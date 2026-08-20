import Foundation
import XCTest
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

private final class RecordingLaunchctl: LaunchctlRunning {
    private(set) var invocations: [[String]] = []
    var printResult = LaunchctlInvocation(exitCode: 113, stdout: "", stderr: "Could not find service\n")
    var bootstrapResult = LaunchctlInvocation(exitCode: 0, stdout: "", stderr: "")
    var bootoutResult = LaunchctlInvocation(exitCode: 0, stdout: "", stderr: "")
    var enableResult = LaunchctlInvocation(exitCode: 0, stdout: "", stderr: "")

    func run(_ arguments: [String]) -> LaunchctlInvocation {
        invocations.append(arguments)
        switch arguments.first {
        case "print": return printResult
        case "bootstrap": return bootstrapResult
        case "bootout": return bootoutResult
        case "enable": return enableResult
        default: return LaunchctlInvocation(exitCode: 127, stdout: "", stderr: "unscripted launchctl subcommand")
        }
    }
}

@MainActor
final class PinchosCLIServiceTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-cli-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCLI(
        home: URL,
        launchctl: LaunchctlRunning,
        output: CLIOutput,
        currentExecutablePath: String? = "/opt/pinchos/pinchos"
    ) -> PinchosCLI {
        let launchAgentService = LaunchAgentService(
            launchctl: launchctl,
            homeDirectory: home.path,
            userID: 501
        )
        return PinchosCLI(
            configPath: home.appendingPathComponent("pinchos/pinchos.toml").path,
            output: output,
            launchAgentService: launchAgentService,
            currentExecutablePath: { currentExecutablePath }
        )
    }

    func testServiceWithNoSubcommandPrintsHelpAndUsageExitCode() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = makeCLI(home: root, launchctl: RecordingLaunchctl(), output: capture.output)

        let code = await cli.run(arguments: ["service"])

        XCTAssertEqual(code, 2)
        XCTAssertTrue(capture.stdout.contains("Usage: pinchos service <subcommand>"))
    }

    func testServiceRejectsUnknownSubcommand() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = makeCLI(home: root, launchctl: RecordingLaunchctl(), output: capture.output)

        let code = await cli.run(arguments: ["service", "bogus"])

        XCTAssertEqual(code, 2)
        XCTAssertTrue(capture.stderr.contains("unknown service subcommand 'bogus'"))
    }

    func testInstallDefaultsToCurrentExecutablePathAndIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let launchctl = RecordingLaunchctl()
        let cli = makeCLI(home: root, launchctl: launchctl, output: capture.output)

        let firstCode = await cli.run(arguments: ["service", "install"])
        XCTAssertEqual(firstCode, 0)
        XCTAssertTrue(capture.stdout.contains("Installed launch agent"))
        XCTAssertTrue(capture.stdout.contains("/opt/pinchos/pinchos"))

        let plistURL = root.appendingPathComponent("Library/LaunchAgents/com.pinchos.agent.plist")
        let document = try XCTUnwrap(LaunchAgentPlistDocument.decoded(from: try Data(contentsOf: plistURL)))
        XCTAssertEqual(document.programArguments, ["/opt/pinchos/pinchos"])

        launchctl.printResult = LaunchctlInvocation(exitCode: 0, stdout: "state = not running\n", stderr: "")
        capture.stdout = ""
        let secondCode = await cli.run(arguments: ["service", "install"])
        XCTAssertEqual(secondCode, 0)
        XCTAssertTrue(capture.stdout.contains("already installed and enabled"))
    }

    func testInstallHonorsExecutableOverride() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = makeCLI(home: root, launchctl: RecordingLaunchctl(), output: capture.output)

        let code = await cli.run(arguments: ["service", "install", "--executable", "/opt/pinchos/other"])

        XCTAssertEqual(code, 0)
        XCTAssertTrue(capture.stdout.contains("/opt/pinchos/other"))
        let plistURL = root.appendingPathComponent("Library/LaunchAgents/com.pinchos.agent.plist")
        let document = try XCTUnwrap(LaunchAgentPlistDocument.decoded(from: try Data(contentsOf: plistURL)))
        XCTAssertEqual(document.programArguments, ["/opt/pinchos/other"])
    }

    func testInstallRejectsRelativeExecutableOverride() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = makeCLI(home: root, launchctl: RecordingLaunchctl(), output: capture.output)

        let code = await cli.run(arguments: ["service", "install", "--executable", "relative/pinchos"])

        XCTAssertEqual(code, 2)
        XCTAssertTrue(capture.stderr.contains("usage: pinchos service install"))
    }

    func testInstallFailsClearlyWhenCurrentExecutablePathCannotBeResolved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = makeCLI(home: root, launchctl: RecordingLaunchctl(), output: capture.output, currentExecutablePath: nil)

        let code = await cli.run(arguments: ["service", "install"])

        XCTAssertEqual(code, 3)
        XCTAssertTrue(capture.stderr.contains("unable to resolve the current executable's path"))
    }

    func testStatusReportsNotEnabledExitCodeWhenNothingIsInstalled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let cli = makeCLI(home: root, launchctl: RecordingLaunchctl(), output: capture.output)

        let code = await cli.run(arguments: ["service", "status"])

        XCTAssertEqual(code, 1)
        XCTAssertTrue(capture.stdout.contains("Enabled: no"))
        XCTAssertTrue(capture.stdout.contains("Running: no"))
        XCTAssertTrue(capture.stdout.contains("(missing)"))
    }

    func testStatusReportsEnabledAndRunningAfterInstall() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let launchctl = RecordingLaunchctl()
        let cli = makeCLI(home: root, launchctl: launchctl, output: capture.output)
        let installCode = await cli.run(arguments: ["service", "install"])
        XCTAssertEqual(installCode, 0)

        launchctl.printResult = LaunchctlInvocation(
            exitCode: 0,
            stdout: "state = running\npid = 4242\nprogram = /opt/pinchos/pinchos\n",
            stderr: ""
        )
        capture.stdout = ""
        let code = await cli.run(arguments: ["service", "status"])

        XCTAssertEqual(code, 0)
        XCTAssertTrue(capture.stdout.contains("Enabled: yes"))
        XCTAssertTrue(capture.stdout.contains("Running: yes (pid 4242)"))
        XCTAssertTrue(capture.stdout.contains("(present)"))
    }

    func testUninstallIsIdempotentAndRemovesConfiguration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let launchctl = RecordingLaunchctl()
        let cli = makeCLI(home: root, launchctl: launchctl, output: capture.output)
        let installCode = await cli.run(arguments: ["service", "install"])
        XCTAssertEqual(installCode, 0)

        capture.stdout = ""
        let firstUninstallCode = await cli.run(arguments: ["service", "uninstall"])
        XCTAssertEqual(firstUninstallCode, 0)
        XCTAssertTrue(capture.stdout.contains("Uninstalled launch agent"))
        let plistURL = root.appendingPathComponent("Library/LaunchAgents/com.pinchos.agent.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))

        capture.stdout = ""
        let secondUninstallCode = await cli.run(arguments: ["service", "uninstall"])
        XCTAssertEqual(secondUninstallCode, 0)
        XCTAssertTrue(capture.stdout.contains("already not installed"))
    }

    func testServiceHelpVariantsExitZeroWithoutSideEffects() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = CLIOutputCapture()
        let launchctl = RecordingLaunchctl()
        let cli = makeCLI(home: root, launchctl: launchctl, output: capture.output)

        for arguments in [["service", "--help"], ["service", "install", "--help"], ["service", "status", "--help"], ["service", "uninstall", "--help"]] {
            capture.stdout = ""
            let code = await cli.run(arguments: arguments)
            XCTAssertEqual(code, 0, "\(arguments) should exit 0")
            XCTAssertFalse(capture.stdout.isEmpty)
        }
        XCTAssertTrue(launchctl.invocations.isEmpty, "help output must never shell out to launchctl")
    }
}
