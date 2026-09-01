import XCTest
@testable import PinchosCore

final class ConfigDiffTests: XCTestCase {
    private func item(
        _ name: String,
        run: String = "echo x",
        interval: RefreshInterval = .scheduled(60),
        format: String? = nil
    ) -> ItemConfig {
        ItemConfig(
            name: name,
            run: run,
            interval: interval,
            format: format
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

    func testChangingMenuRowsMarksItemChanged() {
        let old = PinchosConfig(items: [item("a")])
        let withInfo = ItemConfig(
            name: "a",
            run: "echo x",
            interval: .scheduled(60),
            menu: [MenuRowConfig(label: "Reset", value: "1")]
        )
        let diff = ConfigDiffEngine.diff(old: old, new: PinchosConfig(items: [withInfo]))
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertEqual(diff.added, [])
        XCTAssertEqual(diff.removed, [])
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
        XCTAssertTrue(diff.requiresNativeRebuild)
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
                menu: [MenuRowConfig(label: "Refresh", action: "echo refresh")]
            )
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
    }

    func testDetectsChangedIconSourceFromFileToSymbol() {
        let old = PinchosConfig(items: [
            ItemConfig(name: "a", run: "echo x", interval: .scheduled(60), icon: "/tmp/a.svg")
        ])
        let new = PinchosConfig(items: [
            ItemConfig(name: "a", run: "echo x", interval: .scheduled(60), symbol: "chart.bar.fill")
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["a"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testDetectsChangedIconSourceToNone() {
        let old = PinchosConfig(items: [
            ItemConfig(name: "a", run: "echo x", interval: .scheduled(60), symbol: "chart.bar.fill")
        ])
        let new = PinchosConfig(items: [item("a")])

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

    func testAddingItemBeforeExistingItemsUsesNativeInsertion() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("new"), item("a"), item("b")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.added.map(\.name), ["new"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
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
