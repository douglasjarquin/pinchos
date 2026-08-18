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
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var commandExited = false
        private var descendantsGone = false
        private var terminating = false
        private var released = false
        private var exited = false

        var isOwned: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !terminating && !released && !exited
        }

        var hasDescendants: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started && !descendantsGone && !terminating && !released && !exited
        }

        func markStarted() {
            lock.lock()
            started = true
            lock.unlock()
        }

        func markDescendantsGone() {
            lock.lock()
            descendantsGone = true
            lock.unlock()
        }

        func markCommandExited() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !commandExited, !terminating, !released, !exited else { return false }
            commandExited = true
            return true
        }

        func beginTermination() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminating, !released, !exited else { return false }
            terminating = true
            return true
        }

        func markReleased() {
            lock.lock()
            released = true
            lock.unlock()
        }

        func markExited() {
            lock.lock()
            exited = true
            lock.unlock()
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
    private let lifecycleLock = NSLock()
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
        self.supervisorWaitTask = Task.detached {
            var status: Int32 = 0
            while waitpid(processGroupID, &status, 0) == -1, errno == EINTR {}
            state.markExited()
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
        state.markStarted()
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
        guard state.isOwned else {
            closeControlDescriptor()
            return
        }
        state.markReleased()
        try? send("release\n")
        closeControlDescriptor()
    }

    func waitForExit() async {
        await supervisorWaitTask.value
        state.markExited()
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
                state.markDescendantsGone()
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

}
