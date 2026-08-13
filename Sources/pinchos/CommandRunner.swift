import Foundation

enum CommandError: Error {
    case nonZeroExit(Int32)
    case launchFailed(Error)
}

actor CommandRunner {
    private var isRunning = false

    func runIfIdle(_ command: String) async -> Result<String, Error>? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        return await Self.execute(command)
    }

    private static func execute(_ command: String) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe()

            process.terminationHandler = { finished in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: .success(text))
                } else {
                    continuation.resume(returning: .failure(CommandError.nonZeroExit(finished.terminationStatus)))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(CommandError.launchFailed(error)))
            }
        }
    }
}

func lastTrimmedLine(of output: String) -> String {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    guard let last = lines.last else { return "" }
    return last.trimmingCharacters(in: .whitespaces)
}

func runFireAndForget(_ command: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}
