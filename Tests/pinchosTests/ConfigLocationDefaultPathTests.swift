import Foundation
import XCTest

/// Covers the issue #15 acceptance criterion that, with `XDG_CONFIG_HOME`
/// unset, an installed copy resolves the documented default config at
/// `$HOME/.config/pinchos/pinchos.toml`.
///
/// `ConfigLocation.resolve()` falls back to `NSHomeDirectory()`, which reads
/// the current user's home directory from the account database, not the
/// `HOME` environment variable - so this test cannot fake a different home
/// by overriding `HOME` in the child process's environment (see
/// docs/manual-qa/v1.2-packaging-evidence.md for how that was discovered).
/// Instead it omits `XDG_CONFIG_HOME` entirely and compares against this
/// test process's own real `NSHomeDirectory()`, which is the same user and
/// therefore the same value the child process will independently resolve.
final class ConfigLocationDefaultPathTests: XCTestCase {
    func testDefaultConfigPathIsUnderRealHomeDirectoryWhenXDGConfigHomeIsUnset() throws {
        let launchedProcess = Process()
        launchedProcess.executableURL = try pinchosExecutable()
        launchedProcess.arguments = ["config-path"]

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XDG_CONFIG_HOME")
        launchedProcess.environment = environment

        let stdoutPipe = Pipe()
        launchedProcess.standardOutput = stdoutPipe
        launchedProcess.standardError = FileHandle.nullDevice

        try launchedProcess.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        launchedProcess.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = NSHomeDirectory() + "/.config/pinchos/pinchos.toml"

        XCTAssertEqual(launchedProcess.terminationStatus, 0)
        XCTAssertEqual(output, expected)
    }

    private func pinchosExecutable() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/arm64-apple-macosx/release/pinchos"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/pinchos")
        ]
        if let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw NSError(
            domain: "ConfigLocationDefaultPathTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate the Pinchos executable in .build"]
        )
    }
}
