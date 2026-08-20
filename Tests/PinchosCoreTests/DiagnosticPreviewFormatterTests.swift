import XCTest
@testable import PinchosCore

final class DiagnosticPreviewFormatterTests: XCTestCase {
    // MARK: - Basic pass-through

    func testEmptyTextIsUntruncatedAndEmpty() {
        let preview = DiagnosticPreviewFormatter.preview("", limits: .menuValue)
        XCTAssertEqual(preview.text, "")
        XCTAssertFalse(preview.isTruncated)
    }

    func testShortPlainTextPassesThroughUnchanged() {
        let preview = DiagnosticPreviewFormatter.preview("42%", limits: .menuValue)
        XCTAssertEqual(preview.text, "42%")
        XCTAssertFalse(preview.isTruncated)
    }

    // MARK: - Byte-length boundary: a 64 KiB single-line value

    func test64KiBSingleLineValueProducesAConciseTruncatedPreview() {
        let hugeLine = String(repeating: "x", count: 64 * 1024)
        let preview = DiagnosticPreviewFormatter.preview(hugeLine, limits: .menuValue)

        XCTAssertTrue(preview.isTruncated)
        XCTAssertLessThan(preview.text.utf8.count, 1024, "a 64KiB value must not become a 64KiB menu title")
        XCTAssertTrue(preview.text.contains("65536 bytes"), "the truncation marker must report the true original byte count")
        XCTAssertTrue(preview.text.contains("1 line total"), "a single-line input must be reported as 1 line, not 0 or many")
    }

    func testMenuValueKeepsAFewShortLinesWithoutTruncation() {
        let preview = DiagnosticPreviewFormatter.preview("one\ntwo\nthree", limits: .menuValue)
        XCTAssertFalse(preview.isTruncated)
        XCTAssertEqual(preview.text, "one \u{240A} two \u{240A} three")
    }

    func testMenuValueDropsAndMarksLinesBeyondItsCapEvenWhenShort() {
        let preview = DiagnosticPreviewFormatter.preview("one\ntwo\nthree\nfour", limits: .menuValue)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertTrue(preview.text.contains("4 lines total"))
        XCTAssertFalse(preview.text.contains("four"))
    }

    // MARK: - Line-count boundary: thousands of lines

