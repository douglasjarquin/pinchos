import XCTest
@testable import PinchosCore

final class DurationTests: XCTestCase {
    func testParsesSeconds() throws {
        XCTAssertEqual(try parseDuration("30s"), 30)
    }

    func testParsesMinutes() throws {
        XCTAssertEqual(try parseDuration("5m"), 300)
    }

    func testParsesHours() throws {
        XCTAssertEqual(try parseDuration("1h"), 3600)
    }

    func testMinimumOneSecondIsValid() throws {
        XCTAssertEqual(try parseDuration("1s"), 1)
    }

    func testRejectsBelowMinimum() {
        XCTAssertThrowsError(try parseDuration("0s")) { error in
            guard case DurationParseError.tooSmall(let value) = error else {
                return XCTFail("expected tooSmall, got \(error)")
            }
            XCTAssertEqual(value, 0)
        }
    }

    func testRejectsMissingUnit() {
        XCTAssertThrowsError(try parseDuration("30")) { error in
            guard case DurationParseError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
    }

    func testRejectsUnknownUnit() {
        XCTAssertThrowsError(try parseDuration("30d")) { error in
            guard case DurationParseError.invalidFormat = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
        }
    }

    func testRejectsEmptyString() {
        XCTAssertThrowsError(try parseDuration(""))
    }

    func testRejectsNegative() {
        XCTAssertThrowsError(try parseDuration("-5s"))
    }
}
