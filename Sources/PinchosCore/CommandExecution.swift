import Darwin
import Foundation

public enum CommandTerminalReason: Equatable, Sendable {
    case exited(code: Int32)
    case signaled(signal: Int32)
    case timedOut
    case cancelled
    case launchFailed(String)
}

public struct CommandExecution: Equatable, Sendable {
    public let terminalReason: CommandTerminalReason
    public let stdout: String
    public let stderr: String
    public let stdoutBytesRead: Int
    public let stderrBytesRead: Int
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let duration: TimeInterval

    public var exitCode: Int32? {
        guard case .exited(let code) = terminalReason else { return nil }
        return code
    }

    public init(
        terminalReason: CommandTerminalReason,
        stdout: String,
        stderr: String,
        stdoutBytesRead: Int,
        stderrBytesRead: Int,
        stdoutTruncated: Bool,
        stderrTruncated: Bool,
        duration: TimeInterval
    ) {
        self.terminalReason = terminalReason
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutBytesRead = stdoutBytesRead
        self.stderrBytesRead = stderrBytesRead
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.duration = duration
    }
}

public enum CommandRunOutcome: Equatable, Sendable {
    case completed(CommandExecution)
    case skipped
}

public struct CommandRunnerSnapshot: Equatable, Sendable {
    public let isRunning: Bool
    public let lastExecution: CommandExecution?
    public let skippedRefreshes: Int

    public init(isRunning: Bool, lastExecution: CommandExecution?, skippedRefreshes: Int) {
        self.isRunning = isRunning
        self.lastExecution = lastExecution
        self.skippedRefreshes = skippedRefreshes
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var retained = Data()
    private var bytesRead = 0
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let (newTotal, totalOverflowed) = bytesRead.addingReportingOverflow(data.count)
        bytesRead = totalOverflowed ? Int.max : newTotal
        if bytesRead > limit || totalOverflowed {
            truncated = true
        }

        retained.append(data)
        if retained.count > limit {
            retained = Data(retained.suffix(limit))
        }
    }

    func snapshot() -> (data: Data, bytesRead: Int, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (retained, bytesRead, truncated)
    }
}

private final class DrainController: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private final class LingeringOutput: @unchecked Sendable {
    let stdoutTask: Task<Void, Never>
    let stderrTask: Task<Void, Never>
    private let controller: DrainController

    init(stdoutTask: Task<Void, Never>, stderrTask: Task<Void, Never>, controller: DrainController) {
        self.stdoutTask = stdoutTask
        self.stderrTask = stderrTask
        self.controller = controller
    }

    func stop() {
        controller.stop()
    }

    func stopAndWait() async {
        stop()
        _ = await stdoutTask.value
        _ = await stderrTask.value
    }
}

private final class ProcessGroupController: @unchecked Sendable {
    fileprivate enum Claim: Equatable {
        case natural
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var claim: Claim?
    private var cleanupRequested = false

    func install(processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldTerminate = claim == .timedOut || claim == .cancelled
        lock.unlock()

        if shouldTerminate {
            requestGroupTermination()
        }
    }

    func claimNatural() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard claim == nil else { return false }
        claim = .natural
        return true
    }

    fileprivate func beginTermination(_ reason: Claim) -> Bool {
        lock.lock()
        let canClaim = claim == nil || claim == reason || claim == .natural
        if claim == nil {
            claim = reason
        }
        let shouldRequest = processGroupID != nil && !cleanupRequested
        lock.unlock()
        if shouldRequest {
            requestGroupTermination()
        }
        return canClaim
    }

    func requestGroupTermination() {
        lock.lock()
        guard !cleanupRequested, let processGroupID else {
            lock.unlock()
            return
        }
        guard groupHasMembers(processGroupID) else {
            self.processGroupID = nil
            lock.unlock()
            return
        }
        cleanupRequested = true
        lock.unlock()

        _ = kill(-processGroupID, SIGTERM)
        _ = kill(-processGroupID, SIGKILL)
    }

