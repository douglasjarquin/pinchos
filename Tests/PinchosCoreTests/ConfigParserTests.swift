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
        XCTAssertEqual(item.interval, .scheduled(60))
        XCTAssertNil(item.format)
        XCTAssertNil(item.click)
        XCTAssertTrue(item.actions.isEmpty)
        XCTAssertEqual(item.errorText, "\u{2013}")
        XCTAssertEqual(item.onError, .replace)
        XCTAssertNil(item.staleAfter)
        XCTAssertNil(item.tooltip)
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
        XCTAssertEqual(item.interval, .scheduled(30))
        XCTAssertEqual(item.timeout, 2)
        XCTAssertEqual(item.maxOutputBytes, 64 * 1024)
        XCTAssertEqual(item.format, "\u{1F440} {output}%")
        XCTAssertEqual(item.click, "open https://example.com")
        XCTAssertEqual(item.errorText, "n/a")
        XCTAssertEqual(item.icon, "/path/to/icon.svg")
    }

    func testRejectsPresentWrongTypesForEverySupportedField() {
        let invalidFields = [
            (key: "shell", value: "\"/bin/sh\"", expectedMessage: "must be an array"),
            (key: "shell", value: "[42]", expectedMessage: "must be a string"),
            (key: "working_directory", value: "42", expectedMessage: "must be a string"),
            (key: "env", value: "[]", expectedMessage: "must be a table"),
            (key: "interval", value: "5", expectedMessage: "must be a string"),
            (key: "timeout", value: "15", expectedMessage: "must be a string"),
            (key: "max_output", value: "65536", expectedMessage: "must be a string"),
            (key: "format", value: "42", expectedMessage: "must be a string"),
            (key: "click", value: "true", expectedMessage: "must be a string"),
            (key: "refresh_on_click", value: "\"yes\"", expectedMessage: "must be a boolean"),
            (key: "error_text", value: "[]", expectedMessage: "must be a string"),
            (key: "on_error", value: "false", expectedMessage: "must be a string"),
            (key: "stale_after", value: "5", expectedMessage: "must be a string"),
            (key: "tooltip", value: "42", expectedMessage: "must be a string"),
            (key: "action", value: "\"not an array\"", expectedMessage: "must be an array"),
            (key: "icon", value: "false", expectedMessage: "must be a string")
        ]

        for field in invalidFields {
            let toml = """
            [item.clock]
            type = "command"
            run = "date"
            \(field.key) = \(field.value)
            """

            XCTAssertThrowsError(try ConfigParser.parse(toml), "expected \(field.key) to reject") { error in
                guard let parseError = error as? ConfigParseError else {
                    return XCTFail("expected ConfigParseError, got \(error)")
                }
                XCTAssertTrue(parseError.message.contains("item.clock.\(field.key)"))
                XCTAssertTrue(parseError.message.contains(field.expectedMessage))
                XCTAssertEqual(parseError.line, 4)
            }
        }
    }

    func testRejectsUnknownItemKeysWithNearestKeySuggestionAndSourceLine() {
        let cases = [
            (key: "intervall", suggestion: "interval"),
            (key: "max_outpt", suggestion: "max_output")
        ]

        for invalid in cases {
            let toml = """
            [item.clock]
            type = "command"
            run = "date"
            \(invalid.key) = "5s"
            """

            XCTAssertThrowsError(try ConfigParser.parse(toml), "expected \(invalid.key) to reject") { error in
                let parseError = error as? ConfigParseError
                XCTAssertTrue(parseError?.message.contains("item.clock.\(invalid.key)") == true)
                XCTAssertTrue(parseError?.message.contains("unknown key") == true)
                XCTAssertTrue(parseError?.message.contains("did you mean '\(invalid.suggestion)'" ) == true)
                XCTAssertEqual(parseError?.line, 4)
            }
        }
    }

    func testRejectsUnknownKeyAfterCommentedItemHeaderWithSourceLine() {
        let toml = """
        [item.clock] # valid TOML trailing comment
        type = "command"
        run = "date"
        intervall = "5s"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.intervall: unknown key") == true)
            XCTAssertTrue(parseError?.message.contains("did you mean 'interval'") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testPreservesHashInQuotedItemHeaderBeforeTrailingComment() throws {
        let toml = """
        [item."quoted#name"] # valid TOML trailing comment
        type = "command"
        run = "date"
        """

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.map(\.name), ["quoted#name"])
    }

    func testPreservesEscapedQuotedItemHeaderName() throws {
        let toml = #"""
        [item."quoted\u002Ename"]
        type = "command"
        run = "date"
        """#

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.map(\.name), ["quoted.name"])
    }

    func testPreservesEscapedQuotedItemHeaderNameForActionDiagnostics() {
        let toml = #"""
        [item."quoted\u002Ename"]
        type = "command"
        run = "date"

        [[item."quoted\u002Ename".action]]
        title = "Run"
        run = "echo hi"
        unknown = true
        """#

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.quoted.name.action[0].unknown: unknown key") == true)
            XCTAssertEqual(parseError?.line, 8)
        }
    }

    func testQuotedItemNameDoesNotCollideWithNestedActionSourceLines() {
        let toml = """
        [item.a]
        type = "command"
        run = "date"

        [[item.a.action]]
        title = "Run"
        run = "echo hi"

        [item."a.action[0]"]
        type = "command"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.a.action[0]: missing required field 'run'") == true)
            XCTAssertEqual(parseError?.line, 9)
        }
    }

    func testEscapedQuotedKeyUsesAssignmentSourceLine() {
        let toml = #"""
        [item.clock]
        type = "command"
        run = "date"
        "inter\u0076al" = 5
        """#

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.interval: type error") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testEscapedControlInQuotedItemNameCannotEnterDiagnostics() {
        let toml = #"""
        [item."bad\u001Bname"]
        type = "command"
        run = "date"
        unknown = true
        """#

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertFalse(parseError?.message.unicodeScalars.contains { $0.value == 0x1B } == true)
            XCTAssertTrue(parseError?.message.contains("\\u{1B}") == true)
        }
    }

    func testInlineActionArrayElementUsesParentAssignmentSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        action = ["not a table"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.action[0]: type error") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testDottedUnknownAssignmentUsesItsSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        unknown.nested = "value"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.unknown: unknown key") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testRejectsPresentNonTableRootItemWithSourceLine() {
        let toml = "item = \"not-a-table\""

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item: type error, must be a table") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testRejectsUnknownRootKeysWithSourceLine() {
        let toml = """
        unrelated = 1

        [item.clock]
        type = "command"
        run = "date"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("root.unrelated: unknown key") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testRejectsUnknownActionKeysWithIndexAndActionSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"

        [[item.clock.action]]
        title = "Run"
        run = "echo hi"
        unknown = true
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.action[0].unknown") == true)
            XCTAssertTrue(parseError?.message.contains("unknown key") == true)
            XCTAssertEqual(parseError?.line, 8)
        }
    }

    func testRejectsUnknownActionKeyAfterCommentedArrayHeaderWithIndexedSourceLine() {
        let toml = """
        [item."quoted.dot"]
        type = "command"
        run = "date"

        [[item."quoted.dot".action]] # valid TOML trailing comment
        title = "Run"
        run = "echo hi"
        unknown = true
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.quoted.dot.action[0].unknown: unknown key") == true)
            XCTAssertEqual(parseError?.line, 8)
        }
    }

    func testRejectsWrongTypesInsideEnvironmentAndActionTables() {
        let configurations = [
            (
                toml: """
                [item.clock]
                type = "command"
                run = "date"

                [item.clock.env]
                PATH = 42
                """,
                path: "item.clock.env.PATH"
            ),
            (
                toml: """
                [item.clock]
                type = "command"
                run = "date"

                [[item.clock.action]]
                title = 42
                run = "echo hi"
                """,
                path: "item.clock.action[0].title"
            ),
            (
                toml: """
                [item.clock]
                type = "command"
                run = "date"

                [[item.clock.action]]
                title = "Run"
                run = 42
                """,
                path: "item.clock.action[0].run"
            ),
            (
                toml: """
                [item.clock]
                type = "command"
                run = "date"

                [[item.clock.action]]
                title = "Refresh"
                refresh = "yes"
                """,
                path: "item.clock.action[0].refresh"
            )
        ]

        for invalid in configurations {
            XCTAssertThrowsError(try ConfigParser.parse(invalid.toml)) { error in
                let parseError = error as? ConfigParseError
                XCTAssertTrue(parseError?.message.contains(invalid.path) == true)
                XCTAssertTrue(parseError?.message.contains("type error") == true)
            }
        }
    }

    func testRejectsEmptyAndWhitespaceOnlyRunClickAndActionCommands() {
        let configurations = [
            """
            [item.clock]
            type = "command"
            run = ""
            """,
            """
            [item.clock]
            type = "command"
            run = "   \t"
            """,
            """
            [item.clock]
            type = "command"
            run = "date"
            click = "  "
            """,
            """
            [item.clock]
            type = "command"
            run = "date"

            [[item.clock.action]]
            title = "Run"
            run = " \t"
            """
        ]

        for toml in configurations {
            XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
                let parseError = error as? ConfigParseError
                XCTAssertTrue(parseError?.message.contains("non-empty string") == true)
            }
        }
    }

    func testReportsNonStringTypeAndRunAsTypeErrorsNotMissingFields() {
        let cases = [
            (key: "type", value: "42", line: 2),
            (key: "run", value: "42", line: 3)
        ]

        for invalid in cases {
            let toml = """
            [item.clock]
            type = \(invalid.key == "type" ? invalid.value : "\"command\"")
            run = \(invalid.key == "run" ? invalid.value : "\"date\"")
            """

            XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
                let parseError = error as? ConfigParseError
                XCTAssertTrue(parseError?.message.contains("item.clock.\(invalid.key)") == true)
                XCTAssertTrue(parseError?.message.contains("must be a string") == true)
                XCTAssertFalse(parseError?.message.contains("missing required field") == true)
                XCTAssertEqual(parseError?.line, invalid.line)
            }
        }
    }

    func testPreservesQuotedItemNamesAndIndexedNestedActionLines() {
        let toml = """
        [item."quoted.dot"]
        type = "command"
        run = "date"

        [[item."quoted.dot".action]]
        title = "Run"
        run = "echo hi"
        unknown = true
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.quoted.dot.action[0].unknown") == true)
            XCTAssertEqual(parseError?.line, 8)
        }

        let valid = try? ConfigParser.parse("""
        [item."quoted.dot"]
        type = "command"
        run = "date"
        """)
        XCTAssertEqual(valid?.items.map(\.name), ["quoted.dot"])
    }

    func testRepositoryExamplesAndRecipesRemainValid() throws {
        XCTAssertEqual(try ConfigParser.parse(ExampleConfig.text).items.map(\.name), ["clock"])

        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let exampleURL = repoRoot.appendingPathComponent("example/pinchos.toml")
        let text = try String(contentsOf: exampleURL, encoding: .utf8)
        let config = try ConfigParser.parse(text, relativeTo: exampleURL)
        XCTAssertEqual(config.items.map(\.name), ["claude", "codex", "clock", "battery"])
    }

    func testSupportedSchemaEnumeratesEveryCurrentItemAndActionKey() {
        XCTAssertEqual(ConfigParser.supportedRootKeys, ["item"])
        XCTAssertEqual(ConfigParser.supportedItemKeys, [
            "type",
            "run",
            "shell",
            "working_directory",
            "env",
            "interval",
            "timeout",
            "max_output",
            "format",
            "click",
            "refresh_on_click",
            "error_text",
            "on_error",
            "stale_after",
            "tooltip",
            "action",
            "icon"
        ])
        XCTAssertEqual(ConfigParser.supportedActionKeys, ["title", "run", "refresh"])
    }

    func testParsesTooltipErrorPolicyAndStaleAfter() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        on_error = "keep_last"
        stale_after = "15m"
        tooltip = "Updated {updated_at}"
        """

        let item = try ConfigParser.parse(toml).items[0]

        XCTAssertEqual(item.onError, .keepLast)
        XCTAssertEqual(item.staleAfter, 900)
        XCTAssertEqual(item.tooltip, "Updated {updated_at}")
    }

    func testRejectsUnknownTooltipPlaceholder() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        tooltip = "{not_a_placeholder}"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("tooltip") == true)
            XCTAssertTrue(parseError?.message.contains("not_a_placeholder") == true)
        }
    }

    func testRejectsInvalidErrorPolicyAndStaleAfter() {
        let invalidPolicy = """
        [item.limits]
        type = "command"
        run = "echo 42"
        on_error = "discard"
        """
        XCTAssertThrowsError(try ConfigParser.parse(invalidPolicy)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("on_error") == true)
        }

        let invalidStaleAfter = """
        [item.limits]
        type = "command"
        run = "echo 42"
        stale_after = "0s"
        """
        XCTAssertThrowsError(try ConfigParser.parse(invalidStaleAfter)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("stale_after") == true)
        }
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

    func testMissingFieldUsesItemHeaderLineWhenMultilineValueContainsEquals() {
        let toml = "[item.bad]\nrun = \"\"\"\ntype = \"command\"\n\"\"\"\n"

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("missing required field 'type'") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testMissingFieldUsesItemHeaderLineWhenMultilineLiteralContainsEquals() {
        let toml = "[item.bad]\nrun = '''\ntype = \"command\"\n'''\n"

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("missing required field 'type'") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testEscapedMultilineDelimiterDoesNotCreateSourceLineForStringContent() {
        let toml = #"""
        [item.bad]
        run = """
        literal escaped delimiter: \"""
        type = "command"
        """
        """#

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("missing required field 'type'") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testQuotedEnvironmentKeyContainingEqualsUsesItsSourceLine() {
        let toml = """
        [item.bad]
        type = "command"
        run = "echo ok"

        [item.bad.env]
        "BAD=NAME" = "value"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.bad.env.BAD=NAME") == true)
            XCTAssertEqual(parseError?.line, 6)
        }
    }

    func testManualIntervalIsAcceptedForOnDemandItem() throws {
        let toml = """
        [item.expensive]
        type = "command"
        run = "sleep 1; echo value"
        interval = "manual"
        refresh_on_click = true
        """

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.count, 1)
        XCTAssertEqual(config.items[0].interval, .manual)
        XCTAssertTrue(config.items[0].refreshOnClick)
    }

    func testInvalidRefreshOnClickThrowsWithItemContext() {
        let toml = """
        [item.expensive]
        type = "command"
        run = "echo value"
        refresh_on_click = "yes"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("refresh_on_click") == true)
            XCTAssertTrue(parseError?.message.contains("expensive") == true)
        }
    }

    func testDeclarativeActionTablesAreProjectedIntoTheItemModel() throws {
        let toml = """
        [item.codex]
        type = "command"
        run = "echo value"

        [[item.codex.action]]
        title = "Open usage"
        run = "open https://example.com/usage"

        [[item.codex.action]]
        title = "Refresh now"
        refresh = true
        """

        let item = try XCTUnwrap(ConfigParser.parse(toml).items.first)

        XCTAssertEqual(item.actions.map(\.title), ["Open usage", "Refresh now"])
        XCTAssertEqual(item.actions.map(\.kind), [
            .command("open https://example.com/usage"),
            .refresh
        ])
    }

    func testRejectsActionWithoutExactlyOneOperation() {
        let bothOperations = """
        [item.codex]
        type = "command"
        run = "echo value"

        [[item.codex.action]]
        title = "Invalid"
        run = "echo action"
        refresh = true
        """
        let missingOperation = """
        [item.codex]
        type = "command"
        run = "echo value"

        [[item.codex.action]]
        title = "Invalid"
        """

        for toml in [bothOperations, missingOperation] {
            XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
                let parseError = error as? ConfigParseError
                XCTAssertTrue(parseError?.message.contains("action[0]") == true)
            }
        }
    }

    func testRejectsInvalidActionValues() {
        let invalidConfigurations = [
            """
            [item.codex]
            type = "command"
            run = "echo value"

            [[item.codex.action]]
            title = "Invalid"
            run = "echo action"
            refresh = false
            """,
            """
            [item.codex]
            type = "command"
            run = "echo value"

            [[item.codex.action]]
            title = "Invalid"
            refresh = "true"
            """,
            """
            [item.codex]
            type = "command"
            run = "echo value"

            [[item.codex.action]]
            title = " "
            refresh = true
            """,
            """
            [item.codex]
            type = "command"
            run = "echo value"

            [[item.codex.action]]
            title = "Invalid"
            run = "   "
            """
        ]

        for toml in invalidConfigurations {
            XCTAssertThrowsError(try ConfigParser.parse(toml))
        }
    }
}
