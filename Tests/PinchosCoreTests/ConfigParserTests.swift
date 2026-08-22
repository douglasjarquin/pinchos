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
        let item = config.items[0].command
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
        XCTAssertNil(item.maxLength)
        XCTAssertFalse(item.hideWhenEmpty)
        XCTAssertFalse(item.hideOnError)
        XCTAssertFalse(item.iconOnly)
        XCTAssertFalse(item.disabled)
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
        max_length = 24
        hide_when_empty = true
        hide_on_error = true
        icon_only = true
        disabled = true
        """
        let config = try ConfigParser.parse(toml)
        let item = config.items[0].command
        XCTAssertEqual(item.interval, .scheduled(30))
        XCTAssertEqual(item.timeout, 2)
        XCTAssertEqual(item.maxOutputBytes, 64 * 1024)
        XCTAssertEqual(item.format, "\u{1F440} {output}%")
        XCTAssertEqual(item.click, "open https://example.com")
        XCTAssertEqual(item.errorText, "n/a")
        XCTAssertEqual(item.icon, "/path/to/icon.svg")
        XCTAssertNil(item.symbol)
        XCTAssertEqual(item.maxLength, 24)
        XCTAssertTrue(item.hideWhenEmpty)
        XCTAssertTrue(item.hideOnError)
        XCTAssertTrue(item.iconOnly)
        XCTAssertTrue(item.disabled)
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
            (key: "icon", value: "false", expectedMessage: "must be a string"),
            (key: "symbol", value: "false", expectedMessage: "must be a string"),
            (key: "max_length", value: "\"24\"", expectedMessage: "must be an integer"),
            (key: "hide_when_empty", value: "\"yes\"", expectedMessage: "must be a boolean"),
            (key: "hide_on_error", value: "\"yes\"", expectedMessage: "must be a boolean"),
            (key: "icon_only", value: "\"yes\"", expectedMessage: "must be a boolean"),
            (key: "disabled", value: "\"yes\"", expectedMessage: "must be a boolean")
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

    func testInlineActionTableWrongRunUsesParentAssignmentSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        action = [{ title = "Bad", run = 42 }]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.action[0].run: type error") == true)
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

    func testQuotedDottedEnvironmentAssignmentUsesItsSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        env."BAD.NAME" = "value"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.env.BAD.NAME: invalid environment key") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testQuotedDottedEnvironmentTableKeyUsesItsSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"

        [item.clock.env]
        "BAD.NAME" = "value"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.env.BAD.NAME: invalid environment key") == true)
            XCTAssertEqual(parseError?.line, 6)
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
        XCTAssertEqual(ConfigParser.supportedRootKeys, ["item", "scheduler", "group"])
        XCTAssertEqual(ConfigParser.supportedSchedulerKeys, ["max_active_sessions"])
        XCTAssertEqual(ConfigParser.supportedGroupKeys, ["title", "members", "icon", "symbol"])
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
            "icon",
            "symbol",
            "max_length",
            "hide_when_empty",
            "hide_on_error",
            "icon_only",
            "disabled"
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

        let item = try ConfigParser.parse(toml).items[0].command

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
        XCTAssertNil(config.items[0].command.icon)
        XCTAssertNil(config.items[0].command.symbol)
        XCTAssertNil(config.items[0].command.iconSource)
    }

    func testParsesNonEmptySymbolAsNativeSource() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        symbol = "chart.bar.fill"
        """
        let item = try ConfigParser.parse(toml).items[0].command
        XCTAssertEqual(item.symbol, "chart.bar.fill")
        XCTAssertNil(item.icon)
        XCTAssertEqual(item.iconSource, .symbol("chart.bar.fill"))
    }

    func testRejectsEmptySymbolWithItemKeyAndSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        symbol = ""
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.symbol") == true)
            XCTAssertTrue(parseError?.message.contains("non-empty") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testRejectsWhitespaceOnlySymbolWithItemKeyAndSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        symbol = "   "
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.symbol") == true)
            XCTAssertTrue(parseError?.message.contains("non-empty") == true)
            XCTAssertEqual(parseError?.line, 4)
        }
    }

    func testRejectsSymbolAndIconTogetherWithItemKeyAndSourceLine() {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        icon = "/path/to/icon.svg"
        symbol = "chart.bar.fill"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.symbol") == true)
            XCTAssertTrue(parseError?.message.contains("icon") == true)
            XCTAssertTrue(parseError?.message.contains("cannot be combined") == true)
            XCTAssertEqual(parseError?.line, 5)
        }
    }

    func testIconOnlyPathResolutionStaysUnchangedWhenSymbolIsAbsent() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        icon = "/path/to/icon.svg"
        """
        let item = try ConfigParser.parse(toml).items[0].command
        XCTAssertEqual(item.icon, "/path/to/icon.svg")
        XCTAssertNil(item.symbol)
        XCTAssertEqual(item.iconSource, .file("/path/to/icon.svg"))
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

    // MARK: - Item discovery (dotted keys, inline tables, silent-loss guards)

    func testDottedKeyItemDeclarationIsDiscoveredWithFields() throws {
        let toml = """
        item.clock.type = "command"
        item.clock.run = "date '+%H:%M'"
        """

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.map(\.name), ["clock"])
        XCTAssertEqual(config.items[0].command.run, "date '+%H:%M'")
    }

    func testDottedKeyItemDeclarationReportsSourceLineForInvalidField() {
        let toml = """
        item.clock.type = "command"
        item.clock.run = "date"
        item.clock.interval = 5
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock.interval: type error") == true)
            XCTAssertEqual(parseError?.line, 3)
        }
    }

    func testQuotedDottedKeyItemNamePreservesDotsAsOneItem() throws {
        let toml = #"""
        item."my.clock".type = "command"
        item."my.clock".run = "date"
        """#

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.map(\.name), ["my.clock"])
    }

    func testDottedKeyItemsDeclaredBeforeAnyHeaderPreserveOrderWithSubsequentHeaderItems() throws {
        // Dotted keys can only add to the implicit root table before the first `[item.*]`
        // header opens a table; TOML has no syntax to return to root scope afterward.
        let toml = """
        item.apple.type = "command"
        item.apple.run = "echo a"

        [item.banana]
        type = "command"
        run = "echo b"
        """

        let config = try ConfigParser.parse(toml)

        XCTAssertEqual(config.items.map(\.name), ["apple", "banana"])
    }

    func testSingleLineInlineTableItemDeclarationFailsExplicitlyInsteadOfSilentlyDroppingItems() {
        // TOMLKit parses this successfully (`item.clock` is a real table in the parsed tree),
        // but the declaration scanner cannot recover a source order for it. Before this fix,
        // that mismatch silently produced an empty item list; it must now fail explicitly.
        let toml = """
        item = { clock = { type = "command", run = "date '+%H:%M'" } }
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertNotNil(parseError, "expected an explicit ConfigParseError, not a silently empty config")
            XCTAssertTrue(parseError?.message.contains("item") == true)
            XCTAssertTrue(parseError?.message.contains("inline table") == true)
        }
    }

    func testDottedKeyAssignedInlineTableItemFailsExplicitly() {
        let toml = """
        item.clock = { type = "command", run = "date" }
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock") == true)
            XCTAssertTrue(parseError?.message.contains("inline table") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testMultilineInlineTableItemDeclarationFailsRatherThanSilentlyDroppingItems() {
        // This is the exact representative form from the issue. The source scanner rejects the
        // opening `item = {` line before TOMLKit even runs (toml++, as vendored by TOMLKit,
        // additionally rejects multi-line inline tables on its own since it doesn't enable TOML
        // 1.1's unreleased preview support) - either way this must never silently produce an
        // empty item list.
        let toml = """
        item = {
          clock = { type = "command", run = "date '+%H:%M'" }
        }
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertNotNil(parseError, "expected an explicit ConfigParseError, not a silently empty config")
            XCTAssertTrue(parseError?.message.contains("inline table") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }

    func testArrayOfTablesItemDeclarationFailsExplicitlyInsteadOfSilentlyDroppingItems() {
        // `[[item.clock]]` is valid TOML (item.clock becomes an array containing one table),
        // but it is not a supported item declaration form and must not vanish silently.
        let toml = """
        [[item.clock]]
        type = "command"
        run = "date"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock") == true)
            XCTAssertTrue(parseError?.message.contains("not supported") == true)
        }
    }

    func testDottedKeyScalarItemAssignmentReportsTypeErrorInsteadOfSilentlyDroppingItems() {
        let toml = """
        item.clock = "not a table"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.clock: type error") == true)
            XCTAssertTrue(parseError?.message.contains("must be a table") == true)
        }
    }

    func testMultilineStringResemblingItemHeaderDoesNotAffectDiscoveryOrLineMapping() {
        let toml = #"""
        [item.real]
        type = "command"
        run = """
        [item.fake]
        type = "command"
        run = "echo fake"
        """
        interval = 5
        """#

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("item.real.interval: type error") == true)
            XCTAssertEqual(parseError?.line, 8)
        }
    }

    func testAllEntryPointsSeeIdenticalItemsForDottedKeyDeclarations() throws {
        let toml = """
        item.clock.type = "command"
        item.clock.run = "date"

        [item.battery]
        type = "command"
        run = "pmset -g batt"
        """

        let first = try ConfigParser.parse(toml)
        let second = try ConfigParser.parse(toml)

        XCTAssertEqual(first.items.map(\.name), ["clock", "battery"])
        XCTAssertEqual(first.items.map(\.name), second.items.map(\.name))
        XCTAssertEqual(first.items.map(\.command.run), second.items.map(\.command.run))
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

    func testMaxOutputAboveSafeMaximumFailsValidationWithItemKeyAndLineContext() {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        interval = "30s"
        max_output = "9999MiB"
        """
        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            guard let parseError = error as? ConfigParseError else {
                return XCTFail("expected a ConfigParseError, got \(error)")
            }
            XCTAssertTrue(parseError.message.contains("limits"))
            XCTAssertTrue(parseError.message.contains("max_output"))
            XCTAssertEqual(parseError.line, 5)
        }
    }

    func testMaxOutputAtSafeMaximumParsesSuccessfully() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        interval = "30s"
        max_output = "\(maxAllowedOutputBytes / (1024 * 1024))MiB"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.items[0].command.maxOutputBytes, maxAllowedOutputBytes)
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
            let click = try XCTUnwrap(item.command.click, "\(item.name) is missing a click line")
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
            config.items[0].command.icon,
            ("~/Pictures/pinchos.svg" as NSString).expandingTildeInPath
        )
        XCTAssertNil(config.items[0].command.symbol)
    }

    func testSymbolIsNotTildeExpandedOrResolvedRelativeToConfig() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        symbol = "~/chart.bar.fill"
        """

        let config = try ConfigParser.parse(toml, relativeTo: URL(fileURLWithPath: "/tmp/pinchos.toml"))
        XCTAssertEqual(config.items[0].command.symbol, "~/chart.bar.fill")
        XCTAssertNil(config.items[0].command.icon)
        XCTAssertEqual(config.items[0].command.iconSource, .symbol("~/chart.bar.fill"))
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
        let item = config.items[0].command

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
        XCTAssertEqual(config.items[0].command.interval, .manual)
        XCTAssertTrue(config.items[0].command.refreshOnClick)
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

        let item = try XCTUnwrap(ConfigParser.parse(toml).items.first).command

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

    func testMaxLengthRejectsZeroNegativeAndNonIntegerValues() {
        let invalidValues = ["0", "-1", "3.5"]
        for value in invalidValues {
            let toml = """
            [item.limits]
            type = "command"
            run = "echo 42"
            max_length = \(value)
            """
            XCTAssertThrowsError(try ConfigParser.parse(toml), "expected max_length = \(value) to be rejected") { error in
                guard let parseError = error as? ConfigParseError else {
                    return XCTFail("expected ConfigParseError, got \(error)")
                }
                XCTAssertTrue(parseError.message.contains("item.limits.max_length"))
            }
        }
    }

    func testMaxLengthAcceptsPositiveIntegerAndDefaultsToNil() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        max_length = 12
        """
        let item = try ConfigParser.parse(toml).items[0].command
        XCTAssertEqual(item.maxLength, 12)

        let withoutMaxLength = """
        [item.limits]
        type = "command"
        run = "echo 42"
        """
        XCTAssertNil(try ConfigParser.parse(withoutMaxLength).items[0].command.maxLength)
    }

    func testVisibilityAndDisabledBooleansDefaultToFalse() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        """
        let item = try ConfigParser.parse(toml).items[0].command
        XCTAssertFalse(item.hideWhenEmpty)
        XCTAssertFalse(item.hideOnError)
        XCTAssertFalse(item.iconOnly)
        XCTAssertFalse(item.disabled)
    }

    func testVisibilityAndDisabledBooleansAcceptExplicitTrue() throws {
        let toml = """
        [item.limits]
        type = "command"
        run = "echo 42"
        hide_when_empty = true
        hide_on_error = true
        icon_only = true
        disabled = true
        """
        let item = try ConfigParser.parse(toml).items[0].command
        XCTAssertTrue(item.hideWhenEmpty)
        XCTAssertTrue(item.hideOnError)
        XCTAssertTrue(item.iconOnly)
        XCTAssertTrue(item.disabled)
    }

    func testSchedulerSectionDefaultsToNoOverrideWhenAbsent() throws {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertNil(config.scheduler.maxActiveSessions)
    }

    func testSchedulerSectionParsesValidMaxActiveSessionsOverride() throws {
        let toml = """
        [scheduler]
        max_active_sessions = 8

        [item.clock]
        type = "command"
        run = "date"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.scheduler.maxActiveSessions, 8)
        XCTAssertEqual(config.items.map(\.name), ["clock"])
    }

    func testSchedulerSectionAcceptsBoundaryValuesOfTheAllowedRange() throws {
        let lower = CommandScheduler.allowedMaxActiveSessionsRange.lowerBound
        let upper = CommandScheduler.allowedMaxActiveSessionsRange.upperBound

        let lowerConfig = try ConfigParser.parse("""
        [scheduler]
        max_active_sessions = \(lower)
        """)
        XCTAssertEqual(lowerConfig.scheduler.maxActiveSessions, lower)

        let upperConfig = try ConfigParser.parse("""
        [scheduler]
        max_active_sessions = \(upper)
        """)
        XCTAssertEqual(upperConfig.scheduler.maxActiveSessions, upper)
    }

    func testSchedulerSectionRejectsMaxActiveSessionsBelowTheAllowedRange() {
        let tooLow = CommandScheduler.allowedMaxActiveSessionsRange.lowerBound - 1
        let toml = """
        [scheduler]
        max_active_sessions = \(tooLow)
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("scheduler.max_active_sessions must be between") == true)
            XCTAssertEqual(parseError?.line, 2)
        }
    }

    func testSchedulerSectionRejectsMaxActiveSessionsAboveTheAllowedRange() {
        let tooHigh = CommandScheduler.allowedMaxActiveSessionsRange.upperBound + 1
        let toml = """
        [scheduler]
        max_active_sessions = \(tooHigh)
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("scheduler.max_active_sessions must be between") == true)
        }
    }

    func testSchedulerSectionRejectsNonIntegerMaxActiveSessions() {
        let toml = """
        [scheduler]
        max_active_sessions = "four"
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("scheduler.max_active_sessions: type error, must be an integer") == true)
        }
    }

    func testSchedulerSectionRejectsUnknownKeys() {
        let toml = """
        [scheduler]
        max_sessions = 4
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("scheduler.max_sessions: unknown key") == true)
        }
    }

    func testSchedulerSectionRejectsNonTableValue() {
        let toml = "scheduler = 4"

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("scheduler: type error, must be a table") == true)
        }
    }
}
