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
        XCTAssertEqual(gui.path, CommandExecutionPolicy.pathEntries.joined(separator: ":"))
        XCTAssertTrue(gui.path.contains("/opt/homebrew/bin"))
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
        XCTAssertNil(terminalEnv["SSH_AUTH_SOCK"])
        XCTAssertFalse(String(describing: guiEnv).contains(secret))
        XCTAssertFalse(gui.missingCommandMessage("jq").contains(secret))
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
                .contains("system plus Apple Silicon Homebrew")
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
