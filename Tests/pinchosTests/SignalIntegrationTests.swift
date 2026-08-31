import Darwin
import Foundation
import XCTest

final class SignalIntegrationTests: XCTestCase {
    private struct OwnedProcess: Hashable {
        let pid: pid_t
        let parentPID: pid_t
        let groupID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    func testSIGINTCancelsRunAndRemovesOwnedDescendants() throws {
        try runSignalScenario(signal: SIGINT, expectedExitCode: 130)
    }

    func testSIGTERMCancelsRunAndRemovesOwnedDescendants() throws {
        try runSignalScenario(signal: SIGTERM, expectedExitCode: 143)
    }

    func testDoctorDoesNotExecuteConfiguredRunCommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-doctor-no-run-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("pinchos", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("pinchos.toml")
        let markerURL = root.appendingPathComponent("doctor-run.marker")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"""
        [item.probe]
        run = "touch '\#(markerURL.path)'"
        interval = "manual"
        """#.write(to: configURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try pinchosExecutable()
        process.arguments = ["doctor"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "doctor must inspect configuration without executing item commands"
        )
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testGUISIGTERMCancelsMainRunnerAndRemovesOwnedDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-issue44-gui-signal-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("pinchos", isDirectory: true)
        let configURL = configDirectory.appendingPathComponent("pinchos.toml")
        let markerURL = root.appendingPathComponent("child.pid")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        var process: Process?
        var parentIdentity: OwnedProcess?
        var supervisorIdentity: OwnedProcess?
        var ownedProcesses = Set<OwnedProcess>()
        var ownedPIDs = Set<pid_t>()
        defer {
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            cleanupProcesses(
                processes: ownedProcesses,
                owner: supervisorIdentity,
                parent: parentIdentity
            )
            try? FileManager.default.removeItem(at: root)
        }

        try #"""
        [item.gui]
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
        launchedProcess.standardOutput = FileHandle.nullDevice
        launchedProcess.standardError = FileHandle.nullDevice
        try launchedProcess.run()

        parentIdentity = try XCTUnwrap(processIdentity(for: launchedProcess.processIdentifier))
        let childPID = try waitForPID(at: markerURL)
        XCTAssertEqual(kill(childPID, 0), 0, "GUI marker child must exist before signal delivery")
        let childProcess = try XCTUnwrap(processIdentity(for: childPID))
        let groupID = try XCTUnwrap(processGroupID(for: childPID))
        let groupLeader = try XCTUnwrap(processIdentity(for: groupID))
        supervisorIdentity = groupLeader
        let groupProcesses = processIdentities(in: groupID)
        XCTAssertEqual(groupLeader.parentPID, parentIdentity?.pid)
        XCTAssertTrue(groupProcesses.contains(childProcess))
        XCTAssertTrue(groupProcesses.allSatisfy { isDescendant($0, of: parentIdentity!) })
        ownedProcesses.formUnion(groupProcesses)
        ownedPIDs.formUnion(groupProcesses.map(\.pid))
        XCTAssertTrue(ownedPIDs.contains(childPID), "GUI marker child must be in the owned process group")
        XCTAssertEqual(kill(launchedProcess.processIdentifier, SIGTERM), 0)
        launchedProcess.waitUntilExit()

        XCTAssertTrue(waitUntilGone(childPID), "GUI SIGTERM left owned descendant \(childPID) alive")
        for pid in ownedPIDs {
            XCTAssertTrue(waitUntilGone(pid), "GUI SIGTERM left owned process \(pid) alive")
        }
        XCTAssertTrue(waitUntilGroupGone(groupID), "GUI SIGTERM left owned process group \(groupID) alive")
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
        run = "exit 7"
        """#.write(to: configURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try pinchosExecutable()
        process.arguments = ["run", "normal"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
        var parentIdentity: OwnedProcess?
        var supervisorIdentity: OwnedProcess?
        var ownedProcesses = Set<OwnedProcess>()
        var ownedPIDs = Set<pid_t>()
        defer {
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            cleanupProcesses(
                processes: ownedProcesses,
                owner: supervisorIdentity,
                parent: parentIdentity
            )
            try? FileManager.default.removeItem(at: root)
        }

        try #"""
        [item.long]
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
        launchedProcess.standardOutput = FileHandle.nullDevice
        launchedProcess.standardError = FileHandle.nullDevice
        try launchedProcess.run()

        parentIdentity = try XCTUnwrap(processIdentity(for: launchedProcess.processIdentifier))
        let childPID = try waitForPID(at: markerURL)
        XCTAssertEqual(kill(childPID, 0), 0, "marker child must exist before signal delivery")
        let childProcess = try XCTUnwrap(processIdentity(for: childPID))
        let groupID = try XCTUnwrap(processGroupID(for: childPID))
        let groupLeader = try XCTUnwrap(processIdentity(for: groupID))
        supervisorIdentity = groupLeader
        let groupProcesses = processIdentities(in: groupID)
        XCTAssertEqual(groupLeader.parentPID, parentIdentity?.pid)
        XCTAssertTrue(groupProcesses.contains(childProcess))
        XCTAssertTrue(groupProcesses.allSatisfy { isDescendant($0, of: parentIdentity!) })
        ownedProcesses.formUnion(groupProcesses)
        ownedPIDs.formUnion(groupProcesses.map(\.pid))
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
        XCTAssertTrue(waitUntilGroupGone(groupID), "owned process group \(groupID) survived signal cleanup")
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

    private func cleanupProcesses(
        processes: Set<OwnedProcess>,
        owner: OwnedProcess?,
        parent: OwnedProcess?
    ) {
        guard let owner, let parent,
            owner.parentPID == parent.pid,
            processIdentity(for: owner.pid) == owner,
            processIdentity(for: parent.pid) == parent
        else {
            return
        }

        let killableProcesses = processes.filter {
            processIdentity(for: $0.pid) == $0
                && $0.groupID == owner.groupID
                && isDescendant($0, of: parent)
        }
        for process in killableProcesses {
            _ = kill(process.pid, SIGKILL)
        }
        for process in killableProcesses {
            _ = waitUntilGone(process.pid)
        }
    }

    private func processGroupID(for pid: pid_t) -> pid_t? {
        processIdentity(for: pid)?.groupID
    }

    private func processIDs(in group: pid_t) -> [pid_t] {
        processIdentities(in: group).map(\.pid)
    }

    private func processIdentity(for pid: pid_t) -> OwnedProcess? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
            return nil
        }
        return OwnedProcess(
            pid: pid_t(info.pbi_pid),
            parentPID: pid_t(info.pbi_ppid),
            groupID: pid_t(info.pbi_pgid),
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private func processIdentities(in group: pid_t) -> [OwnedProcess] {
        processTablePIDs().compactMap { processIdentity(for: $0) }.filter { $0.groupID == group }
    }

    private func processTablePIDs() -> [pid_t] {
        let output = runProcess(arguments: ["-axo", "pid="]) ?? ""
        return output.split(whereSeparator: \.isWhitespace).compactMap(parseProcessID)
    }

    private func isDescendant(_ process: OwnedProcess, of ancestor: OwnedProcess) -> Bool {
        if process == ancestor { return true }
        var currentPID = process.parentPID
        var visited = Set<pid_t>()
        while currentPID > 0, visited.insert(currentPID).inserted {
            guard let current = processIdentity(for: currentPID) else { return false }
            if current == ancestor { return true }
            currentPID = current.parentPID
        }
        return false
    }

    private func parseProcessID(_ line: Substring) -> pid_t? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.first.flatMap { pid_t(String($0)) }
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
