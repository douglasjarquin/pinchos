import Darwin
import Foundation

extension SupervisorProcessSession {
    private static let supervisorShell = "/bin/sh"
    private static let controlFileDescriptor: Int32 = 3
    private static let statusFileDescriptor: Int32 = 4
    private static let supervisorScript = """
    IFS= read -r command <&3 || command=
    if [ "$command" = start ]; then
        IFS= read -r command <&3 || command=
        if [ "$command" = finish ]; then
            while /bin/ps -axo pid=,ppid=,pgid=,comm= | /usr/bin/awk -v group="$$" -v supervisor="$$" '$3 == group && $1 != group && $2 != supervisor { found=1 } END { exit found ? 0 : 1 }'; do
                /bin/sleep 0.01
            done
            printf 'empty\\n' >&4
            IFS= read -r command <&3 || command=
            [ "$command" = release ]
        fi
    fi
    """

    static func launch(
        stdoutWrite: Int32,
        stderrWrite: Int32,
        environment: [String: String],
        makePipe: () throws -> (read: Int32, write: Int32) = makePipe
    ) throws -> SupervisorProcessSession {
        var owned = OwnedDescriptors()
        do {
            let control = try makePipe()
            owned.adopt(control.read, control.write)
            let status = try makePipe()
            owned.adopt(status.read, status.write)
            try setCloseOnExec(control.read)
            try setCloseOnExec(control.write)
            try setCloseOnExec(status.read)
            try setCloseOnExec(status.write)
            try setNoSignalOnBrokenPipe(control.write)

            var attributes: posix_spawnattr_t?
            try check(posix_spawnattr_init(&attributes), context: "unable to initialize supervisor attributes")
            defer { posix_spawnattr_destroy(&attributes) }
            // Same descriptor isolation as the command itself: only the
            // descriptors set up below survive into the supervisor.
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)), context: "unable to configure supervisor process group")
            try check(posix_spawnattr_setpgroup(&attributes, 0), context: "unable to configure supervisor process group leader")

            var fileActions: posix_spawn_file_actions_t?
            try check(posix_spawn_file_actions_init(&fileActions), context: "unable to initialize supervisor file actions")
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            try check(posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), context: "unable to configure supervisor stdin")
            try addDup2(stdoutWrite, STDOUT_FILENO, to: &fileActions)
            try addDup2(stderrWrite, STDERR_FILENO, to: &fileActions)
            try addDup2(control.read, controlFileDescriptor, to: &fileActions)
            try addDup2(status.write, statusFileDescriptor, to: &fileActions)

            var arguments = try makeArguments()
            defer { freeArguments(arguments) }
            var environmentEntries = try makeEnvironment(environment)
            defer { freeEnvironment(environmentEntries) }

            var processID: pid_t = 0
            let spawnStatus = arguments.withUnsafeMutableBufferPointer { argumentsBuffer in
                environmentEntries.withUnsafeMutableBufferPointer { environmentBuffer in
                    Self.supervisorShell.withCString { shellPath in
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
            try check(spawnStatus, context: "unable to launch process-session supervisor")
            owned.close(control.read)
            owned.close(status.write)
            guard setNonBlocking(status.read) else {
                let errorCode = errno
                _ = kill(-processID, SIGKILL)
                _ = waitpid(processID, nil, 0)
                throw LaunchError.posix(errorCode, context: "unable to configure supervisor status pipe")
            }
            return SupervisorProcessSession(
                processGroupID: processID,
                controlWrite: owned.release(control.write),
                statusRead: owned.release(status.read)
            )
        } catch {
            owned.closeAll()
            throw error
        }
    }

    /// Single owner for the supervisor pipes from allocation until hand-off:
    /// each descriptor is closed at most once, on whichever path ends first,
    /// so unwinding never leaks one or closes a number another session may
    /// already have reused.
    private struct OwnedDescriptors {
        private var open: Set<Int32> = []

        mutating func adopt(_ descriptors: Int32...) {
            open.formUnion(descriptors)
        }

        mutating func close(_ descriptor: Int32) {
            if open.remove(descriptor) != nil {
                Darwin.close(descriptor)
            }
        }

        mutating func release(_ descriptor: Int32) -> Int32 {
            open.remove(descriptor)
            return descriptor
        }

        mutating func closeAll() {
            for descriptor in open {
                Darwin.close(descriptor)
            }
            open.removeAll()
        }
    }

    static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw LaunchError.posix(errno, context: "unable to create process-session pipe")
        }
        return (descriptors[0], descriptors[1])
    }

    private static func makeArguments() throws -> [UnsafeMutablePointer<CChar>?] {
        var arguments = [UnsafeMutablePointer<CChar>?]()
        for argument in ["/bin/sh", "-c", supervisorScript, "pinchos-process-session"] {
            guard let copy = strdup(argument) else {
                freeArguments(arguments)
                throw LaunchError.posix(ENOMEM, context: "unable to construct supervisor arguments")
            }
            arguments.append(copy)
        }
        arguments.append(nil)
        return arguments
    }

    private static func freeArguments(_ arguments: [UnsafeMutablePointer<CChar>?]) {
        for argument in arguments {
            if let argument { free(argument) }
        }
    }

    private static func makeEnvironment(_ configured: [String: String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var entries = [UnsafeMutablePointer<CChar>?]()
        for key in configured.keys.sorted() {
            guard let entry = strdup("\(key)=\(configured[key]!)") else {
                freeEnvironment(entries)
                throw LaunchError.posix(ENOMEM, context: "unable to construct supervisor environment")
            }
            entries.append(entry)
        }
        entries.append(nil)
        return entries
    }

    private static func freeEnvironment(_ entries: [UnsafeMutablePointer<CChar>?]) {
        for entry in entries {
            if let entry { free(entry) }
        }
    }

    private static func addDup2(_ source: Int32, _ destination: Int32, to actions: inout posix_spawn_file_actions_t?) throws {
        try check(posix_spawn_file_actions_adddup2(&actions, source, destination), context: "unable to configure supervisor descriptor")
    }

    private static func check(_ status: Int32, context: String) throws {
        guard status == 0 else { throw LaunchError.posix(status, context: context) }
    }

    private static func setCloseOnExec(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFD)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
            throw LaunchError.posix(errno, context: "unable to configure close-on-exec")
        }
    }

    /// The supervisor shell can die (killed with its process group, or from
    /// resource exhaustion under heavy concurrent load) before every planned
    /// `send()` to it completes. Without this, a `write()` after that happens
    /// delivers SIGPIPE with its default disposition, which kills this whole
    /// process instantly - not just the write. This makes a broken control
    /// pipe surface as a normal `EPIPE` `send()` already knows how to handle.
    private static func setNoSignalOnBrokenPipe(_ fileDescriptor: Int32) throws {
        guard fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
            throw LaunchError.posix(errno, context: "unable to disable SIGPIPE on control pipe")
        }
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFL)
        return flags >= 0 && fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0
    }
}
