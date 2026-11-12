import Darwin
import Foundation

protocol ProcessSessionIdentity: AnyObject, Sendable {
    var isOwned: Bool { get }
    var hasDescendants: Bool { get }

    func commandDidExit()
    func requestTermination()
    func release()
    func waitForExit() async
}

final class SupervisorProcessSession: ProcessSessionIdentity, @unchecked Sendable {
    final class State: @unchecked Sendable {
        /// The supervisor's lifecycle. The reaper can observe exit from any
        /// case. Whether the supervisor has reported every descendant gone is
        /// only meaningful once the command has started, so only those cases
        /// carry it.
        private enum Phase {
            case spawned
            case running(descendantsGone: Bool)
            case commandExited(descendantsGone: Bool)
            case terminating
            case released
            case exited
        }

        private let lock = NSLock()
        private var phase = Phase.spawned

        var isOwned: Bool {
            lock.lock()
            defer { lock.unlock() }
            switch phase {
            case .spawned, .running, .commandExited:
                return true
            case .terminating, .released, .exited:
                return false
            }
        }

        var hasDescendants: Bool {
            lock.lock()
            defer { lock.unlock() }
            switch phase {
            case .running(let descendantsGone), .commandExited(let descendantsGone):
                return !descendantsGone
            case .spawned, .terminating, .released, .exited:
                return false
            }
        }

        func markStarted() -> Bool {
            transition { phase in
                guard case .spawned = phase else { return nil }
                return .running(descendantsGone: false)
            }
        }

        func markDescendantsGone() -> Bool {
            transition { phase in
                switch phase {
                case .running(descendantsGone: false):
                    return .running(descendantsGone: true)
                case .commandExited(descendantsGone: false):
                    return .commandExited(descendantsGone: true)
                case .spawned, .running, .commandExited, .terminating, .released, .exited:
                    return nil
                }
            }
        }

        func markCommandExited() -> Bool {
            transition { phase in
                guard case .running(let descendantsGone) = phase else { return nil }
                return .commandExited(descendantsGone: descendantsGone)
            }
        }

        func beginTermination() -> Bool {
            transition { phase in
                switch phase {
                case .spawned, .running, .commandExited:
                    return .terminating
                case .terminating, .released, .exited:
                    return nil
                }
            }
        }

        func markReleased() -> Bool {
            transition { phase in
                switch phase {
                case .spawned, .running, .commandExited:
                    return .released
                case .terminating, .released, .exited:
                    return nil
                }
            }
        }

        func markExited() -> Bool {
            transition { phase in
                if case .exited = phase { return nil }
                return .exited
            }
        }

        /// Applies `next` atomically; a `nil` result rejects the transition
        /// and leaves the phase unchanged.
        private func transition(_ next: (Phase) -> Phase?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let nextPhase = next(phase) else { return false }
            phase = nextPhase
            return true
        }
    }

    enum LaunchError: Error, CustomStringConvertible {
        case posix(Int32, context: String)
        case pipeWriteFailed(Int32)

        var description: String {
            switch self {
            case .posix(let status, let context):
                return "\(context): posix_spawn failed with status \(status)"
            case .pipeWriteFailed(let status):
                return "unable to signal process-session supervisor: errno \(status)"
            }
        }
    }

    let processGroupID: pid_t
    private let state: State
    private let supervisorWaitTask: Task<Void, Never>
    private let lifecycleLock: NSLock
    private let descriptorLock = NSLock()
    private let statusReadLock = NSLock()
    private var controlWrite: Int32
    private var statusRead: Int32
    private var statusBuffer = Data()

    init(
        processGroupID: pid_t,
        controlWrite: Int32,
        statusRead: Int32
    ) {
        self.processGroupID = processGroupID
        self.controlWrite = controlWrite
        self.statusRead = statusRead
        let state = State()
        self.state = state
        let lifecycleLock = NSLock()
        self.lifecycleLock = lifecycleLock
        self.supervisorWaitTask = Task.detached {
            while !Self.reapSupervisorIfExited(
                processGroupID: processGroupID,
                state: state,
                lifecycleLock: lifecycleLock
            ) {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    var isOwned: Bool { state.isOwned }

    var hasDescendants: Bool {
        refreshStatus(waitMilliseconds: 50)
        let hasDescendants = state.hasDescendants
        return hasDescendants
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard state.isOwned else {
            throw LaunchError.pipeWriteFailed(ESRCH)
        }
        try send("start\n")
        _ = state.markStarted()
    }

    func commandDidExit() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard state.markCommandExited() else { return }
        try? send("finish\n")
    }

    func requestTermination() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard state.beginTermination() else { return }
        _ = kill(-processGroupID, SIGTERM)
        _ = kill(-processGroupID, SIGKILL)
    }

    func release() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard state.markReleased() else {
            closeControlDescriptor()
            return
        }
        try? send("release\n")
        closeControlDescriptor()
    }

    func waitForExit() async {
        await supervisorWaitTask.value
        closeControlDescriptor()
        closeStatusDescriptor()
    }

    private func refreshStatus(waitMilliseconds: Int32) {
        statusReadLock.lock()
        defer { statusReadLock.unlock() }
        descriptorLock.lock()
        let fileDescriptor = statusRead
        descriptorLock.unlock()
        guard fileDescriptor >= 0 else { return }

        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        var pollResult = Darwin.poll(&descriptor, 1, waitMilliseconds)
        while pollResult > 0 {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, rawBuffer.count)
            }
            guard count > 0 else { return }
            statusBuffer.append(contentsOf: buffer.prefix(count))
            if statusBuffer.range(of: Data("empty\n".utf8)) != nil {
                _ = state.markDescendantsGone()
            }
            pollResult = Darwin.poll(&descriptor, 1, 0)
        }
    }

    private func send(_ command: String) throws {
        descriptorLock.lock()
        let fileDescriptor = controlWrite
        descriptorLock.unlock()
        guard fileDescriptor >= 0 else { return }
        let data = Data(command.utf8)
        let result = data.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fileDescriptor, baseAddress, rawBuffer.count)
        }
        guard result == data.count else {
            throw LaunchError.pipeWriteFailed(errno)
        }
    }

    private func closeControlDescriptor() {
        descriptorLock.lock()
        let fileDescriptor = controlWrite
        controlWrite = -1
        descriptorLock.unlock()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    private func closeStatusDescriptor() {
        descriptorLock.lock()
        let fileDescriptor = statusRead
        statusRead = -1
        descriptorLock.unlock()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    private static func reapSupervisorIfExited(
        processGroupID: pid_t,
        state: State,
        lifecycleLock: NSLock
    ) -> Bool {
        var status: Int32 = 0
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let result = waitpid(processGroupID, &status, WNOHANG)
        let errorCode = errno
        guard result == processGroupID || (result == -1 && errorCode != EINTR) else {
            return false
        }
        _ = state.markExited()
        return true
    }

}
