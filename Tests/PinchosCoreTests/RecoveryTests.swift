import XCTest
@testable import PinchosCore

final class RecoveryTests: XCTestCase {
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

        XCTAssertEqual(config.items.map(\.name), ["clock"])
    }

    func testRecoveryStateMovesFromMissingAndEmptyToNormal() {
        var state = RecoveryState()

        XCTAssertFalse(state.isVisible)

        state.show(configExists: false, errorDescription: nil)
        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.menu.canCreateExampleConfig)

        state.apply(config: PinchosConfig(items: []))
        XCTAssertTrue(state.isVisible)
        XCTAssertFalse(state.menu.canCreateExampleConfig)

        state.apply(config: PinchosConfig(items: [
            ItemConfig(name: "clock", run: "echo clock", interval: 60)
        ]))
        XCTAssertFalse(state.isVisible)
    }
}
