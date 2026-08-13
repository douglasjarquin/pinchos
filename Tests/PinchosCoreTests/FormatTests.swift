import XCTest
@testable import PinchosCore

final class FormatTests: XCTestCase {
    func testAbsentTemplateReturnsRawOutput() {
        XCTAssertEqual(applyFormat(nil, output: "42"), "42")
    }

    func testSubstitutesOutputPlaceholder() {
        XCTAssertEqual(applyFormat("\u{1F440} {output}%", output: "42"), "\u{1F440} 42%")
    }

    func testTemplateWithoutPlaceholderReturnsTemplateVerbatim() {
        XCTAssertEqual(applyFormat("static text", output: "42"), "static text")
    }

    func testMultiplePlaceholdersAllSubstituted() {
        XCTAssertEqual(applyFormat("{output}/{output}", output: "x"), "x/x")
    }

    func testEmptyOutputSubstitutesToEmptyString() {
        XCTAssertEqual(applyFormat("[{output}]", output: ""), "[]")
    }
}
