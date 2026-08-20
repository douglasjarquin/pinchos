import XCTest
@testable import PinchosCore

final class ConfigDiffTests: XCTestCase {
    private func item(
        _ name: String,
        run: String = "echo x",
        interval: RefreshInterval = .scheduled(60),
        timeout: TimeInterval = 15,
        maxOutputBytes: Int = 64 * 1024
    ) -> ItemConfig {
        ItemConfig(
            name: name,
            run: run,
            interval: interval,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
    }

    func testNoChangeIsEmptyDiff() {
        let config = PinchosConfig(items: [item("a"), item("b")])
        let diff = ConfigDiffEngine.diff(old: config, new: config)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.removed, [])
        XCTAssertEqual(diff.changed, [])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testDetectsAddedItem() {
        let old = PinchosConfig(items: [item("a")])
        let new = PinchosConfig(items: [item("a"), item("b")])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.added.map(\.name), ["b"])
        XCTAssertEqual(diff.removed, [])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testDetectsRemovedItem() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("a")])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.removed, ["b"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testDetectsChangedItem() {
        let old = PinchosConfig(items: [item("a", run: "echo 1")])
        let new = PinchosConfig(items: [item("a", run: "echo 2")])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.removed, [])
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testDetectsChangedDeclarativeActions() {
        let old = PinchosConfig(items: [item("a")])
        let new = PinchosConfig(items: [
            ItemConfig(
                name: "a",
                run: "echo x",
                interval: .scheduled(60),
                actions: [ItemAction(title: "Refresh", kind: .refresh)]
            )
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testDetectsChangedCommandBounds() {
        let old = PinchosConfig(items: [item("a")])
        let new = PinchosConfig(items: [item("a", timeout: 30, maxOutputBytes: 128 * 1024)])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testDetectsChangedRuntimePresentationSettings() {
        let old = PinchosConfig(items: [item("a")])
        let new = PinchosConfig(items: [
            ItemConfig(
                name: "a",
                run: "echo x",
                interval: .scheduled(60),
                onError: .keepLast,
                staleAfter: 900,
                tooltip: "{status}"
            )
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testDetectsChangedVisibilityAndDisabledPolicy() {
        let old = PinchosConfig(items: [item("a")])
        let new = PinchosConfig(items: [
            ItemConfig(
                name: "a",
                run: "echo x",
                interval: .scheduled(60),
                maxLength: 24,
                hideWhenEmpty: true,
                hideOnError: true,
                iconOnly: true,
                disabled: true
            )
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testDetectsOrderChangeWithSameItems() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("b"), item("a")])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertTrue(diff.orderChanged)
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.removed, [])
        XCTAssertEqual(diff.changed, [])
        XCTAssertEqual(diff.newOrder, ["b", "a"])
        XCTAssertTrue(diff.requiresNativeRebuild)
    }

    func testUnchangedItemsAreListed() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("a"), item("b", run: "echo changed")])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertEqual(diff.unchanged, ["a"])
        XCTAssertEqual(diff.changed.map(\.name), ["b"])
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testAddingItemBeforeExistingItemsRequiresNativeRebuild() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("new"), item("a"), item("b")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.added.map(\.name), ["new"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertTrue(diff.requiresNativeRebuild)
    }

    func testAddedRemovedAndChangedTogether() {
        let old = PinchosConfig(items: [item("a"), item("b"), item("c")])
        let new = PinchosConfig(items: [item("a", run: "echo new"), item("c"), item("d")])
        let diff = ConfigDiffEngine.diff(old: old, new: new)
        XCTAssertEqual(diff.added.map(\.name), ["d"])
        XCTAssertEqual(diff.removed, ["b"])
        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertEqual(diff.unchanged, ["c"])
    }
}
