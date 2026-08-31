import Foundation
import XCTest
@testable import PinchosCore

final class ConfigParserTests: XCTestCase {
    func testParsesCanonicalItemWithDefaults() throws {
        let config = try ConfigParser.parse("""
        [item.limits]
        run = "echo 42"
        """)

        XCTAssertEqual(config.items, [
            ItemConfig(name: "limits", run: "echo 42")
        ])
        XCTAssertEqual(config.items[0].interval, .scheduled(60))
        XCTAssertEqual(config.items[0].timeout, 15)
        XCTAssertNil(config.items[0].format)
        XCTAssertNil(config.items[0].iconSource)
    }

    func testParsesAllSixPublicKeys() throws {
        let config = try ConfigParser.parse("""
        [item.limits]
        run = "echo 42"
        interval = "30s"
        timeout = "2s"
        format = "usage {output}%"
        symbol = "gauge.with.dots.needle.67percent"
        """)

        XCTAssertEqual(
            config.items[0],
            ItemConfig(
                name: "limits",
                run: "echo 42",
                interval: .scheduled(30),
                timeout: 2,
                format: "usage {output}%",
                symbol: "gauge.with.dots.needle.67percent"
            )
        )
    }

    func testParsesManualInterval() throws {
        let item = try ConfigParser.parse("""
        [item.manual]
        run = "echo manual"
        interval = "manual"
        """).items[0]

        XCTAssertEqual(item.interval, .manual)
    }

    func testResolvesRelativeIconAgainstConfigDirectory() throws {
        let configURL = URL(fileURLWithPath: "/tmp/pinchos/config/pinchos.toml")
        let item = try ConfigParser.parse("""
        [item.weather]
        run = "echo sunny"
        icon = "icons/weather.png"
        """, relativeTo: configURL).items[0]

        XCTAssertEqual(item.icon, "/tmp/pinchos/config/icons/weather.png")
        XCTAssertNil(item.symbol)
    }

    func testPreservesDeclarationOrder() throws {
        let config = try ConfigParser.parse("""
        [item.zebra]
        run = "echo z"

        [item.apple]
        run = "echo a"

        [item.mango]
        run = "echo m"
        """)

        XCTAssertEqual(config.items.map(\.name), ["zebra", "apple", "mango"])
    }

    func testEmptyAndCommentOnlyConfigsProduceNoItems() throws {
        XCTAssertTrue(try ConfigParser.parse("").items.isEmpty)
        XCTAssertTrue(try ConfigParser.parse("# nothing configured\n").items.isEmpty)
    }

    func testHashInsideAStringIsNotTreatedAsAComment() throws {
        let item = try ConfigParser.parse("""
        [item.hash]
        run = "printf '# value'" # actual comment
        """).items[0]

        XCTAssertEqual(item.run, "printf '# value'")
    }

