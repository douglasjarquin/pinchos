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

    func testNilMaxLengthReturnsTextUnchanged() {
        XCTAssertEqual(truncateTitle("hello world", maxLength: nil), "hello world")
    }

    func testTextAtOrBelowMaxLengthIsUnchanged() {
        XCTAssertEqual(truncateTitle("hello", maxLength: 5), "hello")
        XCTAssertEqual(truncateTitle("hi", maxLength: 5), "hi")
    }

    func testTruncatesToMaxLengthMinusOneCharactersPlusEllipsis() {
        let truncated = truncateTitle("hello world", maxLength: 5)
        XCTAssertEqual(truncated, "hell\u{2026}")
        XCTAssertEqual(truncated.count, 5)
    }

    func testMaxLengthOfOneRendersOnlyTheEllipsis() {
        XCTAssertEqual(truncateTitle("hello world", maxLength: 1), "\u{2026}")
    }

    func testTruncationCountsGraphemeClustersNotUnicodeScalarsOrUTF16Units() {
        let flags = "🇺🇸🇨🇦🇲🇽🇯🇵" // 4 grapheme clusters, each a multi-scalar regional-indicator pair
        XCTAssertEqual(flags.count, 4)
        XCTAssertEqual(truncateTitle(flags, maxLength: 2), "🇺🇸\u{2026}")

        let familyEmoji = "👨‍👩‍👧‍👦hi" // ZWJ-joined family emoji is one grapheme cluster, followed by "hi"
        XCTAssertEqual(familyEmoji.count, 3)
        XCTAssertEqual(truncateTitle(familyEmoji, maxLength: 2), "👨‍👩‍👧‍👦\u{2026}")
    }

    func testNonPositiveMaxLengthIsTreatedAsNoCap() {
        XCTAssertEqual(truncateTitle("hello world", maxLength: 0), "hello world")
        XCTAssertEqual(truncateTitle("hello world", maxLength: -1), "hello world")
    }
}