    func claimDescription() -> CommandTerminalReason? {
        lock.lock()
        defer { lock.unlock() }
        switch claim {
        case .natural, nil:
            return nil
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    func hasMembers() -> Bool {
        lock.lock()
        guard let processGroupID else {
            lock.unlock()
            return false
        }
        let hasMembers = groupHasMembers(processGroupID)
        if !hasMembers {
            self.processGroupID = nil
        }
        lock.unlock()
        return hasMembers
    }

    private func groupHasMembers(_ processGroupID: pid_t) -> Bool {
        let result = kill(-processGroupID, 0)
        return result == 0 || errno == EPERM
    }

    func waitForExit() async {
        for _ in 0..<100 {
            guard hasMembers() else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct LingeringProcess: Sendable {
    let controller: ProcessGroupController
    let output: LingeringOutput
    let timeoutTask: Task<Void, Never>
    let execution: CommandExecution
    let stdout: OutputCollector
    let stderr: OutputCollector

    func currentExecution() -> CommandExecution {
        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        return CommandExecution(
            terminalReason: execution.terminalReason,
            stdout: String(decoding: stdoutSnapshot.data, as: UTF8.self),
            stderr: String(decoding: stderrSnapshot.data, as: UTF8.self),
            stdoutBytesRead: stdoutSnapshot.bytesRead,
            stderrBytesRead: stderrSnapshot.bytesRead,
            stdoutTruncated: stdoutSnapshot.truncated,
            stderrTruncated: stderrSnapshot.truncated,
            duration: execution.duration
        )
    }
}

private struct CommandExecutionResult: Sendable {
    let execution: CommandExecution
    let lingeringProcess: LingeringProcess?
}

private enum CommandExecutionEngine {
    private static let drainGraceNanoseconds: UInt64 = 300_000_000

    private enum SpawnError: Error, CustomStringConvertible {
        case posix(Int32)

        var description: String {
            switch self {
            case .posix(let code):
                return "posix_spawn failed with status \(code)"
            }
        }
    }

    private enum WaitResult: Sendable {
        case exited(Int32)
        case signaled(Int32)
        case unknown
    }

    private enum Event: Sendable {
        case process(WaitResult)
        case timeout
        case cancellation
    }

    private final class EventRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Event, Never>?
        private var pending: Event?

        func install(_ continuation: CheckedContinuation<Event, Never>) {
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(returning: pending)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func resume(_ event: Event) {
            lock.lock()
            guard pending == nil else {
                lock.unlock()
                return
            }
            guard let continuation = self.continuation else {
                pending = event
                lock.unlock()
                return
            }
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: event)
        }
    }

    static func run(
        command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        controller: ProcessGroupController
    ) async -> CommandExecutionResult {
        let race = EventRace()
        return await withTaskCancellationHandler(
            operation: {
                await runProcess(
                    command: command,
                    timeout: timeout,
                    maxOutputBytes: maxOutputBytes,
                    controller: controller,
                    race: race
                )
            },
            onCancel: {
                _ = controller.beginTermination(.cancelled)
                race.resume(.cancellation)
            })
    }

    private static func runProcess(
        command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        controller: ProcessGroupController,
        race: EventRace
    ) async -> CommandExecutionResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var stdoutFileDescriptors = [Int32](repeating: -1, count: 2)
        var stderrFileDescriptors = [Int32](repeating: -1, count: 2)

        guard Darwin.pipe(&stdoutFileDescriptors) == 0,
            Darwin.pipe(&stderrFileDescriptors) == 0
        else {
            let errorCode = errno
            closeIfOpen(stdoutFileDescriptors)
            closeIfOpen(stderrFileDescriptors)
            return CommandExecutionResult(
                execution: makeExecution(
                    reason: .launchFailed(String(cString: strerror(errorCode))),
                    stdout: OutputCollector(limit: maxOutputBytes),
                    stderr: OutputCollector(limit: maxOutputBytes),
                    startedAt: startedAt
                ),
                lingeringProcess: nil
            )
        }
        guard setCloseOnExec(stdoutFileDescriptors[0]),
            setCloseOnExec(stdoutFileDescriptors[1]),
            setCloseOnExec(stderrFileDescriptors[0]),
            setCloseOnExec(stderrFileDescriptors[1])
        else {
            let errorCode = errno
            closeIfOpen(stdoutFileDescriptors)
            closeIfOpen(stderrFileDescriptors)
            return CommandExecutionResult(
                execution: makeExecution(
                    reason: .launchFailed(String(cString: strerror(errorCode))),
                    stdout: OutputCollector(limit: maxOutputBytes),
                    stderr: OutputCollector(limit: maxOutputBytes),
                    startedAt: startedAt
                ),
                lingeringProcess: nil
            )
        }

        let processID: pid_t
        do {
            processID = try spawn(
                command: command,
                stdoutRead: stdoutFileDescriptors[0],
                stdoutWrite: stdoutFileDescriptors[1],
                stderrRead: stderrFileDescriptors[0],
                stderrWrite: stderrFileDescriptors[1]
            )
        } catch {
            closeIfOpen(stdoutFileDescriptors)
            closeIfOpen(stderrFileDescriptors)
            return CommandExecutionResult(
                execution: makeExecution(
                    reason: .launchFailed(String(describing: error)),
                    stdout: OutputCollector(limit: maxOutputBytes),
                    stderr: OutputCollector(limit: maxOutputBytes),
                    startedAt: startedAt
                ),
                lingeringProcess: nil
            )
        }

        close(stdoutFileDescriptors[1])
        stdoutFileDescriptors[1] = -1
        close(stderrFileDescriptors[1])
        stderrFileDescriptors[1] = -1
        controller.install(processGroupID: processID)

        let stdout = OutputCollector(limit: maxOutputBytes)
        let stderr = OutputCollector(limit: maxOutputBytes)
        let drainController = DrainController()
        let stdoutTask = Task {
            await drainAsync(
                fileDescriptor: stdoutFileDescriptors[0],
                into: stdout,
                controller: drainController
            )
        }
        let stderrTask = Task {
            await drainAsync(
                fileDescriptor: stderrFileDescriptors[0],
                into: stderr,
                controller: drainController
            )
        }
        let waitTask = Task { await waitForProcessAsync(processID) }
        let timerTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(for: timeout))
                drainController.stop()
                _ = controller.beginTermination(.timedOut)
                race.resume(.timeout)
            } catch {
                return
            }
        }
        let processEventTask = Task {
            race.resume(.process(await waitTask.value))
        }
        let firstEvent = await withCheckedContinuation { (continuation: CheckedContinuation<Event, Never>) in
            race.install(continuation)
        }
        let terminalAt = DispatchTime.now().uptimeNanoseconds

        let reason: CommandTerminalReason
        let keepProcessGroup: Bool
        switch firstEvent {
        case .timeout:
            timerTask.cancel()
            if !controller.beginTermination(.timedOut), let claimed = controller.claimDescription() {
                reason = claimed
            } else {
                reason = .timedOut
            }
            _ = await waitTask.value
            keepProcessGroup = controller.hasMembers()
        case .cancellation:
            timerTask.cancel()
            if !controller.beginTermination(.cancelled), let claimed = controller.claimDescription() {
                reason = claimed
            } else {
                reason = .cancelled
            }
            _ = await waitTask.value
            keepProcessGroup = controller.hasMembers()
        case .process(let waitResult):
            if controller.claimNatural() {
                reason = terminalReason(for: waitResult)
            } else {
                reason = controller.claimDescription() ?? terminalReason(for: waitResult)
            }
            keepProcessGroup = controller.hasMembers()
            if !keepProcessGroup {
                timerTask.cancel()
            }
        }

        _ = await processEventTask.value

        let lingeringOutput = await finishDraining(
            stdoutTask: stdoutTask,
            stderrTask: stderrTask,
            controller: drainController,
            keepRunning: keepProcessGroup
        )
        let execution = makeExecution(
            reason: reason,
            stdout: stdout,
            stderr: stderr,
            startedAt: startedAt,
            finishedAt: terminalAt
        )
        return CommandExecutionResult(
            execution: execution,
            lingeringProcess: lingeringOutput.map {
                LingeringProcess(
                    controller: controller,
                    output: $0,
                    timeoutTask: timerTask,
                    execution: execution,
                    stdout: stdout,
                    stderr: stderr
                )
            }
        )
    }

