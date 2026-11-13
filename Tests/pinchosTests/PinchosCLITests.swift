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
        XCTAssertTrue(String(decoding: initialContents, as: UTF8.self).contains("[item.clock]"))
        XCTAssertTrue(String(decoding: initialContents, as: UTF8.self).contains("date '+%H:%M'"))

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
        let malformedContents = try Data(contentsOf: configURL)

        capture.stderr = ""
        capture.stdout = ""
        let initCode = await cli.run(arguments: ["init"])
        XCTAssertEqual(initCode, 0)
        XCTAssertEqual(try Data(contentsOf: configURL), malformedContents)
        XCTAssertTrue(capture.stdout.contains("Config already exists"))
    }

    func testNamedTempRecipePathValidatesWithTheProductionCLI() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recipesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("recipes")
        let recipes = try FileManager.default.contentsOfDirectory(
            at: recipesDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "toml" }.sorted { $0.path < $1.path }
        XCTAssertEqual(recipes.count, 10)

        for recipeURL in recipes {
            let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: recipeURL, to: configURL)
            let capture = CLIOutputCapture()
            let cli = PinchosCLI(configPath: configURL.path, output: capture.output)
            let code = await cli.run(arguments: ["validate"])
            XCTAssertEqual(code, 0, "\(recipeURL.lastPathComponent) failed validate: \(capture.stderr)")
            XCTAssertTrue(capture.stdout.contains("Valid config"))
            try FileManager.default.removeItem(at: configURL)
        }

        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("example/pinchos.toml")
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.copyItem(at: exampleURL, to: configURL)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)
        let exampleCode = await cli.run(arguments: ["validate"])
        XCTAssertEqual(exampleCode, 0, capture.stderr)
        XCTAssertTrue(capture.stdout.contains("Valid config"), capture.stdout)
    }

    func testExecutableValidateUsesXDGConfigHomeForACopiedRecipe() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recipeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("recipes/clock.toml")
        let configDirectory = root.appendingPathComponent("pinchos", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: recipeURL,
            to: configDirectory.appendingPathComponent("pinchos.toml")
        )

        let process = Process()
        process.executableURL = try PinchosTestExecutable.resolve()
        process.arguments = ["validate"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errors)
        XCTAssertTrue(output.contains("Valid config"), output)
        XCTAssertTrue(output.contains(root.path), output)
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

        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("[UNKNOWN] item.compound.run"))
        XCTAssertTrue(capture.stdout.contains("compound shell expression"))
        XCTAssertTrue(capture.stdout.contains("not statically inspected"))
        XCTAssertFalse(capture.stdout.contains("[FAIL] item.compound.run"))
        XCTAssertFalse(capture.stdout.contains("not found"))
        XCTAssertFalse(capture.stdout.contains("definitely_missing_pinchos_command"))
    }

    func testDoctorResolvesUnquotedTildeHomePathAndDoesNotCallBuiltinsMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let remainder = root.appendingPathComponent(".local/opt/remainder/v0.2.1/remainder")
        try FileManager.default.createDirectory(
            at: remainder.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: remainder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remainder.path)
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.remainder]
        run = "~/.local/opt/remainder/v0.2.1/remainder value"

        [[item.remainder.menu]]
        label = "Usage"
        run = "~/.local/opt/remainder/v0.2.1/remainder value"

        [[item.remainder.menu]]
        label = "Export"
        action = "export FOO=1"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.path
        ])
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            executionPolicy: policy
        )

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("[PASS] item.remainder.run"))
        XCTAssertTrue(capture.stdout.contains(remainder.path))
        XCTAssertTrue(capture.stdout.contains("[PASS] item.remainder.menu[0].run"))
        XCTAssertTrue(capture.stdout.contains("[UNKNOWN] item.remainder.menu[1].action"))
        XCTAssertFalse(capture.stdout.contains("not found"))
        XCTAssertFalse(capture.stdout.contains("[FAIL] item.remainder"))
    }

    func testDoctorReportsUnterminatedQuoteAsAProblem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.broken]
        run = "echo 'hi"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.broken.run"))
        XCTAssertTrue(capture.stdout.contains("unterminated quote or escape"))
        XCTAssertFalse(capture.stdout.contains("[UNKNOWN] item.broken.run"))
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

    func testDoctorResolvesHomebrewToolsUnderLaunchdPATHWithoutDumpingSecrets() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let brew = "/opt/homebrew/bin/brew"
        let jq = "/opt/homebrew/bin/jq"
        let tool = FileManager.default.isExecutableFile(atPath: jq) ? "jq"
            : FileManager.default.isExecutableFile(atPath: brew) ? "brew"
            : "ls"
        try """
        [item.tools]
        run = "\(tool) --help"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let secret = "pinchos-doctor-secret-\(UUID().uuidString)"
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "PINCHOS_SECRET": secret,
            "AWS_SECRET_ACCESS_KEY": secret
        ])
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            executionPolicy: policy
        )

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("[PASS] item.tools.run"))
        XCTAssertTrue(capture.stdout.contains("PATH uses Homebrew, /usr/local/bin, and system directories"))
        if tool == "jq" {
            XCTAssertTrue(capture.stdout.contains(jq))
        } else if tool == "brew" {
            XCTAssertTrue(capture.stdout.contains(brew))
        }
        let combined = capture.stdout + capture.stderr
        XCTAssertFalse(combined.contains(secret))
        XCTAssertFalse(combined.contains("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(combined.contains("PINCHOS_SECRET="))
        XCTAssertFalse(combined.contains("/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    func testDoctorFailsWhenWorkingDirectoryIsMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.clock]
        run = "true"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let staleHome = root.appendingPathComponent("missing-home-\(UUID().uuidString)")
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": staleHome.path
        ])
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            executionPolicy: policy
        )

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[PASS] execution environment: PATH uses Homebrew, /usr/local/bin, and system directories"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] execution environment"))
        XCTAssertTrue(capture.stdout.contains("working directory cannot be resolved"))
        XCTAssertTrue(capture.stdout.contains(staleHome.path))
        XCTAssertFalse(capture.stdout.contains("[PASS] execution environment: working directory is available"))
    }

    func testDoctorReportsAbsentToolsHelpfullyWithoutExecutingOrDumpingSecrets() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.missing]
        run = "definitely_missing_pinchos_command_125"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let secret = "pinchos-doctor-absent-secret-\(UUID().uuidString)"
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "PINCHOS_SECRET": secret
        ])
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            executionPolicy: policy
        )

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.missing.run"))
        XCTAssertTrue(capture.stdout.contains("definitely_missing_pinchos_command_125"))
        XCTAssertTrue(capture.stdout.contains("Homebrew, /usr/local/bin, and system directories"))
        let combined = capture.stdout + capture.stderr
        XCTAssertFalse(combined.contains(secret))
        XCTAssertFalse(combined.contains("PINCHOS_SECRET"))
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

    func testDoctorChecksMenuSourcesAndActionsWithoutExecuting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let runMarker = root.appendingPathComponent("menu-run-executed")
        let actionMarker = root.appendingPathComponent("menu-action-executed")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.safe]
        run = "true"

        [[item.safe.menu]]
        label = "Usage"
        run = "touch '\(runMarker.path)'"

        [[item.safe.menu]]
        label = "Open"
        action = "touch '\(actionMarker.path)'"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: actionMarker.path))
        XCTAssertTrue(capture.stdout.contains("[PASS] item.safe.menu[0].run"))
        XCTAssertTrue(capture.stdout.contains("[PASS] item.safe.menu[1].action"))
        XCTAssertTrue(capture.stdout.contains("/usr/bin/touch") || capture.stdout.contains("/bin/touch"))
    }

    func testDoctorReportsUnknownForCompoundMenuAndActionWithoutCallingThemMissing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.compound]
        run = "true"

        [[item.compound.menu]]
        label = "Usage"
        run = "cd /tmp; definitely_missing_pinchos_menu_command"

        [[item.compound.menu]]
        label = "Open"
        action = "cd /tmp && definitely_missing_pinchos_action_command"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("[UNKNOWN] item.compound.menu[0].run"))
        XCTAssertTrue(capture.stdout.contains("[UNKNOWN] item.compound.menu[1].action"))
        XCTAssertFalse(capture.stdout.contains("not found"))
        XCTAssertFalse(capture.stdout.contains("definitely_missing_pinchos_menu_command"))
        XCTAssertFalse(capture.stdout.contains("definitely_missing_pinchos_action_command"))
    }

    func testDoctorLabelsCliInspectionAndAvailableInstallInfo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.clock]
        run = "true"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        XCTAssertTrue(capture.stdout.contains("Inspection: CLI (fresh static check; not a live GUI cache)"))
        XCTAssertTrue(capture.stdout.contains("Version:"))
        XCTAssertTrue(capture.stdout.contains("Install:"))
        XCTAssertTrue(capture.stdout.contains("Config path: \(configURL.path)"))
        XCTAssertFalse(capture.stdout.contains("live GUI cache snapshot"))
        XCTAssertFalse(capture.stdout.contains("launch at login"))
    }

    func testDoctorRemediatesMissingToolAndUnreadableIcon() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        let iconURL = root.appendingPathComponent("missing.svg")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.bad]
        run = "definitely_missing_pinchos_command_126"
        icon = "\(iconURL.path)"

        [[item.bad.menu]]
        label = "Usage"
        run = "definitely_missing_pinchos_menu_126"

        [[item.bad.menu]]
        label = "Open"
        action = "definitely_missing_pinchos_action_126"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.run"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.menu[0].run"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.menu[1].action"))
        XCTAssertTrue(capture.stdout.contains("install it on that PATH or use an absolute path"))
        XCTAssertTrue(capture.stdout.contains("[FAIL] item.bad.icon"))
        XCTAssertTrue(capture.stdout.contains("use a readable image file or switch to symbol"))
    }

    func testDoctorPrivacyFixtureDoesNotCollectInheritedEnvironmentOrCredentials() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [item.tools]
        run = "ls"

        [[item.tools.menu]]
        label = "Usage"
        run = "ls"

        [[item.tools.menu]]
        label = "Open"
        action = "true"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let secret = "pinchos-doctor-privacy-\(UUID().uuidString)"
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "PINCHOS_SECRET": secret,
            "AWS_SECRET_ACCESS_KEY": secret,
            "SSH_AUTH_SOCK": "/tmp/pinchos-ssh-\(secret).sock"
        ])
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(
            configPath: configURL.path,
            output: capture.output,
            executionPolicy: policy
        )

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 0)
        let combined = capture.stdout + capture.stderr
        XCTAssertFalse(combined.contains(secret))
        XCTAssertFalse(combined.contains("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(combined.contains("PINCHOS_SECRET"))
        XCTAssertFalse(combined.contains("SSH_AUTH_SOCK"))
        XCTAssertFalse(combined.contains("/usr/bin:/bin:/usr/sbin:/sbin"))
        XCTAssertFalse(combined.contains("inherited environment"))
    }

    func testDoctorBoundsLargeUnreadableIconPath() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("pinchos/pinchos.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hugeName = String(repeating: "x", count: 8000)
        try """
        [item.huge]
        run = "true"
        icon = "/tmp/\(hugeName).svg"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let capture = CLIOutputCapture()
        let cli = PinchosCLI(configPath: configURL.path, output: capture.output)

        let doctorCode = await cli.run(arguments: ["doctor"])

        XCTAssertEqual(doctorCode, 4)
        let failLine = try XCTUnwrap(capture.stdout.split(separator: "\n").first { $0.hasPrefix("[FAIL] item.huge.icon") })
        XCTAssertLessThan(failLine.utf8.count, 1024)
        XCTAssertTrue(failLine.contains("truncated") || failLine.count < 8000)
        XCTAssertFalse(capture.stdout.contains(hugeName))
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
