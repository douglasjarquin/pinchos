public struct ConfigDiff: Equatable {
    public let added: [ItemConfig]
    public let removed: [String]
    public let changed: [ItemConfig]
    public let unchanged: [String]
    public let orderChanged: Bool
    public let requiresNativeRebuild: Bool
    public let newOrder: [String]

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && !orderChanged
    }
}

public enum ConfigDiffEngine {
    /// Computes what changed between two configs, in terms a
    /// `StatusItemController` can apply incrementally.
    ///
    /// A name shared by both configs is either `unchanged`, `changed` (same
    /// managed-item instance updates in place), or folded into
    /// `added`+`removed` together when it must become a *new* managed-item
    /// instance instead: this happens when its kind changes (a `command`
    /// becomes a `group` or vice versa, same name) or when its
    /// group-membership visibility changes (a previously hidden group
    /// member becomes top-level, or vice versa) -- both cases need a
    /// native status item created or torn down, which a same-instance
    /// in-place update cannot do (see `ManagedItem`/`ManagedGroupItem`,
    /// whose native `NSStatusItem` is fixed at construction time).
    ///
    /// `orderChanged`/`requiresNativeRebuild`/`newOrder` describe native
    /// status-item placement and therefore only ever consider *top-level*
    /// (non-hidden-member) names: a hidden group member has no native
    /// status item to place, so its position among hidden names is
    /// irrelevant to whether AppKit's append-only insertion can preserve
    /// declared order.
    public static func diff(old: PinchosConfig, new: PinchosConfig) -> ConfigDiff {
        let oldByName = Dictionary(uniqueKeysWithValues: old.items.map { ($0.name, $0) })
        let newByName = Dictionary(uniqueKeysWithValues: new.items.map { ($0.name, $0) })
        let oldHidden = old.hiddenMemberNames
        let newHidden = new.hiddenMemberNames

        var added: [ItemConfig] = []
        var removed: [String] = []
        var changed: [ItemConfig] = []
        var unchanged: [String] = []

        for item in new.items {
            guard let oldItem = oldByName[item.name] else {
                added.append(item)
                continue
            }
            let kindChanged = oldItem.kind != item.kind
            let visibilityChanged = oldHidden.contains(item.name) != newHidden.contains(item.name)
            if kindChanged || visibilityChanged {
                removed.append(item.name)
                added.append(item)
            } else if oldItem == item {
                unchanged.append(item.name)
            } else {
                changed.append(item)
            }
        }
        for name in old.items.map(\.name) where newByName[name] == nil {
            removed.append(name)
        }

        let addedNames = Set(added.map(\.name))
        let recreatedOrRemovedNames = Set(removed)

        let oldVisibleSharedOrder = old.items.map(\.name)
            .filter { !oldHidden.contains($0) }
            .filter { newByName[$0] != nil && !recreatedOrRemovedNames.contains($0) }
        let newVisibleSharedOrder = new.items.map(\.name)
            .filter { !newHidden.contains($0) }
            .filter { oldByName[$0] != nil && !addedNames.contains($0) }
        let orderChanged = oldVisibleSharedOrder != newVisibleSharedOrder

        // Incremental apply can only append a newly-created native status
        // item to the right (AppKit has no "insert before" for
        // `NSStatusItem`) and cannot reorder an existing one, so the
        // incrementally-achievable order keeps every kept item at its *old*
        // relative position and appends every added item after them in its
        // *new* relative position. If that does not equal the actually
        // desired new order, only a full rebuild (tear down and recreate
        // every native item in the new order) can realize it.
        let newVisibleOrder = new.items.map(\.name).filter { !newHidden.contains($0) }
        let addedVisibleOrder = newVisibleOrder.filter { addedNames.contains($0) }
        let incrementalVisibleOrder = oldVisibleSharedOrder + addedVisibleOrder
        let requiresNativeRebuild = incrementalVisibleOrder != newVisibleOrder

        return ConfigDiff(
            added: added,
            removed: removed,
            changed: changed,
            unchanged: unchanged,
            orderChanged: orderChanged,
            requiresNativeRebuild: requiresNativeRebuild,
            newOrder: new.items.map(\.name)
        )
    }
}