    private static func spawn(
        command: String,
        stdoutRead: Int32,
        stdoutWrite: Int32,
        stderrRead: Int32,
        stderrWrite: Int32
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&fileActions, stdoutRead))
        try check(posix_spawn_file_actions_addclose(&fileActions, stdoutWrite))
        try check(posix_spawn_file_actions_addclose(&fileActions, stderrRead))
        try check(posix_spawn_file_actions_addclose(&fileActions, stderrWrite))

        guard let shell = strdup("/bin/sh"),
            let option = strdup("-c"),
            let commandCopy = strdup(command)
        else {
            throw SpawnError.posix(ENOMEM)
        }
        var arguments: [UnsafeMutablePointer<CChar>?] = [shell, option, commandCopy, nil]
        defer {
            for argument in arguments {
                if let argument { free(argument) }
            }
        }

        var environment = ProcessInfo.processInfo.environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        environment.append(nil)
        defer {
            for value in environment {
                if let value { free(value) }
            }
        }

        var processID: pid_t = 0
        let status = arguments.withUnsafeMutableBufferPointer { argumentsBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                "/bin/sh".withCString { shellPath in
                    posix_spawn(
                        &processID,
                        shellPath,
                        &fileActions,
                        &attributes,
                        argumentsBuffer.baseAddress,
                        environmentBuffer.baseAddress
                    )
                }
            }
        }
        try check(status)
        return processID
    }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw SpawnError.posix(status) }
    }

    private static func drain(
        fileDescriptor: Int32,
        into collector: OutputCollector,
        controller: DrainController
    ) {
        defer { close(fileDescriptor) }
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !controller.shouldStop {
            let pollResult = Darwin.poll(&descriptor, 1, 50)
            if pollResult == 0 {
                continue
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, rawBuffer.count)
            }
            if count > 0 {
                collector.append(Data(buffer.prefix(count)))
            } else if count == 0 {
                return
            } else if errno != EINTR {
                return
            }
        }
    }

    private static func drainAsync(
        fileDescriptor: Int32,
        into collector: OutputCollector,
        controller: DrainController
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                drain(fileDescriptor: fileDescriptor, into: collector, controller: controller)
                continuation.resume()
            }
        }
    }

    private static func finishDraining(
        stdoutTask: Task<Void, Never>,
        stderrTask: Task<Void, Never>,
        controller: DrainController,
        keepRunning: Bool
    ) async -> LingeringOutput? {
        if keepRunning {
            try? await Task.sleep(nanoseconds: drainGraceNanoseconds)
            return LingeringOutput(
                stdoutTask: stdoutTask,
                stderrTask: stderrTask,
                controller: controller
            )
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await stdoutTask.value
                _ = await stderrTask.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: drainGraceNanoseconds)
                controller.stop()
            }
            _ = await group.next()
            group.cancelAll()
        }
        _ = await stdoutTask.value
        _ = await stderrTask.value
        return nil
    }

    private static func waitForProcess(_ processID: pid_t) -> WaitResult {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID {
                let signal = status & 0x7f
                if signal == 0 {
                    return .exited((status >> 8) & 0xff)
                }
                if signal != 0x7f {
                    return .signaled(signal)
                }
                return .unknown
            }
            if result == -1, errno == EINTR {
                continue
            }
            return .unknown
        }
    }

    private static func waitForProcessAsync(_ processID: pid_t) async -> WaitResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<WaitResult, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: waitForProcess(processID))
            }
        }
    }

    private static func terminalReason(for result: WaitResult) -> CommandTerminalReason {
        switch result {
        case .exited(let code):
            return .exited(code: code)
        case .signaled(let signal):
            return .signaled(signal: signal)
        case .unknown:
            return .launchFailed("waitpid did not return a terminal status")
        }
    }

    private static func makeExecution(
        reason: CommandTerminalReason,
        stdout: OutputCollector,
        stderr: OutputCollector,
        startedAt: UInt64,
        finishedAt: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> CommandExecution {
        let stdoutSnapshot = stdout.snapshot()
        let stderrSnapshot = stderr.snapshot()
        let elapsed = finishedAt &- startedAt
        return CommandExecution(
            terminalReason: reason,
            stdout: String(decoding: stdoutSnapshot.data, as: UTF8.self),
            stderr: String(decoding: stderrSnapshot.data, as: UTF8.self),
            stdoutBytesRead: stdoutSnapshot.bytesRead,
            stderrBytesRead: stderrSnapshot.bytesRead,
            stdoutTruncated: stdoutSnapshot.truncated,
            stderrTruncated: stderrSnapshot.truncated,
            duration: Double(elapsed) / 1_000_000_000
        )
    }

    private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        let value = timeout * 1_000_000_000
        guard value.isFinite, value < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(max(1, value))
    }

    private static func setCloseOnExec(_ fileDescriptor: Int32) -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFD)
        guard flags >= 0 else { return false }
        return fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC) >= 0
    }

    private static func closeIfOpen(_ fileDescriptors: [Int32]) {
        for fileDescriptor in fileDescriptors where fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
}

