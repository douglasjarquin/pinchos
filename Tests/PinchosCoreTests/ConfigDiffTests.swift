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

    func testChangingInfoRowsMarksItemChanged() {
        let old = PinchosConfig(items: [item("a")])
        let withInfo = ItemConfig(
            name: "a",
            run: "echo x",
            interval: .scheduled(60),
            info: [ItemInfoRow(title: "Reset", run: "echo 1")]
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
                staleAfter: 900
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

    func testDetectsChangedGroupIconSource() {
        let old = PinchosConfig(items: [
            item("claude"),
            .group(GroupItemConfig(name: "ai", title: "AI", members: ["claude"], icon: "/tmp/a.svg"))
        ])
        let new = PinchosConfig(items: [
            item("claude"),
            .group(GroupItemConfig(name: "ai", title: "AI", members: ["claude"], symbol: "brain"))
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["ai"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertFalse(diff.requiresNativeRebuild)
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
                hidden: true,
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

    // MARK: - Groups (issue #18)

    private func group(_ name: String, title: String = "Group", members: [String]) -> ItemConfig {
        .group(GroupItemConfig(name: name, title: title, members: members))
    }

    func testAddingAGroupIsAnAddedTopLevelItem() {
        let old = PinchosConfig(items: [item("claude")])
        let new = PinchosConfig(items: [item("claude"), group("ai", members: ["claude"])])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        // "claude" becomes a hidden member in `new`, so it is recreated
        // (removed then added) alongside the brand-new "ai" group -- see
        // `testMemberVisibilityChangeForcesRecreationNotInPlaceUpdate`.
        XCTAssertEqual(Set(diff.added.map(\.name)), ["ai", "claude"])
        XCTAssertEqual(diff.removed, ["claude"])
    }

    func testMemberVisibilityChangeForcesRecreationNotInPlaceUpdate() {
        let old = PinchosConfig(items: [item("claude"), item("codex")])
        let new = PinchosConfig(items: [item("claude"), item("codex"), group("ai", members: ["claude", "codex"])])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.removed.sorted(), ["claude", "codex"])
        XCTAssertEqual(Set(diff.added.map(\.name)), ["ai", "claude", "codex"])
        XCTAssertTrue(diff.changed.isEmpty)
    }

    func testMemberRemovedFromGroupBecomesTopLevelAgainViaRecreation() {
        let old = PinchosConfig(items: [item("claude"), item("codex"), group("ai", members: ["claude", "codex"])])
        let new = PinchosConfig(items: [item("claude"), item("codex"), group("ai", members: ["codex"])])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        // "ai"'s own config changed (its `members` array shrank) but it
        // stays a top-level group either way, so it updates in place.
        XCTAssertEqual(diff.changed.map(\.name), ["ai"])
        // "claude" flips from hidden to top-level, which an in-place
        // update cannot express -- it must be recreated.
        XCTAssertEqual(diff.removed, ["claude"])
        XCTAssertEqual(diff.added.map(\.name), ["claude"])
        XCTAssertEqual(diff.unchanged, ["codex"])
    }

    func testGroupTitleChangeWithStableMembershipIsAnIncrementalUpdate() {
        let old = PinchosConfig(items: [item("claude"), group("ai", title: "AI", members: ["claude"])])
        let new = PinchosConfig(items: [item("claude"), group("ai", title: "AI Assistants", members: ["claude"])])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.changed.map(\.name), ["ai"])
        XCTAssertTrue(diff.added.isEmpty)
        XCTAssertTrue(diff.removed.isEmpty)
        XCTAssertFalse(diff.requiresNativeRebuild)
    }

    func testKindChangeFromCommandToGroupForcesRecreation() {
        let old = PinchosConfig(items: [item("ai"), item("claude")])
        let new = PinchosConfig(items: [group("ai", members: ["claude"]), item("claude")])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.removed.sorted(), ["ai", "claude"])
        XCTAssertEqual(Set(diff.added.map(\.name)), ["ai", "claude"])
    }

    func testOnlyTopLevelNamesParticipateInOrderAndRebuildDecisions() {
        // Reordering the hidden members among themselves must not force a
        // native rebuild: neither has (or will have) a real `NSStatusItem`,
        // so there is nothing for AppKit to reorder.
        let old = PinchosConfig(items: [item("claude"), item("codex"), group("ai", members: ["claude", "codex"])])
        let new = PinchosConfig(items: [item("codex"), item("claude"), group("ai", members: ["codex", "claude"])])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertFalse(diff.orderChanged)
        XCTAssertFalse(diff.requiresNativeRebuild)
        XCTAssertEqual(diff.changed.map(\.name), ["ai"])
    }

    func testNestedGroupBecomingAMemberIsRecreatedLikeAnyOtherVisibilityChange() {
        let old = PinchosConfig(items: [
            item("claude"),
            group("assistants", members: ["claude"])
        ])
        let new = PinchosConfig(items: [
            item("claude"),
            group("assistants", members: ["claude"]),
            group("everything", members: ["assistants"])
        ])

        let diff = ConfigDiffEngine.diff(old: old, new: new)

        XCTAssertEqual(diff.removed, ["assistants"])
        XCTAssertEqual(Set(diff.added.map(\.name)), ["assistants", "everything"])
    }
}
