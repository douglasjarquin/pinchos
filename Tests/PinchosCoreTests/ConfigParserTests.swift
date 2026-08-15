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
        XCTAssertEqual(item.timeout, 15)
        XCTAssertEqual(item.maxOutputBytes, 64 * 1024)
    }

    func testParsesAllFields() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        interval = "30s"
        timeout = "2s"
        max_output = "64KiB"
        format = "\u{1F440} {output}%"
        click = "open https://example.com"
        error_text = "n/a"
        icon = "/path/to/icon.svg"
        """
        let config = try ConfigParser.parse(toml)
        let item = config.items[0]
        XCTAssertEqual(item.interval, 30)
        XCTAssertEqual(item.timeout, 2)
        XCTAssertEqual(item.maxOutputBytes, 64 * 1024)
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

    func testInvalidCommandBoundsThrowWithItemContext() {
        let invalidTimeout = """
        [item.limits]
        type = "command"
        run = "echo 42"
        timeout = "soon"
        """
        XCTAssertThrowsError(try ConfigParser.parse(invalidTimeout)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("limits") == true)
            XCTAssertTrue(parseError?.message.contains("timeout") == true)
        }

        let invalidOutput = """
        [item.limits]
        type = "command"
        run = "echo 42"
        max_output = "64KB"
        """
        XCTAssertThrowsError(try ConfigParser.parse(invalidOutput)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("limits") == true)
            XCTAssertTrue(parseError?.message.contains("max_output") == true)
        }

        let wrongTimeoutType = """
        [item.limits]
        type = "command"
        run = "echo 42"
        timeout = 15
        """
        XCTAssertThrowsError(try ConfigParser.parse(wrongTimeoutType))

        let wrongOutputType = """
        [item.limits]
        type = "command"
        run = "echo 42"
        max_output = 65536
        """
        XCTAssertThrowsError(try ConfigParser.parse(wrongOutputType))
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

    func testExpandsTildeInIconPath() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        icon = "~/Pictures/pinchos.svg"
        """

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(
            config.items[0].icon,
            ("~/Pictures/pinchos.svg" as NSString).expandingTildeInPath
        )
    }

    func testRejectsUnresolvableConfiguredShell() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        shell = ["/definitely/missing/pinchos-shell", "-lc"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("shell") == true)
            XCTAssertTrue(parseError?.message.contains("/definitely/missing/pinchos-shell") == true)
        }
    }

    func testRejectsUnresolvableWorkingDirectory() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        working_directory = "/definitely/missing/pinchos-directory"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("working_directory") == true)
            XCTAssertTrue(parseError?.message.contains("/definitely/missing/pinchos-directory") == true)
        }
    }

    func testRejectsNonStringEnvironmentValue() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"

        [item.limits.env]
        PATH = 42
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("limits.env.PATH") == true)
        }
    }

    func testRejectsEnvironmentNameThatCannotBeExportedToShell() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"

        [item.limits.env]
        BAD-NAME = "value"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("valid environment name") == true)
        }
    }

    func testParsesExecutionSettingsAndResolvesPathsRelativeToConfigFile() throws {
        let configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-config-\(UUID().uuidString)")
        let workingDirectory = configDirectory.appendingPathComponent("src/project")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDirectory) }

        let toml = """
        [item.example]
        type = "command"
        run = "printf ok"
        shell = ["/bin/zsh", "-lc"]
        working_directory = "src/project"
        icon = "icons/status.svg"

        [item.example.env]
        PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        AWS_PROFILE = "production"
        """

        let config = try ConfigParser.parse(toml, relativeTo: configDirectory.appendingPathComponent("pinchos.toml"))
        let item = config.items[0]

        XCTAssertEqual(item.shell, ["/bin/zsh", "-lc"])
        XCTAssertEqual(item.workingDirectory, workingDirectory.path)
        XCTAssertEqual(item.environment, [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "AWS_PROFILE": "production"
        ])
        XCTAssertEqual(item.icon, configDirectory.appendingPathComponent("icons/status.svg").path)
    }

    func testSemanticErrorIncludesItemKeyAndSourceLine() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        interval = "soon"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.limits") == true)
            XCTAssertTrue(parseError?.message.contains("interval") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testSemanticErrorIncludesSourceLineForQuotedDottedItemName() {
        let toml = """
        [item."quoted.dot"]
        type = "command"
        run = "echo 42"
        interval = "soon"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.quoted.dot") == true)
            XCTAssertTrue(parseError?.message.contains("interval") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }
}
