import Foundation
import XCTest
@testable import PinchosCore

final class CommandExecutionPolicyTests: XCTestCase {
    private let secret = "pinchos-policy-secret-must-never-appear"

    func testGUILikeAndTerminalLikeInheritedPATHComposeTheSamePolicyPATH() {
        let home = NSHomeDirectory()
        let gui = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "PINCHOS_SECRET": secret
        ])
        let terminal = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/Users/test/.local/bin",
            "HOME": home,
            "TERM": "xterm-256color",
            "SSH_AUTH_SOCK": "/tmp/secret-ssh-agent.sock",
            "PINCHOS_SECRET": secret
        ])

        XCTAssertEqual(gui.path, terminal.path)
        XCTAssertEqual(
            CommandExecutionPolicy.pathEntries,
            [
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin"
            ]
        )
        XCTAssertEqual(gui.path, CommandExecutionPolicy.pathEntries.joined(separator: ":"))
        XCTAssertTrue(gui.path.contains("/opt/homebrew/bin"))
        XCTAssertTrue(gui.path.contains("/usr/local/bin"))
        XCTAssertTrue(gui.path.contains("/usr/bin"))
        XCTAssertFalse(gui.path.contains("/Users/test/.local/bin"))

        let guiEnv = gui.environment()
        let terminalEnv = terminal.environment()
        XCTAssertEqual(guiEnv["PATH"], terminalEnv["PATH"])
        XCTAssertEqual(guiEnv["HOME"], home)
        XCTAssertEqual(guiEnv["SHELL"], "/bin/sh")
        XCTAssertNil(guiEnv["PINCHOS_SECRET"])
        XCTAssertNil(terminalEnv["PINCHOS_SECRET"])
        XCTAssertNil(terminalEnv["TERM"])
        XCTAssertFalse(String(describing: guiEnv).contains(secret))
        XCTAssertFalse(gui.missingCommandMessage("jq").contains(secret))
    }

    func testSSHAuthSockIsNotInherited() {
        let sock = "/tmp/pinchos-ssh-agent-\(UUID().uuidString).sock"
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "HOME": NSHomeDirectory(),
            "SSH_AUTH_SOCK": sock
        ])
        XCTAssertFalse(CommandExecutionPolicy.inheritedKeys.contains("SSH_AUTH_SOCK"))
        XCTAssertNil(policy.environment()["SSH_AUTH_SOCK"])
        XCTAssertFalse(String(describing: policy.environment()).contains(sock))
    }

    func testResolveExecutableFindsSystemAndHomebrewToolsUnderLaunchdPATH() {
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "PINCHOS_SECRET": secret
        ])

        XCTAssertEqual(policy.resolveExecutable("ls"), "/bin/ls")
        XCTAssertNil(policy.resolveExecutable("definitely_missing_pinchos_command_125"))
        XCTAssertTrue(
            policy.missingCommandMessage("definitely_missing_pinchos_command_125")
                .contains("Homebrew, /usr/local/bin, and system directories")
        )
        XCTAssertFalse(policy.missingCommandMessage("ls").contains(secret))
        XCTAssertFalse(policy.missingCommandMessage("ls").contains("/usr/bin:/bin:/usr/sbin:/sbin"))

        let brew = "/opt/homebrew/bin/brew"
        if FileManager.default.isExecutableFile(atPath: brew) {
            XCTAssertEqual(policy.resolveExecutable("brew"), brew)
        }
        let jq = "/opt/homebrew/bin/jq"
        if FileManager.default.isExecutableFile(atPath: jq) {
            XCTAssertEqual(policy.resolveExecutable("jq"), jq)
        }
    }

    func testRelativeExecutableResolvesAgainstHOMENotProcessCWD() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-policy-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = home.appendingPathComponent("rel-tool")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path
        ])
        XCTAssertEqual(policy.resolveExecutable("./rel-tool"), tool.path)
    }

    func testSpawnedHOMEAlwaysMatchesWorkingDirectory() {
        let missingInherited = CommandExecutionPolicy(inheritedEnvironment: [:])
        XCTAssertEqual(missingInherited.environment()["HOME"], missingInherited.workingDirectory)
        XCTAssertEqual(missingInherited.workingDirectory, NSHomeDirectory())

        let stale = "/definitely/missing/pinchos-home-\(UUID().uuidString)"
        let staleInherited = CommandExecutionPolicy(inheritedEnvironment: ["HOME": stale])
        XCTAssertEqual(staleInherited.environment()["HOME"], stale)
        XCTAssertEqual(staleInherited.workingDirectory, stale)
    }

    func testInspectExecutableReportsFoundMissingAndUnknownWithoutExecuting() throws {
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "PINCHOS_SECRET": secret
        ])

        switch policy.inspectExecutable("ls -1") {
        case .found(let path):
            XCTAssertEqual(path, "/bin/ls")
        case .missing, .unknown:
            XCTFail("ls must be found on the execution PATH")
        }

        switch policy.inspectExecutable("definitely_missing_pinchos_command_126 --help") {
        case .missing(let command):
            XCTAssertEqual(command, "definitely_missing_pinchos_command_126")
        case .found, .unknown:
            XCTFail("an absent simple command must be missing, not unknown")
        }

        switch policy.inspectExecutable("cd /tmp; definitely_missing_pinchos_command") {
        case .unknown:
            break
        case .found, .missing:
            XCTFail("a compound expression must be unknown, not missing")
        }

        switch policy.inspectExecutable("env PINCHOS_PROBE=1 ls") {
        case .found(let path):
            XCTAssertEqual(path, "/bin/ls")
        case .missing, .unknown:
            XCTFail("env PREFIX=value command must inspect the command, not the env wrapper")
        }

        XCTAssertEqual(
            CommandExecutionPolicy.unknownInspectionMessage,
            "compound shell expression; not statically inspected"
        )
        XCTAssertFalse(String(describing: policy.inspectExecutable("ls")).contains(secret))
        XCTAssertFalse(policy.missingCommandMessage("ls").contains(secret))
    }

    func testRelativeExecutableResolvesAgainstHOMEEvenWhenHOMEDoesNotExist() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-policy-missing-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let decoy = parent.appendingPathComponent("rel-tool")
        try "#!/bin/sh\nexit 0\n".write(to: decoy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoy.path)
        let missingHome = parent.appendingPathComponent("does-not-exist")

        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": missingHome.path
        ])
        XCTAssertNil(
            policy.resolveExecutable("./rel-tool"),
            "a missing HOME must not resolve relative tools against its parent"
        )
    }
}
