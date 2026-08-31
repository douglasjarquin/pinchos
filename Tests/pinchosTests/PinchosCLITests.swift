import Darwin
import Foundation
import XCTest
@testable import PinchosCore
@testable import pinchos

private final class CLIOutputCapture {
    var stdout = ""
    var stderr = ""

    var output: CLIOutput {
        CLIOutput(
            stdout: { [weak self] text in self?.stdout += text },
            stderr: { [weak self] text in self?.stderr += text }
        )
    }
}

@MainActor
final class PinchosCLITests: XCTestCase {
    func testHelpAndUnknownCommandHaveStableBoundaries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: root.appendingPathComponent("pinchos.toml").path, output: capture.output)

        let exitCode1 = await cli.run(arguments: ["--help"])
        XCTAssertEqual(exitCode1, 0)
        XCTAssertTrue(capture.stdout.contains("Usage: pinchos <command>"))
        XCTAssertTrue(capture.stdout.contains("run <item>"))
        XCTAssertFalse(capture.stdout.contains("service"))

        capture.stdout = ""
        let exitCode2 = await cli.run(arguments: ["unknown-command"])
        XCTAssertEqual(exitCode2, 2)
        XCTAssertTrue(capture.stderr.contains("unknown command 'unknown-command'"))
    }

    func testConfigPathDoesNotCreateAnythingAndInitIsCanonicalAndIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode3 = await cli.run(arguments: ["config-path"])
        XCTAssertEqual(exitCode3, 0)
        XCTAssertEqual(capture.stdout, "\(configURL.path)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))

        capture.stdout = ""
        let exitCode4 = await cli.run(arguments: ["init"])
        XCTAssertEqual(exitCode4, 0)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), ExampleConfig.text)
        XCTAssertNoThrow(try ConfigParser.parse(ExampleConfig.text))

        try "custom".write(to: configURL, atomically: true, encoding: .utf8)
        capture.stdout = ""
        let exitCode5 = await cli.run(arguments: ["init"])
        XCTAssertEqual(exitCode5, 0)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "custom")
        XCTAssertTrue(capture.stdout.contains("Config already exists"))
    }

    func testOpenConfigCreatesOnlyMissingFileAndUsesInjectedOpener() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let capture = CLIOutputCapture()
        var opened: URL?
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            opener: { opened = $0; return true }
        )

        let exitCode6 = await cli.run(arguments: ["open-config"])
        XCTAssertEqual(exitCode6, 0)
        XCTAssertEqual(opened, configURL)
        XCTAssertEqual(try Data(contentsOf: configURL), Data())
    }

    func testValidateReportsMissingEmptySyntaxAndRemovedSchemaErrors() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode7 = await cli.run(arguments: ["validate"])
        XCTAssertEqual(exitCode7, 3)
        XCTAssertTrue(capture.stderr.contains("config does not exist"))

        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: configURL)
        capture.stderr = ""
        let exitCode8 = await cli.run(arguments: ["validate"])
        XCTAssertEqual(exitCode8, 3)
        XCTAssertTrue(capture.stderr.contains("contains no items"))

        try "[item.bad".write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let exitCode9 = await cli.run(arguments: ["validate"])
        XCTAssertEqual(exitCode9, 3)
        XCTAssertTrue(capture.stderr.contains("invalid config"))

        try """
        [item.bad]
        run = "echo bad"
        click = "open https://example.com"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let exitCode10 = await cli.run(arguments: ["validate"])
        XCTAssertEqual(exitCode10, 3)
        XCTAssertTrue(capture.stderr.contains("unknown key 'click'"))
        XCTAssertTrue(capture.stderr.contains("line 3"))
    }

    func testValidateAcceptsExactlyTheCanonicalSchema() async throws {
        let (root, configURL) = try makeConfig("""
        [item.clock]
        run = "date '+%H:%M'"
        interval = "30s"
        timeout = "2s"
        format = "{output}"
        symbol = "clock"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode11 = await cli.run(arguments: ["validate"])
        XCTAssertEqual(exitCode11, 0)
        XCTAssertTrue(capture.stdout.contains("(1 item)"))
    }

    func testDoctorChecksFixedRuntimeWithoutExecutingConfiguredItems() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-doctor-marker-\(UUID().uuidString)")
        let (root, configURL) = try makeConfig("""
        [item.safe]
        run = "touch '\(marker.path)'; printf ok"
        interval = "manual"
        """)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: marker)
        }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode12 = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(exitCode12, 0)
        XCTAssertTrue(capture.stdout.contains("[PASS] shell: /bin/sh"))
        XCTAssertTrue(capture.stdout.contains("[PASS] working directory:"))
        XCTAssertTrue(capture.stdout.contains("[PASS] PATH:"))
        XCTAssertTrue(capture.stdout.contains("[INFO] item.safe.run: compound shell command"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDoctorFindsMissingSimpleCommandAndUnreadableIcon() async throws {
        let (root, configURL) = try makeConfig("""
        [item.bad]
        run = "definitely_missing_pinchos_command"
        icon = "missing.png"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode13 = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(exitCode13, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.run"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.icon"))
    }

    func testRunUsesFixedHomeWorkingDirectoryAndDeterministicPath() async throws {
        let (root, configURL) = try makeConfig("""
        [item.runtime]
        run = "printf '%s\\n%s' \"$PWD\" \"$PATH\""
        interval = "manual"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode14 = await cli.run(arguments: ["run", "runtime"])
        XCTAssertEqual(exitCode14, 0)
        let lines = capture.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first.map(String.init), FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertTrue(capture.stdout.contains("/.local/share/mise/shims"))
        XCTAssertTrue(capture.stdout.contains("/opt/homebrew/bin"))
    }

    func testRunPreservesOutputAndChildExitCodeAndRejectsUnknownItem() async throws {
        let (root, configURL) = try makeConfig("""
        [item.failure]
        run = "printf out; printf err >&2; exit 7"
        interval = "manual"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode15 = await cli.run(arguments: ["run", "failure"])
        XCTAssertEqual(exitCode15, 7)
        XCTAssertEqual(capture.stdout, "out")
        XCTAssertTrue(capture.stderr.contains("err"))
        XCTAssertTrue(capture.stderr.contains("exited with code 7"))

        capture.stderr = ""
        let exitCode16 = await cli.run(arguments: ["run", "missing"])
        XCTAssertEqual(exitCode16, 3)
        XCTAssertTrue(capture.stderr.contains("is not configured"))
    }

    func testRunMapsTimeoutToStableExitCode() async throws {
        let (root, configURL) = try makeConfig("""
        [item.slow]
        run = "sleep 5"
        timeout = "1s"
        interval = "manual"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode17 = await cli.run(arguments: ["run", "slow"])
        XCTAssertEqual(exitCode17, 124)
        XCTAssertTrue(capture.stderr.contains("timed out after 1.0s"))
    }

    func testRunWaitsForLateOutputFromLingeringDescendant() async throws {
        let (root, configURL) = try makeConfig("""
        [item.late]
        run = "(sleep 0.2; printf late) & exit 0"
        timeout = "2s"
        interval = "manual"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode18 = await cli.run(arguments: ["run", "late"])
        XCTAssertEqual(exitCode18, 0)
        XCTAssertEqual(capture.stdout, "late")
    }

    func testRunKillsIndefiniteDescendantAtTimeout() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let childPIDURL = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.indefinite]
        run = "(trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' $child > '\(childPIDURL.path)'; exit 0"
        timeout = "1s"
        interval = "manual"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let exitCode19 = await cli.run(arguments: ["run", "indefinite"])
        XCTAssertEqual(exitCode19, 124)
        let pidText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(pidText))
        XCTAssertTrue(waitUntilProcessIsGone(childPID))
    }

    private func makeConfig(_ text: String) throws -> (URL, URL) {
        let root = try makeRoot()
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
        return (root, configURL)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntilProcessIsGone(_ pid: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(10_000)
        } while Date() < deadline
        return kill(pid, 0) == -1 && errno == ESRCH
    }
}
