import Darwin
import Foundation
import XCTest

final class SignalIntegrationTests: XCTestCase {
    private struct OwnedProcess: Hashable {
        let pid: pid_t
        let parentPID: pid_t
        let groupID: pid_t
        let startTime: String
        let command: String
    }

    func testSIGINTCancelsRunAndRemovesOwnedDescendants() throws {
        try runSignalScenario(signal: SIGINT, expectedExitCode: 130)
    }

    func testSIGTERMCancelsRunAndRemovesOwnedDescendants() throws {
        try runSignalScenario(signal: SIGTERM, expectedExitCode: 143)
    }

    func testGUISIGTERMCancelsMainRunnerAndRemovesOwnedDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue44-gui-signal-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("pinchos", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("pinchos.toml")
        let markerURL = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        var process: Process?
        var ownedProcesses = Set<OwnedProcess>()
        var ownedPIDs = Set<pid_t>()
        defer {
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            cleanupProcesses(processes: ownedProcesses)
            try? FileManager.default.removeItem(at: root)
        }

        try #"""
        [item.gui]
        type = "command"
        interval = "manual"
        timeout = "1h"
        run = "(trap '' TERM INT; while :; do sleep 1; done) & child_pid=$!; printf '%s' \"$child_pid\" > \"$PINCHOS_MARKER\"; wait \"$child_pid\""
        """#.write(to: configURL, atomically: true, encoding: .utf8)

        let launchedProcess = Process()
        process = launchedProcess
        launchedProcess.executableURL = try pinchosExecutable()
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        environment["PINCHOS_MARKER"] = markerURL.path
        launchedProcess.environment = environment
        launchedProcess.standardOutput = Pipe()
        launchedProcess.standardError = Pipe()
        try launchedProcess.run()

        let childPID = try waitForPID(at: markerURL)
        XCTAssertEqual(kill(childPID, 0), 0, "GUI marker child must exist before signal delivery")
        ownedPIDs.insert(childPID)
        if let childProcess = processIdentity(for: childPID) {
            ownedProcesses.insert(childProcess)
        }
        let groupID = processGroupID(for: childPID)
        if let groupID {
            let groupProcesses = processIdentities(in: groupID)
            ownedProcesses.formUnion(groupProcesses)
            ownedPIDs.formUnion(groupProcesses.map(\.pid))
        }
        XCTAssertTrue(ownedPIDs.contains(childPID), "GUI marker child must be in the owned process group")
        XCTAssertEqual(kill(launchedProcess.processIdentifier, SIGTERM), 0)
        launchedProcess.waitUntilExit()

        XCTAssertTrue(waitUntilGone(childPID), "GUI SIGTERM left owned descendant \(childPID) alive")
        for pid in ownedPIDs {
            XCTAssertTrue(waitUntilGone(pid), "GUI SIGTERM left owned process \(pid) alive")
        }
        if let groupID {
            XCTAssertTrue(waitUntilGroupGone(groupID), "GUI SIGTERM left owned process group \(groupID) alive")
        }
        XCTAssertEqual(launchedProcess.terminationReason, .exit)
    }

    func testRepeatedAndMixedSignalsUseFirstTerminationRequest() throws {
        try runSignalScenario(
            signal: SIGINT,
            expectedExitCode: 130,
            followupSignals: [SIGINT, SIGTERM]
        )
        try runSignalScenario(
            signal: SIGTERM,
            expectedExitCode: 143,
            followupSignals: [SIGTERM, SIGINT]
        )
    }

    func testNormalRunPreservesConfiguredExitCode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue44-normal-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("pinchos", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("pinchos.toml")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"""
        [item.normal]
        type = "command"
        run = "exit 7"
        """#.write(to: configURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try pinchosExecutable()
        process.arguments = ["run", "normal"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 7)
    }

    private func runSignalScenario(
        signal: Int32,
        expectedExitCode: Int32,
        followupSignals: [Int32] = []
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue44-signal-\(signal)-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("pinchos", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("pinchos.toml")
        let markerURL = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        var process: Process?
        var ownedProcesses = Set<OwnedProcess>()
        var ownedPIDs = Set<pid_t>()
        defer {
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            cleanupProcesses(processes: ownedProcesses)
            try? FileManager.default.removeItem(at: root)
        }

        try #"""
        [item.long]
        type = "command"
        run = "(trap '' TERM INT; while :; do sleep 1; done) & child_pid=$!; printf '%s' \"$child_pid\" > \"$PINCHOS_MARKER\"; wait \"$child_pid\""
        """#.write(to: configURL, atomically: true, encoding: .utf8)

        let launchedProcess = Process()
        process = launchedProcess
        launchedProcess.executableURL = try pinchosExecutable()
        launchedProcess.arguments = ["run", "long"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        environment["PINCHOS_MARKER"] = markerURL.path
        launchedProcess.environment = environment
        launchedProcess.standardOutput = Pipe()
        launchedProcess.standardError = Pipe()
        try launchedProcess.run()

        let childPID = try waitForPID(at: markerURL)
        XCTAssertEqual(kill(childPID, 0), 0, "marker child must exist before signal delivery")
        ownedPIDs.insert(childPID)
        if let childProcess = processIdentity(for: childPID) {
            ownedProcesses.insert(childProcess)
        }
        let groupID = processGroupID(for: childPID)
        if let groupID {
            let groupProcesses = processIdentities(in: groupID)
            ownedProcesses.formUnion(groupProcesses)
            ownedPIDs.formUnion(groupProcesses.map(\.pid))
        }
        XCTAssertTrue(ownedPIDs.contains(childPID), "marker child must be in the owned process group")
        let signalStartedAt = Date()
        XCTAssertEqual(kill(launchedProcess.processIdentifier, signal), 0)
        for followupSignal in followupSignals {
            _ = kill(launchedProcess.processIdentifier, followupSignal)
        }
        launchedProcess.waitUntilExit()

        XCTAssertTrue(
            waitUntilGone(childPID),
            "signal must remove owned descendant before Pinchos exits"
        )
        XCTAssertLessThan(Date().timeIntervalSince(signalStartedAt), 5)
        for pid in ownedPIDs {
            XCTAssertTrue(waitUntilGone(pid), "owned process \(pid) survived signal cleanup")
        }
        if let groupID {
            XCTAssertTrue(waitUntilGroupGone(groupID), "owned process group \(groupID) survived signal cleanup")
        }
        XCTAssertEqual(launchedProcess.terminationReason, .exit)
        XCTAssertEqual(launchedProcess.terminationStatus, expectedExitCode)
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
            domain: "SignalIntegrationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate the Pinchos executable in .build"]
        )
    }

    private func waitForPID(at url: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let value = try? String(contentsOf: url, encoding: .utf8), let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(
            domain: "SignalIntegrationTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "command did not write a marker PID"]
        )
    }

    private func waitUntilGone(_ pid: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private func waitUntilGroupGone(_ group: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if processIDs(in: group).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return processIDs(in: group).isEmpty
    }

    private func cleanupProcesses(processes: Set<OwnedProcess>) {
        let killableProcesses = processes.filter { processIdentity(for: $0.pid) == $0 }
        for process in killableProcesses {
            _ = kill(process.pid, SIGKILL)
        }
        for process in killableProcesses {
            _ = waitUntilGone(process.pid)
        }
    }

    private func processGroupID(for pid: pid_t) -> pid_t? {
        let output = runProcess(arguments: ["-p", String(pid), "-o", "pgid="])
        return output.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func processIDs(in group: pid_t) -> [pid_t] {
        processIdentities(in: group).map(\.pid)
    }

    private func processIdentity(for pid: pid_t) -> OwnedProcess? {
        guard let output = runProcess(arguments: ["-p", String(pid), "-o", "pid=,ppid=,pgid=,lstart=,comm="]) else {
            return nil
        }
        return output.split(whereSeparator: \.isNewline).compactMap(parseProcessIdentity).first
    }

    private func processIdentities(in group: pid_t) -> [OwnedProcess] {
        let output = runProcess(arguments: ["-axo", "pid=,ppid=,pgid=,lstart=,comm="]) ?? ""
        return output.split(whereSeparator: \.isNewline).compactMap(parseProcessIdentity).filter {
            $0.groupID == group
        }
    }

    private func parseProcessIdentity(_ line: Substring) -> OwnedProcess? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 9,
            let pid = pid_t(fields[0]),
            let parentPID = pid_t(fields[1]),
            let groupID = pid_t(fields[2])
        else {
            return nil
        }
        return OwnedProcess(
            pid: pid,
            parentPID: parentPID,
            groupID: groupID,
            startTime: fields[3...7].joined(separator: " "),
            command: fields.dropFirst(8).joined(separator: " ")
        )
    }

    private func runProcess(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
