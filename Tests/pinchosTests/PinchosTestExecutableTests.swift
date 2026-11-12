import Foundation
import XCTest

final class PinchosTestExecutableTests: XCTestCase {
    func testSelectsDebugWhenLeftoverReleaseExists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeExecutable(at: PinchosTestExecutable.debugBinary(in: root), marker: "debug")
        try writeExecutable(at: PinchosTestExecutable.releaseBinary(in: root), marker: "stale-release")

        let selected = try PinchosTestExecutable.resolve(from: root)
        XCTAssertEqual(selected, PinchosTestExecutable.debugBinary(in: root))
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "#!/bin/sh\nexit 0 # debug\n")
    }

    func testSelectsDebugWhenReleaseIsAbsent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeExecutable(at: PinchosTestExecutable.debugBinary(in: root), marker: "debug")

        let selected = try PinchosTestExecutable.resolve(from: root)
        XCTAssertEqual(selected, PinchosTestExecutable.debugBinary(in: root))
    }

    func testDoesNotFallBackToReleaseWhenDebugIsMissing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeExecutable(at: PinchosTestExecutable.releaseBinary(in: root), marker: "stale-release")

        XCTAssertThrowsError(try PinchosTestExecutable.resolve(from: root)) { error in
            guard let error = error as? PinchosTestExecutableError else {
                XCTFail("expected PinchosTestExecutableError, got \(error)")
                return
            }
            switch error {
            case .missingDebugBinary(let path):
                XCTAssertEqual(path, PinchosTestExecutable.debugBinary(in: root).path)
            }
        }
    }

    func testDoesNotFallBackToReleaseWhenDebugIsNotExecutable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let debug = PinchosTestExecutable.debugBinary(in: root)
        try FileManager.default.createDirectory(
            at: debug.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "not executable".write(to: debug, atomically: true, encoding: .utf8)
        try writeExecutable(at: PinchosTestExecutable.releaseBinary(in: root), marker: "stale-release")

        XCTAssertThrowsError(try PinchosTestExecutable.resolve(from: root)) { error in
            guard let error = error as? PinchosTestExecutableError else {
                XCTFail("expected PinchosTestExecutableError, got \(error)")
                return
            }
            switch error {
            case .missingDebugBinary:
                break
            }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-test-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeExecutable(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0 # \(marker)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
