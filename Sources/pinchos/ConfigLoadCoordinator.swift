import Foundation
import PinchosCore

/// Outcome of a single config load+parse attempt, tagged for latest-wins application
/// by `ConfigLoadCoordinator`. Carries only Sendable data so it can cross from the
/// off-actor load step back to the `@MainActor` result handler.
enum ConfigLoadOutcome: Sendable, Equatable {
    case success(PinchosConfig)
    case parseFailure(String)
    case missingFile
}

/// Reads the config file and runs `ConfigParser.parse` away from any actor, off the
/// AppKit main thread.
enum ConfigFileLoader {
    static let load: @Sendable (String) async -> ConfigLoadOutcome = { path in
        await loadFile(path: path)
    }

    private static func loadFile(path: String) async -> ConfigLoadOutcome {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let config = try ConfigParser.parse(text, relativeTo: URL(fileURLWithPath: path))
            return .success(config)
        } catch {
            if FileManager.default.fileExists(atPath: path) {
                return .parseFailure(String(describing: error))
            }
            return .missingFile
        }
    }
}

/// Owns monotonically increasing reload generations so that config file reads and TOML
/// parsing can run off the AppKit main actor while still applying results in request
/// order.
///
/// Semantics:
/// - Each call to `requestLoad` records a new generation and starts loading immediately
///   unless a load is already in flight, in which case it becomes the sole pending
///   request -- a burst of N requests while busy never grows more than one pending slot.
/// - A load's result is only handed to `resultHandler` if no newer request has been
///   made since that load started. A superseded result is discarded whether it
///   succeeded or failed, so a slow stale parse can never overwrite, or show a warning
///   over, a newer revision.
/// - `loader` runs as a plain (non-actor-isolated) async closure, so the actual file
///   read and parse execute on a background thread, not on this actor and not on
///   `@MainActor`. Because at most one load is ever in flight, this also serializes
///   calls into `ConfigParser`/TOMLKit, which is not verified safe to call concurrently.
actor ConfigLoadCoordinator {
    typealias Loader = @Sendable (String) async -> ConfigLoadOutcome
    typealias ResultHandler = @Sendable @MainActor (ConfigLoadOutcome) async -> Void

    private let loader: Loader
    private let resultHandler: ResultHandler
    private var generation = 0
    private var isLoading = false
    private var pendingPath: String?
    private var isShutdown = false

    init(loader: @escaping Loader, resultHandler: @escaping ResultHandler) {
        self.loader = loader
        self.resultHandler = resultHandler
    }

    /// Number of `resultHandler` invocations so far. Exposed for tests to await
    /// settlement without depending on timing.
    private(set) var appliedCount = 0

    func requestLoad(path: String) {
        guard !isShutdown else { return }
        generation += 1
        guard !isLoading else {
            pendingPath = path
            return
        }
        start(path: path)
    }

    /// Stops applying any future result and drops any coalesced pending request.
    /// A load already in flight is left to run to completion on its own; its result
    /// is simply discarded when it arrives, so shutdown never blocks on outstanding
    /// loader work.
    func shutdown() {
        isShutdown = true
        pendingPath = nil
    }

    private func start(path: String) {
        isLoading = true
        pendingPath = nil
        let startedGeneration = generation
        let loader = self.loader
        Task {
            let outcome = await loader(path)
            await self.finished(generation: startedGeneration, outcome: outcome)
        }
    }

    private func finished(generation finishedGeneration: Int, outcome: ConfigLoadOutcome) async {
        isLoading = false
        let isCurrent = finishedGeneration == generation
        if isCurrent, !isShutdown {
            appliedCount += 1
            await resultHandler(outcome)
        }
        if let path = pendingPath, !isShutdown {
            start(path: path)
        }
    }
}
