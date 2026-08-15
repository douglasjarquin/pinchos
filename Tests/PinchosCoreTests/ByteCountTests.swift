import XCTest
@testable import PinchosCore

final class ByteCountTests: XCTestCase {
    func testParsesSupportedUnits() throws {
        XCTAssertEqual(try parseByteCount("64B"), 64)
        XCTAssertEqual(try parseByteCount("64KiB"), 64 * 1024)
        XCTAssertEqual(try parseByteCount("2MiB"), 2 * 1024 * 1024)
    }

    func testRejectsZeroAndMalformedValues() {
        for value in ["0B", "64KB", "64kib", "1.5KiB", "-1B", " 64KiB", "64KiB ", ""] {
            XCTAssertThrowsError(try parseByteCount(value), "expected (value) to be rejected")
        }
    }

    func testRejectsOverflow() {
        XCTAssertThrowsError(try parseByteCount("999999999999999999999999MiB"))
    }
}
