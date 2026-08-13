import XCTest
@testable import PinchosCore

final class ConfigParserTests: XCTestCase {
    func testParsesSingleItemWithDefaults() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.items.count, 1)
        let item = config.items[0]
        XCTAssertEqual(item.name, "limits")
        XCTAssertEqual(item.run, "echo 42")
        XCTAssertEqual(item.interval, 60)
        XCTAssertNil(item.format)
        XCTAssertNil(item.click)
        XCTAssertEqual(item.errorText, "\u{2013}")
    }

    func testParsesAllFields() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        interval = "30s"
        format = "\u{1F440} {output}%"
        click = "open https://example.com"
        error_text = "n/a"
        icon = "/path/to/icon.svg"
        """
        let config = try ConfigParser.parse(toml)
        let item = config.items[0]
        XCTAssertEqual(item.interval, 30)
        XCTAssertEqual(item.format, "\u{1F440} {output}%")
        XCTAssertEqual(item.click, "open https://example.com")
        XCTAssertEqual(item.errorText, "n/a")
        XCTAssertEqual(item.icon, "/path/to/icon.svg")
    }

    func testIconIsOptionalAndNilByDefault() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertNil(config.items[0].icon)
    }

    // TOMLKit's underlying store is alphabetically ordered, not insertion-ordered,
    // so declaration order must survive via a separate mechanism (see ConfigParser).
    func testPreservesDeclarationOrderNotAlphabetical() throws {
        let toml = """
        [item.zebra]
        type = "command"
        run = "echo z"

        [item.apple]
        type = "command"
        run = "echo a"

        [item.mango]
        type = "command"
        run = "echo m"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.items.map(\.name), ["zebra", "apple", "mango"])
    }

    func testEmptyConfigProducesNoItems() throws {
        let config = try ConfigParser.parse("")
        XCTAssertTrue(config.items.isEmpty)
    }

    func testMissingRunThrows() {
        let toml = """
        [item.limits]
        type = "command"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected ConfigParseError, got \(error)")
            }
            XCTAssertTrue(parseError.message.contains("run"))
            XCTAssertTrue(parseError.message.contains("limits"))
        }
    }

    func testMissingTypeThrows() {
        let toml = """
        [item.limits]
        run = "echo 42"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected ConfigParseError, got \(error)")
            }
            XCTAssertTrue(parseError.message.contains("type"))
        }
    }

    func testUnsupportedTypeThrows() {
        let toml = """
        [item.limits]
        type = "clock"
        run = "echo 42"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected ConfigParseError, got \(error)")
            }
            XCTAssertTrue(parseError.message.contains("clock"))
        }
    }

    func testInvalidIntervalThrowsWithItemContext() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        interval = "soon"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected ConfigParseError, got \(error)")
            }
            XCTAssertTrue(parseError.message.contains("limits"))
        }
    }

    func testMalformedTomlSyntaxThrowsWithLineInfo() {
        let toml = """
        [item.limits
        type = "command"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected ConfigParseError, got \(error)")
            }
            XCTAssertNotNil(parseError.line)
        }
    }

    func testFlagshipExampleConfigParsesWithMatchingProviderClickLines() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let exampleURL = repoRoot.appendingPathComponent("example/pinchos.toml")
        let text = try String(contentsOf: exampleURL, encoding: .utf8)
        let config = try ConfigParser.parse(text)

        let claude = try XCTUnwrap(config.items.first(where: { $0.name == "claude" }))
        let codex = try XCTUnwrap(config.items.first(where: { $0.name == "codex" }))

        for item in [claude, codex] {
            let click = try XCTUnwrap(item.click, "\(item.name) is missing a click line")
            XCTAssertTrue(click.hasPrefix("open https://"), "\(item.name) click line should open a usage page URL, got: \(click)")
        }
    }
}
