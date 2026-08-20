import Foundation
import XCTest
@testable import pinchos

/// Records every invocation and returns scripted results keyed by the
/// launchctl subcommand (`print`, `bootstrap`, `bootout`, `enable`), so
/// `LaunchAgentService`'s decision logic can be exercised deterministically
/// without touching the real per-user launchd domain.
private final class FakeLaunchctl: LaunchctlRunning {
    private(set) var invocations: [[String]] = []
    var results: [String: LaunchctlInvocation] = [
        "print": LaunchctlInvocation(exitCode: 113, stdout: "", stderr: "Could not find service\n"),
        "bootstrap": LaunchctlInvocation(exitCode: 0, stdout: "", stderr: ""),
        "bootout": LaunchctlInvocation(exitCode: 0, stdout: "", stderr: ""),
        "enable": LaunchctlInvocation(exitCode: 0, stdout: "", stderr: "")
    ]

    func run(_ arguments: [String]) -> LaunchctlInvocation {
        invocations.append(arguments)
        guard let subcommand = arguments.first, let result = results[subcommand] else {
            return LaunchctlInvocation(exitCode: 127, stdout: "", stderr: "unscripted launchctl subcommand")
        }
        return result
    }

    func clearInvocations() {
        invocations.removeAll()
    }

    func setLoaded(running: Bool, program: String? = nil, pid: String = "4242") {
        var lines = ["state = \(running ? "running" : "not running")"]
        if running {
            lines.append("pid = \(pid)")
        }
        if let program {
            lines.append("program = \(program)")
        }
        results["print"] = LaunchctlInvocation(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }
}

final class LaunchAgentServiceTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-launch-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeService(homeDirectory: URL, launchctl: LaunchctlRunning) -> LaunchAgentService {
        LaunchAgentService(
            fileManager: .default,
            launchctl: launchctl,
            homeDirectory: homeDirectory.path,
            userID: 501
        )
    }

    // MARK: - Plist generation

    func testGeneratedPlistContainsDeterministicConfiguration() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        let executablePath = "/opt/pinchos/pinchos"

        let document = service.makeDocument(executablePath: executablePath)
        let data = try document.encodedPlist()
        let decoded = try XCTUnwrap(LaunchAgentPlistDocument.decoded(from: data))

