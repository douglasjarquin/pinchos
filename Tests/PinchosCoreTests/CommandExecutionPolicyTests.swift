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
        case .missing, .unknown, .invalidSyntax:
            XCTFail("ls must be found on the execution PATH")
        }

        switch policy.inspectExecutable("definitely_missing_pinchos_command_126 --help") {
        case .missing(let command):
            XCTAssertEqual(command, "definitely_missing_pinchos_command_126")
        case .found, .unknown, .invalidSyntax:
            XCTFail("an absent simple command must be missing, not unknown")
        }

        switch policy.inspectExecutable("cd /tmp; definitely_missing_pinchos_command") {
        case .unknown:
            break
        case .found, .missing, .invalidSyntax:
            XCTFail("a compound expression must be unknown, not missing")
        }

        switch policy.inspectExecutable("env PINCHOS_PROBE=1 ls") {
        case .found(let path):
            XCTAssertEqual(path, "/bin/ls")
        case .missing, .unknown, .invalidSyntax:
            XCTFail("env PREFIX=value command must inspect the command, not the env wrapper")
        }

        XCTAssertEqual(
            CommandExecutionPolicy.unknownInspectionMessage,
            "compound shell expression; not statically inspected"
        )
        XCTAssertFalse(String(describing: policy.inspectExecutable("ls")).contains(secret))
        XCTAssertFalse(policy.missingCommandMessage("ls").contains(secret))
    }

    func testInspectExecutableExpandsUnquotedTildeAgainstHOME() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-policy-tilde-\(UUID().uuidString)")
        let remainder = home.appendingPathComponent(".local/opt/remainder/v0.2.1/remainder")
        try FileManager.default.createDirectory(
            at: remainder.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try "#!/bin/sh\nexit 0\n".write(to: remainder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remainder.path)
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path
        ])

        switch policy.inspectExecutable("~/.local/opt/remainder/v0.2.1/remainder value") {
        case .found(let path):
            XCTAssertEqual(path, remainder.path)
        case .missing, .unknown, .invalidSyntax:
            XCTFail("unquoted ~/ must expand against HOME like /bin/sh")
        }

        switch policy.inspectExecutable("'~/.local/opt/remainder/v0.2.1/remainder' value") {
        case .missing(let command):
            XCTAssertEqual(command, "~/.local/opt/remainder/v0.2.1/remainder")
        case .found, .unknown, .invalidSyntax:
            XCTFail("a quoted tilde must stay literal, not expand")
        }
    }

    func testInspectExecutableTreatsShellBuiltinsAsUnknownNotMissing() {
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory()
        ])
        for expression in ["export FOO=1", "eval ls", "source ~/.profile", ".", "exec ls"] {
            switch policy.inspectExecutable(expression) {
            case .unknown:
                break
            case .found, .missing, .invalidSyntax:
                XCTFail("\(expression) must be unknown, not a missing executable")
            }
        }
        switch policy.inspectExecutable("echo `date`") {
        case .unknown:
            break
        case .found, .missing, .invalidSyntax:
            XCTFail("a backtick command word must be unknown, not missing")
        }
    }

    func testInspectExecutableReportsUnterminatedQuoteAsInvalidSyntax() {
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory()
        ])
        switch policy.inspectExecutable("echo 'hi") {
        case .invalidSyntax:
            break
        case .found, .missing, .unknown:
            XCTFail("an unterminated quote must be invalid syntax, not unknown")
        }
        switch policy.inspectExecutable("echo hi\\") {
        case .invalidSyntax:
            break
        case .found, .missing, .unknown:
            XCTFail("a trailing backslash must be invalid syntax, not unknown")
        }
        XCTAssertEqual(
            CommandExecutionPolicy.invalidSyntaxMessage,
            "unterminated quote or escape"
        )
    }

    func testInspectExecutableKeepsEscapedSpacesAndLiteralTilde() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-policy-escape-\(UUID().uuidString)")
        let spaced = home.appendingPathComponent("My Tools/bin/tool")
        let expanded = home.appendingPathComponent("x")
        try FileManager.default.createDirectory(
            at: spaced.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try "#!/bin/sh\nexit 0\n".write(to: spaced, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spaced.path)
        try "#!/bin/sh\nexit 0\n".write(to: expanded, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: expanded.path)
        let policy = CommandExecutionPolicy(inheritedEnvironment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path
        ])

        switch policy.inspectExecutable("\(spaced.path.replacingOccurrences(of: " ", with: "\\ ")) --help") {
        case .found(let path):
            XCTAssertEqual(path, spaced.path)
        case .missing, .unknown, .invalidSyntax:
            XCTFail("an escaped space in the command word must not be invalidSyntax")
        }

        switch policy.inspectExecutable("/definitely/missing/My\\ Tools/bin/tool") {
        case .missing(let command):
            XCTAssertEqual(command, "/definitely/missing/My Tools/bin/tool")
        case .found, .unknown, .invalidSyntax:
            XCTFail("a missing escaped-space path must be missing, not invalidSyntax")
        }

        switch policy.inspectExecutable("~/x") {
        case .found(let path):
            XCTAssertEqual(path, expanded.path)
        case .missing, .unknown, .invalidSyntax:
            XCTFail("unquoted ~/x must still expand")
        }

        switch policy.inspectExecutable("\\~/x") {
        case .missing(let command):
            XCTAssertEqual(command, "~/x")
        case .found:
            XCTFail("\\~/x must stay a literal path and not expand against HOME")
        case .unknown, .invalidSyntax:
            XCTFail("\\~/x must not be unknown or invalidSyntax")
        }

        switch policy.inspectExecutable("grep foo\\.bar file") {
        case .found:
            break
        case .missing, .unknown, .invalidSyntax:
            XCTFail("an escaped dot in an argument must not make the command invalidSyntax")
        }
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
