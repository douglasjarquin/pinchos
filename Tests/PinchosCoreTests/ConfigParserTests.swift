import Foundation
import XCTest
@testable import PinchosCore

final class ConfigParserTests: XCTestCase {
    func testCanonicalItemWithDefaults() throws {
        let item = try ConfigParser.parse("""
        [item.limits]
        run = "echo 42"
        """).items[0].command
        XCTAssertEqual(item.name, "limits")
        XCTAssertEqual(item.run, "echo 42")
        XCTAssertEqual(item.interval, .scheduled(60))
        XCTAssertEqual(item.timeout, 15)
        XCTAssertNil(item.format)
        XCTAssertNil(item.iconSource)
        XCTAssertTrue(item.menu.isEmpty)
    }

    func testCanonicalItemAcceptsEveryPublicKey() throws {
        let configURL = URL(fileURLWithPath: "/tmp/pinchos/config/pinchos.toml")
        let item = try ConfigParser.parse("""
        [item.limits]
        run = "echo 42"
        interval = "30s"
        timeout = "2s"
        format = "usage {output}%"
        icon = "icons/limits.svg"
        [[item.limits.menu]]
        label = "Usage"
        value = "72%"
        action = "open ."
        """, relativeTo: configURL).items[0].command
        XCTAssertEqual(item.interval, .scheduled(30))
        XCTAssertEqual(item.timeout, 2)
        XCTAssertEqual(item.format, "usage {output}%")
        XCTAssertEqual(item.icon, "/tmp/pinchos/config/icons/limits.svg")
        XCTAssertEqual(item.menu, [MenuRowConfig(label: "Usage", value: "72%", action: "open .")])
        XCTAssertEqual(ConfigParser.supportedRootKeys, ["item"])
        XCTAssertEqual(ConfigParser.supportedItemKeys, ["run", "interval", "timeout", "format", "symbol", "icon", "menu"])
        XCTAssertEqual(ConfigParser.supportedMenuKeys, ["label", "value", "run", "action", "cache", "separator"])
    }

    func testManualIntervalAndSymbolArePreserved() throws {
        let item = try ConfigParser.parse("""
        [item.manual_item]
        run = "echo manual"
        interval = "manual"
        symbol = "gauge.with.dots"
        """).items[0].command
        XCTAssertEqual(item.interval, .manual)
        XCTAssertEqual(item.symbol, "gauge.with.dots")
        XCTAssertNil(item.icon)
    }

    func testItemAndMenuDeclarationOrderIsPreserved() throws {
        let config = try ConfigParser.parse("""
        [item.zebra]
        run = "echo z"
        [[item.zebra.menu]]
        label = "Z one"
        value = "1"
        [[item.zebra.menu]]
        label = "Z two"
        action = "open z"
        [item.apple]
        run = "echo a"
        [[item.apple.menu]]
        label = "A one"
        run = "echo a1"
        """)
        XCTAssertEqual(config.items.map(\.name), ["zebra", "apple"])
        XCTAssertEqual(config.items[0].command.menu.map(\.label), ["Z one", "Z two"])
        XCTAssertEqual(config.items[1].command.menu.map(\.label), ["A one"])
    }

    func testCanonicalExampleParses() throws {
        let config = try ConfigParser.parse(ExampleConfig.text)
        XCTAssertEqual(config.items.map(\.name), ["codex"])
        XCTAssertEqual(config.items[0].command.menu.count, 5)
    }

    func testEmptyAndCommentOnlyConfigsProduceNoItems() throws {
        XCTAssertTrue(try ConfigParser.parse("").items.isEmpty)
        XCTAssertTrue(try ConfigParser.parse("# nothing configured\n").items.isEmpty)
    }

    func testCanonicalMenuRowsAllowEveryValidShape() throws {
        let rows = try ConfigParser.parse("""
        [item.status]
        run = "echo ready"
        [[item.status.menu]]
        label = "State"
        value = "Ready"
        [[item.status.menu]]
        label = "Usage"
        run = "echo 72%"
        cache = "1m"
        [[item.status.menu]]
        label = "Open"
        action = "open ."
        [[item.status.menu]]
        label = "Usage and open"
        run = "echo 72%"
        action = "open ."
        [[item.status.menu]]
        separator = true
        """).items[0].command.menu
        XCTAssertEqual(rows, [
            MenuRowConfig(label: "State", value: "Ready"),
            MenuRowConfig(label: "Usage", run: "echo 72%", cache: 60),
            MenuRowConfig(label: "Open", action: "open ."),
            MenuRowConfig(label: "Usage and open", run: "echo 72%", action: "open ."),
            .separator
        ])
    }

