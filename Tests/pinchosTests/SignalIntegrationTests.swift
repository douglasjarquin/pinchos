import Darwin
import Foundation
import XCTest

final class SignalIntegrationTests: XCTestCase {
    func testSIGINTCancelsRunAndRemovesOwnedDescendants() throws {
        try runSignalScenario(signal: SIGINT, expectedExitCode: 130)
    }

    func testSIGTERMCancelsRunAndRemovesOwnedDescendants() throws {
        try runSignalScenario(signal: SIGTERM, expectedExitCode: 143)
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
        defer {
            cleanupProcesses(markerURL: markerURL)
            try? FileManager.default.removeItem(at: root)
        }

        try #"""
        [item.long]
        type = "command"
        run = "(trap '' TERM INT; while :; do sleep 1; done) & child_pid=$!; printf '%s' \"$child_pid\" > \"$PINCHOS_MARKER\"; wait \"$child_pid\""
        """#.write(to: configURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try pinchosExecutable()
        process.arguments = ["run", "long"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = root.path
        environment["PINCHOS_MARKER"] = markerURL.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let childPID = try waitForPID(at: markerURL)
        XCTAssertEqual(kill(childPID, 0), 0, "marker child must exist before signal delivery")
        let groupID = processGroupID(for: childPID)
        let ownedPIDs = groupID.map(processIDs(in:)) ?? []
        XCTAssertTrue(ownedPIDs.contains(childPID), "marker child must be in the owned process group")
        let signalStartedAt = Date()
        XCTAssertEqual(kill(process.processIdentifier, signal), 0)
        for followupSignal in followupSignals {
            _ = kill(process.processIdentifier, followupSignal)
        }
        process.waitUntilExit()

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
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, expectedExitCode)
    }

    private func pinchosExecutable() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/pinchos"),
            root.appendingPathComponent(".build/arm64-apple-macosx/release/pinchos")
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

    private func cleanupProcesses(markerURL: URL) {
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
            let markerPID = pid_t(marker.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return
        }
        let processGroup = processGroupID(for: markerPID)
        let pids = processGroup.map(processIDs(in:)) ?? [markerPID]
        for pid in Set(pids) {
            _ = kill(pid, SIGKILL)
        }
        _ = waitUntilGone(markerPID)
    }

    private func processGroupID(for pid: pid_t) -> pid_t? {
        let output = runProcess(arguments: ["-p", String(pid), "-o", "pgid="])
        return output.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func processIDs(in group: pid_t) -> [pid_t] {
        let output = runProcess(arguments: ["-axo", "pid=,pgid="]) ?? ""
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == Substring(String(group)) else { return nil }
            return pid_t(fields[0])
        }
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
            process.waitUntilExit()
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }
}
