import Darwin
import Dispatch
import Foundation

enum ShutdownReason: Equatable, Sendable {
    case signal(Int32)
    case normalQuit
    case cliCompletion(Int32)

    var exitCode: Int32 {
        switch self {
        case .signal(let signal):
            return min(255, 128 + signal)
        case .normalQuit:
            return 0
        case .cliCompletion(let code):
            return code
        }
    }
}

@MainActor
final class ShutdownCoordinator {
    typealias Cleanup = @MainActor () async -> Void
    typealias ForcedExit = @MainActor (Int32) -> Void
    typealias Completion = @MainActor (ShutdownReason) -> Void

    private enum State {
        case running
        case shuttingDown
        case finished
        case forcedExit
    }

    private let signalNumbers: [Int32]
    private let cleanupTimeoutNanoseconds: UInt64
    private let forcedExit: ForcedExit
    private let autoFinishOnCleanup: Bool
    private let onFinished: Completion?
    private let signalQueue = DispatchQueue(label: "com.pinchos.shutdown-signal")
    private var signalSources: [DispatchSourceSignal] = []
    private var cleanupHandler: Cleanup
    private var cleanupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    private var state = State.running
    private var firstReason: ShutdownReason?
    private var pendingExitCode: Int32?
    private var completionRequested = false

    init(
        signalNumbers: [Int32],
        cleanupTimeoutNanoseconds: UInt64 = 5_000_000_000,
        cleanup: @escaping Cleanup,
        forcedExit: @escaping ForcedExit,
        autoFinishOnCleanup: Bool,
        onFinished: Completion? = nil
    ) {
        self.signalNumbers = signalNumbers
        self.cleanupTimeoutNanoseconds = cleanupTimeoutNanoseconds
        self.cleanupHandler = cleanup
        self.forcedExit = forcedExit
        self.autoFinishOnCleanup = autoFinishOnCleanup
        self.onFinished = onFinished
    }

    var isShutdownRequested: Bool {
        state != .running
    }

    var isFinished: Bool {
        switch state {
        case .finished, .forcedExit:
            return true
        case .running, .shuttingDown:
            return false
        }
    }

    var terminationExitCode: Int32? {
        guard case .signal(let signal) = firstReason else { return nil }
        return min(255, 128 + signal)
    }

    func start() {
        guard signalSources.isEmpty else { return }
        for signalNumber in signalNumbers {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.receiveSignal(signalNumber)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func stop() {
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()
    }

    func setCleanup(_ cleanup: @escaping Cleanup) {
        cleanupHandler = cleanup
    }

    func requestShutdown(reason: ShutdownReason) {
        guard case .running = state else { return }
        firstReason = reason
        state = .shuttingDown
        beginCleanup()
    }

    func finish(exitCode: Int32) async -> Int32 {
        pendingExitCode = exitCode
        completionRequested = true
        if case .running = state {
            requestShutdown(reason: .cliCompletion(exitCode))
        }
        guard !isFinished else { return effectiveExitCode }
        await withCheckedContinuation { continuation in
            cleanupWaiters.append(continuation)
        }
        return effectiveExitCode
    }

    private func receiveSignal(_ signal: Int32) {
        requestShutdown(reason: .signal(signal))
    }

    private func beginCleanup() {
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cleanupHandler()
            self.cleanupDidFinish()
        }
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.cleanupTimeoutNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.forceExitIfNeeded()
        }
    }

    private func cleanupDidFinish() {
        guard case .shuttingDown = state else { return }
        state = .finished
        timeoutTask?.cancel()
        timeoutTask = nil
        resumeCleanupWaiters()
        if autoFinishOnCleanup || completionRequested {
            onFinished?(firstReason ?? .normalQuit)
        }
    }

    private func forceExitIfNeeded() {
        guard case .shuttingDown = state else { return }
        state = .forcedExit
        cleanupTask?.cancel()
        timeoutTask?.cancel()
        resumeCleanupWaiters()
        forcedExit(forcedExitCode)
    }

    private var effectiveExitCode: Int32 {
        if case .forcedExit = state { return forcedExitCode }
        return firstReason?.exitCode ?? pendingExitCode ?? 0
    }

    private let forcedExitCode: Int32 = 125

    private func resumeCleanupWaiters() {
        let waiters = cleanupWaiters
        cleanupWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
