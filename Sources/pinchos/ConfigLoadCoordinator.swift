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
/// - A load stays in flight until its result handler returns, so requests that arrive
///   while the handler is suspended coalesce as pending instead of starting a second
///   load beside a follow-up.
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

    private enum State {
        case idle
        /// A load is in flight, from `start` until its result handler returns.
        /// `pendingPath` is the latest request that arrived meanwhile, if any.
        case loading(pendingPath: String?)
        case shutdown
    }

    private let loader: Loader
    private let resultHandler: ResultHandler
    private var generation = 0
    private var state = State.idle

    init(loader: @escaping Loader, resultHandler: @escaping ResultHandler) {
        self.loader = loader
        self.resultHandler = resultHandler
    }

    /// Number of `resultHandler` invocations so far. Exposed for tests to await
    /// settlement without depending on timing.
    private(set) var appliedCount = 0

    func requestLoad(path: String) {
        if case .shutdown = state { return }
        generation += 1
        switch state {
        case .idle:
            start(path: path)
        case .loading:
            state = .loading(pendingPath: path)
        case .shutdown:
            break
        }
    }

    /// Stops applying any future result and drops any coalesced pending request.
    /// A load already in flight is left to run to completion on its own; its result
    /// is simply discarded when it arrives, so shutdown never blocks on outstanding
    /// loader work.
    func shutdown() {
        state = .shutdown
    }

    private func start(path: String) {
        state = .loading(pendingPath: nil)
        let startedGeneration = generation
        let loader = self.loader
        Task {
            let outcome = await loader(path)
            await self.finished(generation: startedGeneration, outcome: outcome)
        }
    }

    private func finished(generation finishedGeneration: Int, outcome: ConfigLoadOutcome) async {
        guard case .loading = state else { return }
        if finishedGeneration == generation {
            appliedCount += 1
            await resultHandler(outcome)
        }
        // Re-read after the handler: shutdown or new requests may have landed meanwhile.
        guard case .loading(let pendingPath) = state else { return }
        if let pendingPath {
            start(path: pendingPath)
        } else {
            state = .idle
        }
    }
}
