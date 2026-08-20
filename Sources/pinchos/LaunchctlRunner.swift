import Foundation

/// Result of one `launchctl` invocation.
struct LaunchctlInvocation {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Abstraction over running `launchctl`, so `LaunchAgentService`'s decision
/// logic (idempotency, status parsing) can be exercised in tests without
/// touching the real per-user launchd domain.
protocol LaunchctlRunning {
    func run(_ arguments: [String]) -> LaunchctlInvocation
}

/// Real `launchctl` process runner used outside of tests.
struct ProcessLaunchctlRunner: LaunchctlRunning {
    func run(_ arguments: [String]) -> LaunchctlInvocation {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return LaunchctlInvocation(exitCode: 127, stdout: "", stderr: "unable to launch /bin/launchctl: \(error)")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return LaunchctlInvocation(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