    func testMultilineRunDoesNotConfuseSourceMapping() throws {
        let toml = "[item.script]\nrun = \"\"\"\nprintf first\nprintf second\n\"\"\"\ninterval = \"manual\"\n\n[item.after]\nrun = \"echo after\"\n"
        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.map(\.name), ["script", "after"])
        XCTAssertEqual(config.items[0].interval, .manual)
    }

    func testCanonicalExampleParses() throws {
        let config = try ConfigParser.parse(ExampleConfig.text)

        XCTAssertEqual(config.items.map(\.name), ["clock", "battery"])
        XCTAssertEqual(config.items[0].symbol, "clock")
    }

    func testRejectsMissingEmptyAndWrongTypeRunWithLineContext() {
        assertParseError("""
        [item.missing]
        interval = "1m"
        """, contains: "missing required field 'run'", line: 1)

        assertParseError("""
        [item.empty]
        run = "   "
        """, contains: "run must not be empty", line: 2)

        assertParseError("""
        [item.wrong]
        run = 42
        """, contains: "run must be a string", line: 2)
    }

    func testRejectsWrongTypesAndInvalidDurations() {
        assertParseError("""
        [item.clock]
        run = "date"
        interval = 30
        """, contains: "interval must be a duration string", line: 3)

        assertParseError("""
        [item.clock]
        run = "date"
        interval = "0s"
        """, contains: "invalid interval '0s'", line: 3)

        assertParseError("""
        [item.clock]
        run = "date"
        timeout = 3
        """, contains: "timeout must be a duration string", line: 3)

        assertParseError("""
        [item.clock]
        run = "date"
        timeout = "soon"
        """, contains: "invalid timeout 'soon'", line: 3)
    }

    func testRejectsInvalidFormats() {
        for format in ["{status}", "{output", "output}", "{{output}}"] {
            assertParseError("""
            [item.clock]
            run = "date"
            format = "\(format)"
            """, contains: "invalid format", line: 3)
        }
    }

    func testRejectsEmptyOrWrongTypeIconAndSymbol() {
        assertParseError("""
        [item.clock]
        run = "date"
        icon = ""
        """, contains: "icon must not be empty", line: 3)

        assertParseError("""
        [item.clock]
        run = "date"
        symbol = 42
        """, contains: "symbol must be a string", line: 3)
    }

    func testRejectsIconAndSymbolTogether() {
        assertParseError("""
        [item.clock]
        run = "date"
        icon = "/tmp/clock.png"
        symbol = "clock"
        """, contains: "icon and symbol are mutually exclusive", line: 4)
    }

    func testRejectsEveryRemovedItemKey() {
        let removedKeys = [
            "type", "click", "refresh_on_click", "shell", "working_directory", "env",
            "output", "max_output", "error_text", "on_error", "stale_after", "tooltip",
            "max_length", "hide_when_empty", "hide_on_error", "hidden", "icon_only",
            "disabled", "notify_on", "notify_cooldown", "triggers", "watch",
        ]

        for key in removedKeys {
            assertParseError("""
            [item.clock]
            run = "date"
            \(key) = "removed"
            """, contains: "unknown key '\(key)'", line: 3)
        }
    }

    func testRejectsRemovedRootTables() {
        for root in ["scheduler", "group"] {
            assertParseError("""
            [\(root).example]
            value = "removed"
            """, contains: "unsupported root key or table '\(root)'", line: 1)
        }
    }

    func testRejectsUnknownRootAssignment() {
        assertParseError("title = \"Pinchos\"\n", contains: "unsupported root key or table 'title'", line: 1)
    }

    func testRejectsInlineAndDottedItemDeclarations() {
        assertParseError(
            "item.clock = { run = \"date\" }",
            contains: "dotted and inline declarations are not supported",
            line: 1
        )
        assertParseError(
            "item.clock.run = \"date\"",
            contains: "dotted and inline declarations are not supported",
            line: 1
        )
    }

    func testRejectsArrayNestedAndQuotedItemTables() {
        assertParseError("""
        [[item.clock]]
        run = "date"
        """, contains: "array tables are not supported", line: 1)

        assertParseError("""
        [item.clock.extra]
        run = "date"
        """, contains: "items must use exactly [item.<id>]", line: 1)

        assertParseError("""
        [item."clock"]
        run = "date"
        """, contains: "items must use exactly [item.<id>]", line: 1)
    }

    func testRejectsBareItemTableAndInvalidItemID() {
        assertParseError("""
        [item]
        run = "date"
        """, contains: "items must use [item.<id>]", line: 1)

        assertParseError("""
        [item.clock.work]
        run = "date"
        """, contains: "items must use exactly [item.<id>]", line: 1)
    }

    func testRejectsNestedOrQuotedFieldKeys() {
        assertParseError("""
        [item.clock]
        run.command = "date"
        """, contains: "nested, dotted, or quoted keys are not supported", line: 2)

        assertParseError("""
        [item.clock]
        "run" = "date"
        """, contains: "nested, dotted, or quoted keys are not supported", line: 2)
    }

    func testTOMLSyntaxFailureIsNormalizedWithLineNumber() {
        assertParseError("""
        [item.clock]
        run = "unterminated
        """, contains: "unterminated", line: 2)
    }

    private func assertParseError(
        _ text: String,
        contains expected: String,
        line expectedLine: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ConfigParser.parse(text), file: file, line: line) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected ConfigParseError, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                parseError.message.contains(expected),
                "expected '\(parseError.message)' to contain '\(expected)'",
                file: file,
                line: line
            )
            XCTAssertEqual(parseError.line, expectedLine, file: file, line: line)
        }
    }
}
