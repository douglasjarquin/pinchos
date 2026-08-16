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
}