        XCTAssertEqual(decoded.label, "com.pinchos.agent")
        XCTAssertEqual(decoded.programArguments, [executablePath])
        XCTAssertTrue(decoded.runAtLoad)
        XCTAssertEqual(decoded.workingDirectory, home.path)
        XCTAssertEqual(decoded.standardOutPath, home.appendingPathComponent("Library/Logs/pinchos/pinchos.log").path)
        XCTAssertEqual(decoded.standardErrorPath, home.appendingPathComponent("Library/Logs/pinchos/pinchos.err.log").path)
        XCTAssertEqual(decoded.environmentVariables["HOME"], home.path)
        // The environment must not depend on any interactive shell profile:
        // PATH is set explicitly to a fixed, documented value.
        XCTAssertEqual(decoded.environmentVariables["PATH"], LaunchAgentService.deterministicPATH)
    }

    func testPlistPathIsFixedRegardlessOfTargetExecutable() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = makeService(homeDirectory: home, launchctl: FakeLaunchctl())

        XCTAssertEqual(service.plistURL.path, home.appendingPathComponent("Library/LaunchAgents/com.pinchos.agent.plist").path)
    }

    // MARK: - Install

    func testInstallWritesPlistCreatesDirectoriesAndLoadsWhenNotPreviouslyLoaded() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)

        let outcome = service.install(executablePath: "/opt/pinchos/pinchos")

        XCTAssertEqual(outcome, .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.plistURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.logDirectory.path))
        XCTAssertEqual(fake.invocations.map { $0.first }, ["print", "bootstrap", "enable"])
        XCTAssertEqual(fake.invocations[1], ["bootstrap", service.domainTarget, service.plistURL.path])
    }

    func testInstallIsIdempotentWhenAlreadyLoadedWithMatchingConfiguration() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        let executablePath = "/opt/pinchos/pinchos"

        XCTAssertEqual(service.install(executablePath: executablePath), .installed)

        fake.clearInvocations()
        fake.setLoaded(running: false)

        let secondOutcome = service.install(executablePath: executablePath)

        XCTAssertEqual(secondOutcome, .alreadyInstalled)
        // No plist rewrite, no bootout/bootstrap: a matching, already-loaded
        // install must be a true no-op beyond the status query.
        XCTAssertEqual(fake.invocations.map { $0.first }, ["print"])
    }

    func testInstallReloadsWhenLoadedWithADifferentExecutable() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)

        XCTAssertEqual(service.install(executablePath: "/opt/pinchos/old"), .installed)

        fake.clearInvocations()
        fake.setLoaded(running: false, program: "/opt/pinchos/old")

        let outcome = service.install(executablePath: "/opt/pinchos/new")

        XCTAssertEqual(outcome, .installed)
        XCTAssertEqual(fake.invocations.map { $0.first }, ["print", "bootout", "bootstrap", "enable"])

        let rewritten = try XCTUnwrap(LaunchAgentPlistDocument.decoded(from: try Data(contentsOf: service.plistURL)))
        XCTAssertEqual(rewritten.programArguments, ["/opt/pinchos/new"])
    }

    func testInstallRewritesConfigurationEvenWhenNotCurrentlyLoaded() throws {
        // A plist can exist on disk (e.g. from a previous session) without
        // currently being loaded; install must still converge it rather than
        // trusting stale file contents.
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)

        XCTAssertEqual(service.install(executablePath: "/opt/pinchos/pinchos"), .installed)
        fake.clearInvocations()
        // Not loaded (defaultResult simulates "not found").

        let outcome = service.install(executablePath: "/opt/pinchos/pinchos")

        XCTAssertEqual(outcome, .installed)
        XCTAssertEqual(fake.invocations.map { $0.first }, ["print", "bootstrap", "enable"])
    }

    func testInstallSurfacesBootstrapFailure() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        fake.results["bootstrap"] = LaunchctlInvocation(exitCode: 1, stdout: "", stderr: "Bootstrap failed: 5: Input/output error\n")
        let service = makeService(homeDirectory: home, launchctl: fake)

        let outcome = service.install(executablePath: "/opt/pinchos/pinchos")

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Bootstrap failed"))
    }

    // MARK: - Status

    func testStatusReportsNotInstalledWhenNothingIsConfigured() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = makeService(homeDirectory: home, launchctl: FakeLaunchctl())

        let status = service.status(expectedExecutablePath: "/opt/pinchos/pinchos")

        XCTAssertFalse(status.plistExists)
        XCTAssertNil(status.configuredExecutablePath)
        XCTAssertFalse(status.loaded)
        XCTAssertFalse(status.running)
        XCTAssertNil(status.pid)
        XCTAssertFalse(status.matchesExpectedExecutable)
    }

    func testStatusReportsRunningWithPIDWhenLoadedAndActive() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        let executablePath = "/opt/pinchos/pinchos"
        XCTAssertEqual(service.install(executablePath: executablePath), .installed)
        fake.setLoaded(running: true, program: executablePath, pid: "9001")

        let status = service.status(expectedExecutablePath: executablePath)

        XCTAssertTrue(status.plistExists)
        XCTAssertEqual(status.configuredExecutablePath, executablePath)
        XCTAssertTrue(status.matchesExpectedExecutable)
        XCTAssertTrue(status.loaded)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.pid, "9001")
    }

    func testStatusFlagsExecutableDrift() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        XCTAssertEqual(service.install(executablePath: "/opt/pinchos/old"), .installed)
        fake.setLoaded(running: false, program: "/opt/pinchos/old")

        let status = service.status(expectedExecutablePath: "/opt/pinchos/new")

        XCTAssertEqual(status.configuredExecutablePath, "/opt/pinchos/old")
        XCTAssertFalse(status.matchesExpectedExecutable)
    }

    // MARK: - Uninstall

    func testUninstallIsANoOpWhenNothingIsInstalled() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)

        let outcome = service.uninstall()

        XCTAssertEqual(outcome, .alreadyAbsent)
        XCTAssertEqual(fake.invocations.map { $0.first }, ["print"])
    }

    func testUninstallUnloadsAndRemovesTheConfigurationFile() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        XCTAssertEqual(service.install(executablePath: "/opt/pinchos/pinchos"), .installed)
        fake.setLoaded(running: true)
        fake.clearInvocations()

        let outcome = service.uninstall()

        XCTAssertEqual(outcome, .uninstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.plistURL.path))
        XCTAssertEqual(fake.invocations.map { $0.first }, ["print", "bootout"])
    }

    func testUninstallIsIdempotentAfterASuccessfulUninstall() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        XCTAssertEqual(service.install(executablePath: "/opt/pinchos/pinchos"), .installed)
        XCTAssertEqual(service.uninstall(), .uninstalled)

        let secondOutcome = service.uninstall()

        XCTAssertEqual(secondOutcome, .alreadyAbsent)
    }

    func testUninstallSurfacesBootoutFailureOtherThanNotFound() throws {
        let home = try makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }
        let fake = FakeLaunchctl()
        let service = makeService(homeDirectory: home, launchctl: fake)
        XCTAssertEqual(service.install(executablePath: "/opt/pinchos/pinchos"), .installed)
        fake.setLoaded(running: true)
        fake.results["bootout"] = LaunchctlInvocation(exitCode: 1, stdout: "", stderr: "Bootout failed: 1: Operation not permitted\n")

        let outcome = service.uninstall()

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Bootout failed"))
        // The plist must not be removed if the agent could not be unloaded,
        // to avoid leaving launchd pointing at a deleted file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.plistURL.path))
    }
}
