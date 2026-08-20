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

    func testTooltipRendersRuntimePlaceholdersAndEscapedBraces() {
        let state = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: "full\nvalue\n",
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdatedAt: Date(timeIntervalSince1970: 1_699_999_940),
            lastExecution: CommandExecution(
                terminalReason: .exited(code: 0),
                stdout: "full\nvalue\n",
                stderr: "",
                stdoutBytesRead: 11,
                stderrBytesRead: 0,
                stdoutTruncated: false,
                stderrTruncated: false,
                duration: 0.125
            ),
            staleAfter: 900,
            skippedRefreshes: 0,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )

        XCTAssertEqual(
            renderTooltip("{{value}}={output}; updated={updated_at}; attempted={attempted_at}; duration={duration}; exit={exit_status}; error={error}; stale={stale}; status={status}", state: state),
            "{value}=full\nvalue\n; updated=2023-11-14T22:12:20Z; attempted=2023-11-14T22:13:20Z; duration=0.125s; exit=0; error=; stale=no; status=fresh"
        )
    }

    func testUnavailableTooltipValuesRenderAsEmptyStrings() {
        let state = ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: nil,
            lastAttemptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdatedAt: nil,
            lastExecution: CommandExecution(
                terminalReason: .exited(code: 7),
                stdout: "",
                stderr: "failed\n",
                stdoutBytesRead: 0,
                stderrBytesRead: 7,
                stdoutTruncated: false,
                stderrTruncated: false,
                duration: 0.5
            ),
            staleAfter: 900,
            skippedRefreshes: 0,
            now: Date(timeIntervalSince1970: 1_700_000_001)
        )

        XCTAssertEqual(
            renderTooltip("value={output}; updated={updated_at}; attempted={attempted_at}; error={error}", state: state),
            "value=; updated=; attempted=2023-11-14T22:13:20Z; error=failed"
        )
    }

    func testTooltipTemplateRejectsUnknownPlaceholdersAndUnmatchedBraces() {
        XCTAssertThrowsError(try validateTooltipTemplate("{unknown}"))
        XCTAssertThrowsError(try validateTooltipTemplate("{output"))
        XCTAssertThrowsError(try validateTooltipTemplate("output}"))
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