    func testCanonicalRowsBridgeDynamicValuesAndActionsForCurrentRuntime() throws {
        let item = try ConfigParser.parse("""
        [item.codex]
        run = "echo primary"
        [[item.codex.menu]]
        label = "Usage"
        run = "echo usage"
        [[item.codex.menu]]
        label = "Open"
        action = "open ."
        """).items[0].command
        XCTAssertEqual(item.actions, [ItemAction(title: "Open", kind: .command("open ."))])
    }

    func testCanonicalRowsRejectInvalidTypesAndCombinations() {
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Usage"
        value = 72
        """, contains: "item.clock.menu[0].value: type error", line: 5)
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Usage"
        value = "72%"
        run = "quota"
        """, contains: "specify either value or run, not both", line: 6)
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Usage"
        cache = "5m"
        """, contains: "cache requires run", line: 5)
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Usage"
        separator = true
        action = "open ."
        """, contains: "separator = true cannot be combined", line: 5)
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Usage"
        """, contains: "specify value, run, or action", line: 4)
    }

    func testCanonicalRowsRequireNonEmptyFieldsAndValidCache() {
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = " "
        action = "open ."
        """, contains: "label must be a non-empty string", line: 4)
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Usage"
        run = "echo usage"
        cache = "soon"
        """, contains: "invalid cache 'soon'", line: 6)

        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        label = "Good"
        value = "72%"
        [[item.clock.menu]]
        label = "Bad"
        value = 72
        """, contains: "item.clock.menu[1].value: type error", line: 8)
    }

    func testCanonicalItemsRejectWrongTypesAndInvalidDurations() {
        assertParseError("""
        [item.clock]
        run = 42
        """, contains: "item.clock.run: type error", line: 2)
        assertParseError("""
        [item.clock]
        run = "date"
        interval = 30
        """, contains: "item.clock.interval: type error", line: 3)
        assertParseError("""
        [item.clock]
        run = "date"
        timeout = "soon"
        """, contains: "invalid timeout 'soon'", line: 3)
        assertParseError("""
        [item.clock]
        run = "date"
        format = "{status}"
        """, contains: "format may contain only {output}", line: 3)
    }

    func testCanonicalItemsRejectIconConflictsAndInvalidIDs() {
        assertParseError("""
        [item.clock]
        run = "date"
        icon = ""
        """, contains: "item.clock.icon must be a non-empty string", line: 3)
        assertParseError("""
        [item.clock]
        run = "date"
        icon = "clock.svg"
        symbol = "clock"
        """, contains: "icon and symbol are mutually exclusive", line: 4)
        assertParseError("""
        [item."clock"]
        run = "date"
        """, contains: "items must use exactly [item.<id>] tables", line: 1)
    }

    func testCanonicalSchemaRejectsFormerKeysAndUnsupportedRoots() {
        for key in ["type", "shell", "working_directory", "env", "output", "max_output", "error_text", "on_error", "stale_after", "action", "info", "hidden", "triggers", "watch", "notify_on", "notify_cooldown"] {
            assertParseError("""
            [item.clock]
            run = "date"
            \(key) = "removed"
            """, contains: "unknown key", line: 3)
        }
        for root in ["scheduler", "group"] {
            assertParseError("""
            [\(root).example]
            value = "removed"
            """, contains: "unsupported root key or table '\(root)'", line: 1)
        }
    }

    func testCanonicalSchemaRejectsUnknownKeysAndNonCanonicalDeclarations() {
        assertParseError("""
        [item.clock]
        run = "date"
        [[item.clock.menu]]
        lable = "Usage"
        action = "open ."
        """, contains: "unknown key; did you mean 'label'?", line: 4)
        assertParseError("item.clock.run = \"date\"", contains: "root keys must be a single supported table name", line: 1)
        assertParseError("item.clock = { run = \"date\" }", contains: "root keys must be a single supported table name", line: 1)
        assertParseError("""
        [[item.clock]]
        run = "date"
        """, contains: "items and menu rows must use", line: 1)
        assertParseError("""
        [item.clock.extra]
        run = "date"
        """, contains: "items must use exactly [item.<id>] tables", line: 1)
    }

    func testMalformedTomlIsNormalizedWithSourceLine() {
        assertParseError("""
        [item.clock]
        run = "unterminated
        """, contains: "encountered end-of-file", line: 2)
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
            XCTAssertTrue(parseError.message.contains(expected), parseError.message, file: file, line: line)
            XCTAssertEqual(parseError.line, expectedLine, file: file, line: line)
        }
    }
}
