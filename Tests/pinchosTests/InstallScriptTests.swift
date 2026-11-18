import Foundation
import XCTest

/// Fail-closed regressions for `site/public/install.sh` (#163), run against
/// local `file://` release fixtures. Nothing here is signed, so every case
/// must stop before anything reaches the install directory.
final class InstallScriptTests: XCTestCase {
    private let version = "9.9.9"
    private var artifact: String { "Pinchos-\(version)-macos-arm64.zip" }
    private var fixture: URL!
    private var dist: URL { fixture.appendingPathComponent("dist") }
    private var installDir: URL { fixture.appendingPathComponent("install") }

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        // An unsigned but well-formed bundle: only the signature gate can stop it.
        let bundle = fixture.appendingPathComponent("bundle/Pinchos.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Pinchos.app", dist.appendingPathComponent(artifact).path],
                in: fixture.appendingPathComponent("bundle"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture)
    }

    func testSidecarNamingAnotherFileIsRejectedBeforeExtraction() throws {
        // `shasum -c` would verify /bin/ls here and report OK.
        try writeSidecar(run("/usr/bin/shasum", ["-a", "256", "/bin/ls"]))
        let result = try install()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("checksum file is not"), result.output)
        XCTAssertFalse(result.output.contains("Extracting"), result.output)
        try assertNothingInstalled()
    }

    func testMalformedSidecarsAreRejected() throws {
        let digest = try artifactDigest()
        for sidecar in [
            "",
            "\(digest)  \(artifact)\n\(digest)  \(artifact)\n",
            "\(digest) *\(artifact)\n",
            "\(digest)  dist/\(artifact)\n",
            "\(digest.uppercased())  \(artifact)\n"
        ] {
            try writeSidecar(sidecar)
            let result = try install()
            XCTAssertNotEqual(result.status, 0, "accepted sidecar: \(sidecar.debugDescription)")
            XCTAssertFalse(result.output.contains("Extracting"), "sidecar \(sidecar.debugDescription): \(result.output)")
        }
        try assertNothingInstalled()
    }

    func testDigestMismatchIsRejected() throws {
        try writeSidecar(String(repeating: "0", count: 64) + "  \(artifact)\n")
        let result = try install()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("SHA-256 mismatch"), result.output)
        try assertNothingInstalled()
    }

    func testValidChecksumStillRequiresASignature() throws {
        try writeSidecar("\(try artifactDigest())  \(artifact)\n")
        let result = try install()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("\(artifact): OK"), result.output)
        XCTAssertTrue(result.output.contains("signature verification failed"), result.output)
        try assertNothingInstalled()
    }

    // MARK: - Helpers

    private func artifactDigest() throws -> String {
        let line = try run("/usr/bin/shasum", ["-a", "256", artifact], in: dist)
        return String(line.prefix(64))
    }

    private func writeSidecar(_ contents: String) throws {
        try Data(contents.utf8).write(to: dist.appendingPathComponent("\(artifact).sha256"))
    }

    private func assertNothingInstalled(file: StaticString = #filePath, line: UInt = #line) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: installDir.path)
        XCTAssertEqual(contents, [], "installer left files behind", file: file, line: line)
    }

    private func install() throws -> (status: Int32, output: String) {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("site/public/install.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": fixture.path,
            "TMPDIR": fixture.path,
            "PINCHOS_VERSION": version,
            "PINCHOS_BASE_URL": dist.absoluteString,
            "PINCHOS_INSTALL_DIR": installDir.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments) failed")
        return output
    }
}
