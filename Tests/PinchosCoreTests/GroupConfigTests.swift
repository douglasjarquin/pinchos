import XCTest
@testable import PinchosCore

/// Coverage for the grouped-status-items feature (issue #18): parsing
/// `[group.<name>]`, cross-item membership validation, and the
/// `ItemConfig`/`PinchosConfig` model support that visibility and menu
/// building build on. See `GroupStatusItemTests` (pinchosTests) for
/// controller/menu-building coverage and `ConfigDiffTests` for incremental
/// reload coverage.
final class GroupConfigTests: XCTestCase {
    private func members(_ toml: String) -> String {
        """
        [item.claude]
        type = "command"
        run = "echo claude"

        [item.codex]
        type = "command"
        run = "echo codex"

        \(toml)
        """
    }

    func testParsesGroupWithTitleMembersAndIcon() throws {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude", "codex"]
        icon = "/path/to/icon.svg"
        hidden = true
        """)

        let config = try ConfigParser.parse(toml)
        let group = try XCTUnwrap(config.items.first(where: { $0.name == "ai" })).group

        XCTAssertEqual(group.title, "AI")
        XCTAssertEqual(group.members, ["claude", "codex"])
        XCTAssertEqual(group.icon, "/path/to/icon.svg")
        XCTAssertTrue(group.hidden)
    }

    func testGroupWithoutIconDefaultsToNil() throws {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude"]
        """)

        let config = try ConfigParser.parse(toml)
        let group = try XCTUnwrap(config.items.first(where: { $0.name == "ai" })).group
        XCTAssertNil(group.icon)
        XCTAssertNil(group.symbol)
        XCTAssertNil(group.iconSource)
        XCTAssertFalse(group.hidden)
    }

    func testGroupHiddenMustBeBooleanWithGroupContextAndSourceLine() {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude"]
        hidden = "yes"
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.hidden") == true)
            XCTAssertTrue(parseError?.message.contains("must be a boolean") == true)
            XCTAssertEqual(parseError?.line, 12)
        }
    }

    func testGroupParsesSymbolAsNativeSource() throws {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude"]
        symbol = "brain"
        """)

        let config = try ConfigParser.parse(toml)
        let group = try XCTUnwrap(config.items.first(where: { $0.name == "ai" })).group
        XCTAssertEqual(group.symbol, "brain")
        XCTAssertNil(group.icon)
        XCTAssertEqual(group.iconSource, .symbol("brain"))
    }

    func testGroupRejectsEmptySymbolWithKeyAndSourceLine() {
        let toml = members("""
        [group.ai]
        title = "AI"
        symbol = ""
        members = ["claude"]
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.symbol") == true)
            XCTAssertTrue(parseError?.message.contains("non-empty") == true)
        }
    }

    func testGroupRejectsSymbolAndIconTogether() {
        let toml = members("""
        [group.ai]
        title = "AI"
        icon = "/path/to/icon.svg"
        symbol = "brain"
        members = ["claude"]
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.symbol") == true)
            XCTAssertTrue(parseError?.message.contains("cannot be combined") == true)
            XCTAssertTrue(parseError?.message.contains("icon") == true)
        }
    }

    func testGroupRejectsUnknownKey() {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude"]
        colour = "blue"
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.colour: unknown key") == true)
        }
    }

    func testGroupRequiresTitle() {
        let toml = members("""
        [group.ai]
        members = ["claude"]
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai: missing required field 'title'") == true)
        }
    }

    func testGroupRejectsMissingMembers() {
        let toml = members("""
        [group.ai]
        title = "AI"
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai: missing required field 'members'") == true)
        }
    }

    func testGroupRejectsEmptyMembers() {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = []
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.members must not be empty") == true)
        }
    }

    func testGroupRejectsDuplicateMember() {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude", "claude"]
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.members: duplicate member 'claude'") == true)
        }
    }

    func testGroupRejectsUnknownMemberWithLineContext() {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude", "does-not-exist"]
        """)

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group.ai.members: unknown member 'does-not-exist'") == true)
            XCTAssertNotNil(parseError?.line)
        }
    }

    func testDirectGroupMembershipCycleIsRejected() {
        let toml = """
        [group.a]
        title = "A"
        members = ["b"]

        [group.b]
        title = "B"
        members = ["a"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group membership cycle detected") == true)
        }
    }

    func testSelfReferencingGroupCycleIsRejected() {
        let toml = """
        [group.a]
        title = "A"
        members = ["a"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group membership cycle detected") == true)
        }
    }

    func testIndirectThreeGroupCycleIsRejected() {
        let toml = """
        [group.a]
        title = "A"
        members = ["b"]

        [group.b]
        title = "B"
        members = ["c"]

        [group.c]
        title = "C"
        members = ["a"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("group membership cycle detected") == true)
        }
    }

    func testNestedGroupsAreSupportedAndNotFlaggedAsCycles() throws {
        let toml = members("""
        [group.assistants]
        title = "Assistants"
        members = ["claude", "codex"]

        [group.everything]
        title = "Everything"
        members = ["assistants"]
        """)

        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.items.map(\.name), ["claude", "codex", "assistants", "everything"])
    }

    func testNameCannotBeDeclaredAsBothItemAndGroup() {
        let toml = """
        [item.ai]
        type = "command"
        run = "echo hi"

        [group.ai]
        title = "AI"
        members = ["ai"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(toml)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("name is already declared as") == true)
        }
    }

    // MARK: - PinchosConfig visibility policy

    func testHiddenMemberNamesIncludesEveryGroupsMembers() throws {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude", "codex"]
        """)

        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.hiddenMemberNames, ["claude", "codex"])
    }

    func testTopLevelItemsExcludesHiddenMembersButKeepsTheGroupItself() throws {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude", "codex"]
        """)

        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.topLevelItems.map(\.name), ["ai"])
    }

    func testNestedGroupIsHiddenFromTopLevelWhenItIsItselfAMember() throws {
        let toml = members("""
        [group.assistants]
        title = "Assistants"
        members = ["claude", "codex"]

        [group.everything]
        title = "Everything"
        members = ["assistants"]
        """)

        let config = try ConfigParser.parse(toml)
        XCTAssertEqual(config.hiddenMemberNames, ["claude", "codex", "assistants"])
        XCTAssertEqual(config.topLevelItems.map(\.name), ["everything"])
    }

    func testItemWithNoGroupsRemainsFullyTopLevel() throws {
        let toml = """
        [item.clock]
        type = "command"
        run = "date"
        """
        let config = try ConfigParser.parse(toml)
        XCTAssertTrue(config.hiddenMemberNames.isEmpty)
        XCTAssertEqual(config.topLevelItems.map(\.name), ["clock"])
    }

    // MARK: - ItemConfig accessors

    func testItemConfigAccessorsDistinguishCommandAndGroupCases() throws {
        let toml = members("""
        [group.ai]
        title = "AI"
        members = ["claude"]
        """)
        let config = try ConfigParser.parse(toml)
        let command = try XCTUnwrap(config.items.first(where: { $0.name == "claude" }))
        let group = try XCTUnwrap(config.items.first(where: { $0.name == "ai" }))

        XCTAssertEqual(command.kind, .command)
        XCTAssertNotNil(command.commandConfig)
        XCTAssertNil(command.groupConfig)

        XCTAssertEqual(group.kind, .group)
        XCTAssertNil(group.commandConfig)
        XCTAssertNotNil(group.groupConfig)
    }
}
