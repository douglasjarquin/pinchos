import Foundation
import XCTest
@testable import pinchos
@testable import PinchosCore

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
    func testHelpAndUnknownCommandHaveScriptableBoundaries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(
            configPath: root.appendingPathComponent("pinchos/pinchos.toml").path,
            output: capture.output
        )

        let helpCode = await cli.run(arguments: ["--help"])
        XCTAssertEqual(helpCode, 0)
        XCTAssertTrue(capture.stdout.contains("Usage: pinchos <command> [options]"))
        XCTAssertTrue(capture.stdout.contains("run <item>"))

        capture.stdout = ""
        let unknownCode = await cli.run(arguments: ["unknown-command"])
        XCTAssertEqual(unknownCode, 2)
        XCTAssertTrue(capture.stderr.contains("unknown command 'unknown-command'"))
        XCTAssertTrue(capture.stderr.contains("pinchos --help"))
    }

    func testInitIsIdempotentAndConfigPathDoesNotCreateFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let pathCode = await cli.run(arguments: ["config-path"])
        XCTAssertEqual(pathCode, 0)
        XCTAssertEqual(capture.stdout, "\(configURL.path)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))

        capture.stdout = ""
        let firstInitCode = await cli.run(arguments: ["init"])
        XCTAssertEqual(firstInitCode, 0)
        let initialContents = try Data(contentsOf: configURL)
        XCTAssertTrue(capture.stdout.contains("Created example config"))
        XCTAssertTrue(String(decoding: initialContents, as: UTF8.self).contains("[item.clock]"))

        capture.stdout = ""
        let secondInitCode = await cli.run(arguments: ["init"])
        XCTAssertEqual(secondInitCode, 0)
        XCTAssertEqual(try Data(contentsOf: configURL), initialContents)
        XCTAssertTrue(capture.stdout.contains("Config already exists"))
    }

    func testOpenConfigCreatesOnlyTheMissingFileAndUsesTheInjectedOpener() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let capture = CLIOutputCapture()
        var openedURL: URL?
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            opener: { openedURL = $0; return true }
        )

        let openCode = await cli.run(arguments: ["open-config"])
        XCTAssertEqual(openCode, 0)
        XCTAssertEqual(openedURL, configURL)
        XCTAssertEqual(try Data(contentsOf: configURL), Data())
        XCTAssertTrue(capture.stdout.contains("Opened config"))
    }

    func testValidateReportsMissingEmptyMalformedAndSemanticConfigErrors() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let missingCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(missingCode, 3)
        XCTAssertTrue(capture.stderr.contains("config does not exist"))

        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: configURL)
        capture.stderr = ""
        let emptyCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(emptyCode, 3)
        XCTAssertTrue(capture.stderr.contains("config contains no items"))

        try "[item.bad".write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let malformedCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(malformedCode, 3)
        XCTAssertTrue(capture.stderr.contains("invalid config"))
        XCTAssertTrue(capture.stderr.contains("line"))

        try """
        [item.bad]
        type = "command"
        run = "echo bad"
        interval = "soon"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let semanticCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(semanticCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad"))
        XCTAssertTrue(capture.stderr.contains("interval"))
        XCTAssertTrue(capture.stderr.contains("line 4"))
    }

    func testValidateReportsShellWorkingDirectoryAndEnvironmentFailures() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        try """
        [item.bad]
        type = "command"
        run = "echo bad"
        shell = ["/definitely/missing/pinchos-shell", "-lc"]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let shellCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(shellCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad"))
        XCTAssertTrue(capture.stderr.contains("shell"))

        try """
        [item.bad]
        type = "command"
        run = "echo bad"
        working_directory = "missing"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let workingDirectoryCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(workingDirectoryCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad"))
        XCTAssertTrue(capture.stderr.contains("working_directory"))

        try """
        [item.bad]
        type = "command"
        run = "echo bad"

        [item.bad.env]
        BAD-NAME = "value"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let environmentCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(environmentCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad.env.BAD-NAME"))
        XCTAssertTrue(capture.stderr.contains("line"))
    }

    func testDoctorReportsRuntimeProblemsWithoutRunningConfiguredItems() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.bad]
        type = "command"
        run = "definitely_missing_pinchos_command"
        icon = "missing.svg"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[PASS] config: readable and parsed"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.run"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.icon"))
        XCTAssertTrue(capture.stdout.contains("launch at login"))
    }

    func testRunUsesConfiguredShellWorkingDirectoryAndMergedEnvironment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let workingDirectory = configURL.deletingLastPathComponent().appendingPathComponent("work")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try """
        [item.example]
        type = "command"
        run = 'printf "%s\\n%s\\n" "$PINCHOS_TEST_OVERRIDE" "$PWD"'
        shell = ["/bin/zsh", "-lc"]
        working_directory = "work"

        [item.example.env]
        PINCHOS_TEST_OVERRIDE = "configured value"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let runCode = await cli.run(arguments: ["run", "example"])
        XCTAssertEqual(runCode, 0)
        XCTAssertEqual(capture.stderr, "")
        let outputLines = capture.stdout.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(outputLines.first, "configured value")
        XCTAssertTrue(outputLines.dropFirst().first?.hasSuffix("/pinchos/work") == true)
    }

    func testRunPreservesChildExitCodeAndRejectsUnknownItems() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.failure]
        type = "command"
        run = "printf boom >&2; exit 7"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let failureCode = await cli.run(arguments: ["run", "failure"])
        XCTAssertEqual(failureCode, 7)
        XCTAssertTrue(capture.stderr.contains("boom"))
        XCTAssertTrue(capture.stderr.contains("exited with code 7"))

        capture.stderr = ""
        let missingItemCode = await cli.run(arguments: ["run", "missing"])
        XCTAssertEqual(missingItemCode, 3)
        XCTAssertTrue(capture.stderr.contains("item 'missing' is not configured"))
    }

    func testRunMapsTimeoutToAStableScriptableExitCode() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.timeout]
        type = "command"
        run = "sleep 2"
        timeout = "1s"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let timeoutCode = await cli.run(arguments: ["run", "timeout"])
        XCTAssertEqual(timeoutCode, 124)
        XCTAssertTrue(capture.stderr.contains("timed out"))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