public actor CommandRunner {
    private let command: String
    private let timeout: TimeInterval
    private let maxOutputBytes: Int
    private var activeTask: Task<CommandExecutionResult, Never>?
    private var lingeringProcesses: [LingeringProcess] = []
    private var lastExecution: CommandExecution?
    private var skippedRefreshes = 0
    private var cancellationInProgress = false
    private var runGeneration: UInt64 = 0

    public init(command: String, timeout: TimeInterval, maxOutputBytes: Int) {
        precondition(timeout > 0, "command timeout must be positive")
        precondition(maxOutputBytes > 0, "maximum command output must be positive")
        self.command = command
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    public func runIfIdle() async -> CommandRunOutcome {
        let generation = runGeneration
        await settleLingeringProcesses()
        guard generation == runGeneration,
            activeTask == nil,
            lingeringProcesses.isEmpty,
            !cancellationInProgress
        else {
            skippedRefreshes += 1
            return .skipped
        }

        let controller = ProcessGroupController()
        let command = self.command
        let timeout = self.timeout
        let maxOutputBytes = self.maxOutputBytes
        let task = Task.detached {
            await withTaskCancellationHandler {
                await CommandExecutionEngine.run(
                    command: command,
                    timeout: timeout,
                    maxOutputBytes: maxOutputBytes,
                    controller: controller
                )
            } onCancel: {
                _ = controller.beginTermination(.cancelled)
            }
        }
        activeTask = task
        let result = await task.value
        var completedExecution = result.execution
        lastExecution = completedExecution
        if let process = result.lingeringProcess {
            if process.controller.hasMembers() {
                lingeringProcesses.append(process)
            } else {
                process.timeoutTask.cancel()
                await process.output.stopAndWait()
                completedExecution = process.currentExecution()
                lastExecution = completedExecution
            }
        }
        activeTask = nil
        return .completed(completedExecution)
    }

    public func cancelActive() async {
        guard !cancellationInProgress else { return }
        cancellationInProgress = true
        runGeneration &+= 1

        let activeTask = self.activeTask
        activeTask?.cancel()
        if let activeTask {
            _ = await activeTask.value
            while self.activeTask != nil {
                await Task.yield()
            }
        }

        for process in lingeringProcesses {
            await terminate(process)
        }
        await settleLingeringProcesses()
        cancellationInProgress = false
    }

    public func snapshot() async -> CommandRunnerSnapshot {
        await settleLingeringProcesses()
        return CommandRunnerSnapshot(
            isRunning: activeTask != nil || !lingeringProcesses.isEmpty || cancellationInProgress,
            lastExecution: lastExecution,
            skippedRefreshes: skippedRefreshes
        )
    }

    private func terminate(_ process: LingeringProcess) async {
        process.timeoutTask.cancel()
        process.output.stop()
        _ = process.controller.beginTermination(.cancelled)
        await process.controller.waitForExit()
        await process.output.stopAndWait()
    }

    private func settleLingeringProcesses() async {
        var activeProcesses = [LingeringProcess]()
        for process in lingeringProcesses {
            guard !process.controller.hasMembers() else {
                activeProcesses.append(process)
                continue
            }
            process.timeoutTask.cancel()
            await process.output.stopAndWait()
            lastExecution = process.currentExecution()
        }
        lingeringProcesses = activeProcesses
    }
}

public func lastTrimmedLine(of output: String) -> String {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    guard let last = lines.last else { return "" }
    return last.trimmingCharacters(in: .whitespaces)
}
