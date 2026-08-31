import XCTest
@testable import PinchosCore

final class FormatTests: XCTestCase {
    func testApplyFormatDefaultsToOutput() {
        XCTAssertEqual(applyFormat(nil, output: "42"), "42")
    }

    func testApplyFormatReplacesEveryOutputPlaceholder() {
        XCTAssertEqual(
            applyFormat("{output} / {output}", output: "42"),
            "42 / 42"
        )
    }

    func testValidateAcceptsPlainTextAndOutputPlaceholder() throws {
        try validateFormatTemplate("plain text")
        try validateFormatTemplate("usage {output}%")
        try validateFormatTemplate("{output} / {output}")
    }

    func testValidateRejectsUnknownUnclosedAndStrayPlaceholders() {
        for template in ["{status}", "{output", "output}", "{{output}}", "{output}}"] {
            XCTAssertThrowsError(try validateFormatTemplate(template), "expected \(template) to fail")
        }
    }

    func testLastTrimmedLineUsesLastNonEmptyLine() {
        XCTAssertEqual(lastTrimmedLine(of: "first\nsecond\n"), "second")
        XCTAssertEqual(lastTrimmedLine(of: " first \n  \n"), "first")
        XCTAssertEqual(lastTrimmedLine(of: ""), "")
    }
}
