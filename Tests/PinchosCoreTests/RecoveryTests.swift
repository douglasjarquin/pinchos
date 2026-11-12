import XCTest
@testable import PinchosCore

final class RecoveryTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMissingConfigOffersCreateAndAllRecoveryActions() {
        let menu = RecoveryMenu(configExists: false)

        XCTAssertTrue(menu.canCreateExampleConfig)
        XCTAssertEqual(
            menu.actions.map(\.rawValue),
            ["Create Example Config", "Open Config", "Open Config Directory", "Reload", "Quit"]
        )
    }

    func testExistingEmptyConfigKeepsRecoveryWithoutCreateAction() throws {
        let config = try ConfigParser.parse("")
        let menu = RecoveryMenu(configExists: true)

        XCTAssertTrue(config.items.isEmpty)
        XCTAssertFalse(menu.canCreateExampleConfig)
        XCTAssertEqual(
            menu.actions.map(\.rawValue),
            ["Open Config", "Open Config Directory", "Reload", "Quit"]
        )
    }

    func testExampleConfigIsValidAndProvidesNormalItems() throws {
        let config = try ConfigParser.parse(ExampleConfig.text)

        XCTAssertEqual(config.items.map(\.name), ["codex"])
    }

    func testGeneratedExampleMatchesCheckedInRemainderConfiguration() throws {
        let checkedInExample = try String(
            contentsOf: repoRoot.appendingPathComponent("example/pinchos.toml"),
            encoding: .utf8
        )

        XCTAssertEqual(ExampleConfig.text + "\n", checkedInExample)

        let item = try XCTUnwrap(ConfigParser.parse(ExampleConfig.text).items.first)
        let remaining = "remainder value --provider codex --profile default --window weekly --scope account --field remaining --cache auto --max-age 5s --freshness fresh"
        let pace = "remainder value --provider codex --profile default --window weekly --scope account --field pace --cache auto --max-age 5s --freshness fresh"

        XCTAssertEqual(item.run, remaining)
        XCTAssertEqual(item.interval, .scheduled(300))
        XCTAssertEqual(item.timeout, 15)
        XCTAssertEqual(item.symbol, "terminal")
        XCTAssertEqual(item.menu.map(\.label), ["Usage", "Pace", "Refresh", "Open Codex", nil])
        XCTAssertEqual(item.menu.map(\.run), [remaining, pace, remaining, nil, nil])
        XCTAssertEqual(item.menu.map(\.action), [nil, nil, "open https://chatgpt.com/codex", "open https://chatgpt.com/codex", nil])
        XCTAssertEqual(item.menu.map(\.cache), [300, 300, 300, nil, nil])
        XCTAssertFalse(ExampleConfig.text.contains("quota-axi"))
        XCTAssertFalse(ExampleConfig.text.contains("jq"))
    }

    func testRecoveryStateMovesFromMissingAndEmptyToNormal() {
        var state = RecoveryState.missingConfig
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.menu.canCreateExampleConfig)

        state.apply(config: PinchosConfig(items: []))
        XCTAssertEqual(state, .emptyConfig)
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.menu.canCreateExampleConfig)

        state.apply(config: PinchosConfig(items: [
            ItemConfig(name: "clock", run: "echo clock", interval: .scheduled(60))
        ]))
        XCTAssertEqual(state, .hidden)
        XCTAssertFalse(state.isVisible)
    }

    func testEveryVisibleCaseReturnsToHiddenForConfigWithItems() {
        let withItems = PinchosConfig(items: [ItemConfig(name: "clock", run: "echo clock", interval: .manual)])
        let visible: [RecoveryState] = [
            .emptyConfig,
            .missingConfig,
            .error(message: "broken", configExists: true),
            .error(message: "broken", configExists: false),
        ]
        for start in visible {
            var state = start
            XCTAssertTrue(state.isVisible, "\(start)")
            state.apply(config: withItems)
            XCTAssertEqual(state, .hidden, "\(start)")
        }
    }

    func testErrorMenuFollowsWhetherConfigExists() {
        XCTAssertEqual(
            RecoveryState.error(message: "broken", configExists: false).menu,
            RecoveryState.missingConfig.menu
        )
        XCTAssertEqual(
            RecoveryState.error(message: "broken", configExists: true).menu,
            RecoveryState.emptyConfig.menu
        )
        XCTAssertFalse(RecoveryState.hidden.isVisible)
    }
}
