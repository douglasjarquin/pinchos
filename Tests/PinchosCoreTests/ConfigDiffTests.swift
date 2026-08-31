import XCTest
@testable import PinchosCore

final class ConfigDiffTests: XCTestCase {
    func testIdenticalConfigsProduceEmptyDiff() {
        let config = PinchosConfig(items: [item("a"), item("b")])

        let diff = ConfigDiffEngine.diff(old: config, new: config)

        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.unchanged, ["a", "b"])
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testChangedItemIsUpdatedInPlace() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let changed = ItemConfig(
            name: "b",
            run: "printf changed",
            interval: .scheduled(30),
            timeout: 5,
            format: "[{output}]",
            symbol: "bolt"
        )
        let new = PinchosConfig(items: [item("a"), changed])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed, [changed])
        XCTAssertEqual(diff.unchanged, ["a"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testAddingItemsAtVisualPrefixDoesNotRequireRebuild() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let x = item("x")
        let y = item("y")
        let new = PinchosConfig(items: [x, y, item("a"), item("b")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.added, [x, y])
        XCTAssertEqual(diff.newOrder, ["x", "y", "a", "b"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testAddingItemAfterRetainedItemRequiresNativeRebuild() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("a"), item("x"), item("b")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.added.map(\.name), ["x"])
        XCTAssertTrue(diff.requiresNativeRebuild)
    }

    func testRemovingItemsPreservesRemainingNativeOrder() {
        let old = PinchosConfig(items: [item("a"), item("b"), item("c")])
        let new = PinchosConfig(items: [item("a"), item("c")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.removed, ["b"])
        XCTAssertEqual(diff.unchanged, ["a", "c"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testReorderingRetainedItemsRequiresNativeRebuild() {
        let old = PinchosConfig(items: [item("a"), item("b"), item("c")])
        let new = PinchosConfig(items: [item("c"), item("a"), item("b")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertTrue(diff.orderChanged)
        XCTAssertTrue(diff.requiresNativeRebuild)
        XCTAssertEqual(diff.newOrder, ["c", "a", "b"])
    }

    func testReplacingAllItemsDoesNotClaimRetainedOrderChanged() {
        let old = PinchosConfig(items: [item("a"), item("b")])
        let new = PinchosConfig(items: [item("x"), item("y")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.added.map(\.name), ["x", "y"])
        XCTAssertEqual(diff.removed, ["a", "b"])
        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testEveryPublicFieldParticipatesInEquality() {
        let original = item("a")
        let variants = [
            ItemConfig(name: "a", run: "printf other"),
            ItemConfig(name: "a", run: original.run, interval: .manual),
            ItemConfig(name: "a", run: original.run, timeout: 30),
            ItemConfig(name: "a", run: original.run, format: "{output}%"),
            ItemConfig(name: "a", run: original.run, icon: "/tmp/icon.png"),
            ItemConfig(name: "a", run: original.run, symbol: "clock"),
        ]

        for variant in variants {
            let diff = ConfigDiffEngine.diff(
                old: PinchosConfig(items: [original]),
                new: PinchosConfig(items: [variant])
            )
            XCTAssertEqual(diff.changed, [variant])
        }
    }

    private func item(_ name: String) -> ItemConfig {
        ItemConfig(name: name, run: "printf \(name)")
    }
}
