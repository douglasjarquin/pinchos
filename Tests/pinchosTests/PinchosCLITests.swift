import Darwin
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
        XCTAssertTrue(String(decoding: initialContents, as: UTF8.self).contains("[item.codex]"))

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
        run = "echo bad"
        interval = "soon"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let semanticCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(semanticCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad"))
        XCTAssertTrue(capture.stderr.contains("interval"))
        XCTAssertTrue(capture.stderr.contains("line 3"))
    }

    func testIssue45SchemaErrorIsSharedAcrossValidateDoctorAndRun() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.clock]
        run = "date"
        intervall = "5s"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let validateCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(validateCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.clock.intervall"))
        XCTAssertTrue(capture.stderr.contains("line 3"))

        capture.stdout = ""
        capture.stderr = ""
        let doctorCode = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("item.clock.intervall"))
        XCTAssertTrue(capture.stdout.contains("line 3"))

        capture.stdout = ""
        capture.stderr = ""
        let runCode = await cli.run(arguments: ["run", "clock"])
        XCTAssertEqual(runCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.clock.intervall"))
        XCTAssertTrue(capture.stderr.contains("line 3"))
    }

    func testIssue45RootSchemaErrorIsSharedAcrossValidateDoctorAndRun() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "item = \"not-a-table\"\n".write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let validateCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(validateCode, 3)
        XCTAssertTrue(capture.stderr.contains("item must contain [item.<id>] tables"))
        XCTAssertTrue(capture.stderr.contains("line 1"))

        capture.stdout = ""
        capture.stderr = ""
        let doctorCode = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("item must contain [item.<id>] tables"))
        XCTAssertTrue(capture.stdout.contains("line 1"))

        capture.stdout = ""
        capture.stderr = ""
        let runCode = await cli.run(arguments: ["run", "clock"])
        XCTAssertEqual(runCode, 3)
        XCTAssertTrue(capture.stderr.contains("item must contain [item.<id>] tables"))
        XCTAssertTrue(capture.stderr.contains("line 1"))
    }

    func testValidateRejectsDeferredItemOptions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        try """
        [item.bad]
        run = "echo bad"
        shell = ["/definitely/missing/pinchos-shell", "-lc"]
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let shellCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(shellCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad"))
        XCTAssertTrue(capture.stderr.contains("unknown key"))

        try """
        [item.bad]
        run = "echo bad"
        working_directory = "missing"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let workingDirectoryCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(workingDirectoryCode, 3)
        XCTAssertTrue(capture.stderr.contains("item.bad"))
        XCTAssertTrue(capture.stderr.contains("unknown key"))

        try """
        [item.bad]
        run = "echo bad"

        [item.bad.env]
        BAD-NAME = "value"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        capture.stderr = ""
        let environmentCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(environmentCode, 3)
        XCTAssertTrue(capture.stderr.contains("items must use exactly [item.<id>] tables"))
        XCTAssertTrue(capture.stderr.contains("line"))
    }

    func testDoctorReportsRuntimeProblemsWithoutRunningConfiguredItems() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.bad]
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
        XCTAssertFalse(capture.stdout.contains("launch at login"))
    }

    func testDoctorReportsConfiguredSymbolInsteadOfMissingFileIcon() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.chart]
        run = "true"
        symbol = "chart.bar.fill"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("[PASS] item.chart.symbol"))
        XCTAssertTrue(capture.stdout.contains("chart.bar.fill"))
        XCTAssertFalse(capture.stdout.contains("item.chart.icon"))
    }

    func testDoctorReportsUnavailableSymbolWithoutRejectingValidate() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.missing]
        run = "true"
        symbol = "pinchos.definitely.not.a.real.symbol"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let validateCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(validateCode, 0)

        let doctorCode = await cli.run(arguments: ["doctor"])
        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.missing.symbol"))
        XCTAssertTrue(capture.stdout.contains("unavailable"))
        XCTAssertTrue(capture.stdout.contains("rendering text-only"))
        XCTAssertFalse(capture.stdout.contains("item.missing.icon"))
    }

    func testValidateRejectsSymbolAndIconTogether() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.both]
        run = "true"
        icon = "/tmp/icon.svg"
        symbol = "chart.bar.fill"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let validateCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(validateCode, 3)
        XCTAssertTrue(capture.stderr.contains("icon and symbol are mutually exclusive"))
    }

    func testDoctorDoesNotExecuteConfiguredShellOrEnvironment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let markerURL = root.appendingPathComponent("doctor-shell-ran")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.safe]
        run = "touch '\(markerURL.path)'"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(capture.stdout.contains("[PASS] item.safe.run"))
    }

    func testDoctorDoesNotClaimCompoundRunIsAvailable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.compound]
        run = "cd /tmp; definitely_missing_pinchos_command"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.compound.run"))
        XCTAssertTrue(capture.stdout.contains("single command"))
    }

    func testDoctorRecognizesExecutablePathContainingSpaces() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let executableURL = root.appendingPathComponent("tool with spaces")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/zsh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try """
        [item.spaced]
        run = "'\(executableURL.path)'"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let parsed = try ConfigParser.parse(String(contentsOf: configURL), relativeTo: configURL)
        XCTAssertEqual(parsed.items.first?.run, "'\(executableURL.path)'")
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("[PASS] item.spaced.run"))
        XCTAssertTrue(capture.stdout.contains("tool with spaces"))
    }

    func testDoctorChecksCommandAfterEnvironmentAssignments() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.env_prefix]
        run = "env PINCHOS_PROBE=1 definitely_missing_pinchos_command"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.env_prefix.run"))
        XCTAssertTrue(capture.stdout.contains("definitely_missing_pinchos_command"))
    }

    func testRunExecutesCanonicalItem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.example]
        run = "printf canonical"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let runCode = await cli.run(arguments: ["run", "example"])
        XCTAssertEqual(runCode, 0)
        XCTAssertEqual(capture.stderr, "")
        XCTAssertEqual(capture.stdout, "canonical")
    }

    func testRunPreservesChildExitCodeAndRejectsUnknownItems() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.failure]
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
        run = "sleep 2"
        timeout = "1s"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let timeoutCode = await cli.run(arguments: ["run", "timeout"])
        XCTAssertEqual(timeoutCode, 124)
        XCTAssertTrue(capture.stderr.contains("timed out"))
    }

    func testRunWaitsForLingeringDescendantAndIncludesItsLateOutput() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.lingering]
        run = "(sleep 0.3; printf 'late\\n') & exit 0"
        timeout = "2s"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let startedAt = Date()
        let runCode = await cli.run(arguments: ["run", "lingering"])

        // A same-group descendant outliving the shell must not be treated as
        // final: `pinchos run` has to wait for it to settle so its output is
        // captured and the CLI does not exit while it still owns the group.
        XCTAssertEqual(runCode, 0)
        XCTAssertEqual(capture.stdout, "late\n")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.25)
    }

    func testRunKillsIndefiniteLingeringDescendantAtConfiguredTimeoutAndLeavesNoOrphan() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let childPIDURL = root.appendingPathComponent("child.pid")
        try """
        [item.indefinite]
        run = "(trap '' TERM; while :; do sleep 1; done) & child=$!; printf '%s' $child > '\(childPIDURL.path)'; exit 0"
        timeout = "1s"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let runCode = await cli.run(arguments: ["run", "indefinite"])

        XCTAssertEqual(runCode, 124)
        XCTAssertTrue(capture.stderr.contains("timed out"))
        let pidText = try String(contentsOf: childPIDURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(pidText))
        XCTAssertTrue(waitUntilProcessIsGone(childPID), "pinchos run left an orphaned descendant \(childPID) after its timeout")
    }

    private func waitUntilProcessIsGone(_ pid: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