    func testThousandsOfLinesDoNotProduceAThousandsLineMenuTitleForMenuValue() {
        let manyLines = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let preview = DiagnosticPreviewFormatter.preview(manyLines, limits: .menuValue)

        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.text.contains("\n"), "menuValue must collapse newlines onto one visible line")
        XCTAssertTrue(preview.text.contains("5000 line"), "the truncation marker must report the true original line count")
    }

    func testThousandsOfLinesAreBoundedForTooltipTooButRealNewlinesArePreserved() {
        let manyLines = (1...5000).map { "line \($0)" }.joined(separator: "\n")
        let preview = DiagnosticPreviewFormatter.preview(manyLines, limits: .tooltip)

        XCTAssertTrue(preview.isTruncated)
        let renderedLineCount = preview.text.split(separator: "\n", omittingEmptySubsequences: false).count
        XCTAssertLessThanOrEqual(renderedLineCount, DiagnosticPreviewFormatter.tooltip.maxLines)
        XCTAssertTrue(preview.text.hasPrefix("line 1\nline 2"), "tooltip previews keep genuine line breaks, unlike menu titles")
    }

    // MARK: - Control-character sanitization fixtures

    func testNulAndOtherC0ControlsBecomeVisiblePlaceholders() {
        let preview = DiagnosticPreviewFormatter.preview("a\u{0000}b", limits: .menuValue)
        XCTAssertEqual(preview.text, "a\u{2400}b")
        XCTAssertFalse(preview.isTruncated)
    }

    func testEscapeBecomesAVisiblePlaceholder() {
        let preview = DiagnosticPreviewFormatter.preview("\u{001B}[31mred\u{001B}[0m", limits: .menuValue)
        XCTAssertEqual(preview.text, "\u{241B}[31mred\u{241B}[0m")
    }

    func testTabBecomesAVisiblePlaceholder() {
        let preview = DiagnosticPreviewFormatter.preview("a\tb", limits: .menuValue)
        XCTAssertEqual(preview.text, "a\u{2409}b")
    }

    func testLoneCarriageReturnIsTreatedAsALineBreakLikeLoneLineFeed() {
        let preview = DiagnosticPreviewFormatter.preview("a\rb", limits: .menuValue)
        XCTAssertEqual(preview.text, "a \u{240A} b")
    }

    func testCarriageReturnLineFeedIsTreatedAsOneLineBreakNotTwo() {
        let preview = DiagnosticPreviewFormatter.preview("a\r\nb", limits: .menuValue)
        XCTAssertEqual(preview.text, "a \u{240A} b")
    }

    func testDeleteBecomesAVisiblePlaceholder() {
        let preview = DiagnosticPreviewFormatter.preview("a\u{007F}b", limits: .menuValue)
        XCTAssertEqual(preview.text, "a\u{2421}b")
    }

    func testC1ControlsBecomeAReplacementCharacter() {
        let preview = DiagnosticPreviewFormatter.preview("a\u{0085}b", limits: .menuValue)
        XCTAssertEqual(preview.text, "a\u{FFFD}b")
    }

    func testBidiControlsBecomeAReplacementCharacter() {
        let preview = DiagnosticPreviewFormatter.preview("a\u{202E}b\u{202C}c", limits: .menuValue)
        XCTAssertEqual(preview.text, "a\u{FFFD}b\u{FFFD}c")
    }

    func testOrdinaryUnicodePassesThroughUnsanitized() {
        let preview = DiagnosticPreviewFormatter.preview("café \u{1F600} \u{00E9}\u{0301}", limits: .menuValue)
        XCTAssertEqual(preview.text, "café \u{1F600} \u{00E9}\u{0301}")
        XCTAssertFalse(preview.isTruncated)
    }

    // MARK: - Grapheme-cluster-safe truncation at exact boundaries

    func testTruncationDoesNotSplitRegionalIndicatorFlagSequences() {
        let flags = "🇺🇸🇨🇦🇲🇽🇯🇵🇰🇷🇩🇪🇫🇷🇬🇧🇮🇹🇪🇸🇧🇷🇦🇷🇦🇺🇮🇳🇨🇳🇷🇺" // 15 grapheme clusters
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 4, maxUTF8Bytes: 4096, maxLines: 1, collapsesNewlines: true
        )
        let preview = DiagnosticPreviewFormatter.preview(flags, limits: limits)

        XCTAssertTrue(preview.isTruncated)
        let visibleFlags = preview.text.components(separatedBy: " \u{2026} ").first ?? preview.text
        XCTAssertEqual(visibleFlags.count, 4)
        XCTAssertEqual(visibleFlags, "🇺🇸🇨🇦🇲🇽🇯🇵")
    }

    func testTruncationDoesNotSplitZWJFamilyEmoji() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}hello" // family + "hello"
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 1, maxUTF8Bytes: 4096, maxLines: 1, collapsesNewlines: true
        )
        let preview = DiagnosticPreviewFormatter.preview(family, limits: limits)

        XCTAssertTrue(preview.isTruncated)
        let visible = preview.text.components(separatedBy: " \u{2026} ").first ?? preview.text
        XCTAssertEqual(visible, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}")
    }

    func testByteCapDropsWholeGraphemeClustersNotPartialBytes() {
        // Each combining-mark cluster below is multiple UTF-8 bytes; pick a byte
        // budget that lands mid-cluster and confirm the cut backs off to the
        // previous whole cluster instead of emitting invalid/split UTF-8.
        let cluster = "e\u{0301}" // "é" as base + combining acute accent, 3 bytes
        let text = String(repeating: cluster, count: 10)
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 1000, maxUTF8Bytes: 10, maxLines: 1, collapsesNewlines: true
        )
        let preview = DiagnosticPreviewFormatter.preview(text, limits: limits)

        XCTAssertTrue(preview.isTruncated)
        let visible = preview.text.components(separatedBy: " \u{2026} ").first ?? preview.text
        XCTAssertEqual(visible.utf8.count % 3, 0, "byte cap must land on a whole-cluster boundary")
        XCTAssertLessThanOrEqual(visible.utf8.count, 10)
        XCTAssertEqual(visible, String(repeating: cluster, count: visible.count))
    }

    func testExactBoundaryAtMaxGraphemeClustersIsNotTruncated() {
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 5, maxUTF8Bytes: 4096, maxLines: 1, collapsesNewlines: true
        )
        let preview = DiagnosticPreviewFormatter.preview("hello", limits: limits)
        XCTAssertEqual(preview.text, "hello")
        XCTAssertFalse(preview.isTruncated)
    }

    func testOneOverMaxGraphemeClustersIsTruncated() {
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 5, maxUTF8Bytes: 4096, maxLines: 1, collapsesNewlines: true
        )
        let preview = DiagnosticPreviewFormatter.preview("hello!", limits: limits)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertTrue(preview.text.hasPrefix("hello"))
    }

    func testExactBoundaryAtMaxLinesIsNotTruncated() {
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 4096, maxUTF8Bytes: 4096, maxLines: 3, collapsesNewlines: false
        )
        let preview = DiagnosticPreviewFormatter.preview("a\nb\nc", limits: limits)
        XCTAssertEqual(preview.text, "a\nb\nc")
        XCTAssertFalse(preview.isTruncated)
    }

    func testOneOverMaxLinesIsTruncated() {
        let limits = DiagnosticPreviewFormatter.Limits(
            maxGraphemeClusters: 4096, maxUTF8Bytes: 4096, maxLines: 3, collapsesNewlines: false
        )
        let preview = DiagnosticPreviewFormatter.preview("a\nb\nc\nd", limits: limits)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.text.hasPrefix("a\nb\nc\nd"))
    }

    // MARK: - Global-action safety: control-heavy output cannot masquerade as menu structure

    func testControlHeavyOutputCannotProduceRawNewlinesInAMenuValuePreview() {
        let adversarial = "Open Config\nReload Config\nQuit Pinchos\n" + String(repeating: "\r\n", count: 50)
        let preview = DiagnosticPreviewFormatter.preview(adversarial, limits: .menuValue)
        XCTAssertFalse(preview.text.contains("\n"))
        XCTAssertFalse(preview.text.contains("\r"))
    }

    // MARK: - Named limit sanity

    func testMenuValueAndMenuStderrAndActionDiagnosticsAndTooltipHaveDistinctBudgets() {
        XCTAssertEqual(DiagnosticPreviewFormatter.actionDiagnostics, DiagnosticPreviewFormatter.menuStderr)
        XCTAssertTrue(DiagnosticPreviewFormatter.menuValue.collapsesNewlines)
        XCTAssertTrue(DiagnosticPreviewFormatter.menuStderr.collapsesNewlines)
        XCTAssertFalse(DiagnosticPreviewFormatter.tooltip.collapsesNewlines)
        XCTAssertEqual(DiagnosticPreviewFormatter.menuStderr.maxLines, 1)
        XCTAssertGreaterThan(DiagnosticPreviewFormatter.tooltip.maxLines, 1)
        XCTAssertGreaterThan(DiagnosticPreviewFormatter.tooltip.maxGraphemeClusters, DiagnosticPreviewFormatter.menuValue.maxGraphemeClusters)
    }
}
