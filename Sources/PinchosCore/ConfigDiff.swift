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
    public static func diff(old: PinchosConfig, new: PinchosConfig) -> ConfigDiff {
        let oldByName = Dictionary(uniqueKeysWithValues: old.items.map { ($0.name, $0) })
        let newByName = Dictionary(uniqueKeysWithValues: new.items.map { ($0.name, $0) })

        let added = new.items.filter { oldByName[$0.name] == nil }
        let removed = old.items.map(\.name).filter { newByName[$0] == nil }
        let changed = new.items.filter { item in
            guard let previous = oldByName[item.name] else { return false }
            return previous != item
        }
        let unchanged = new.items.compactMap { item in
            oldByName[item.name] == item ? item.name : nil
        }

        let addedNames = Set(added.map(\.name))
        let removedNames = Set(removed)
        let oldSharedOrder = old.items.map(\.name)
            .filter { newByName[$0] != nil && !removedNames.contains($0) }
        let newSharedOrder = new.items.map(\.name)
            .filter { oldByName[$0] != nil && !addedNames.contains($0) }
        let orderChanged = oldSharedOrder != newSharedOrder

        // AppKit inserts newly created status items at the visual left edge.
        // Incremental apply can therefore only produce "new prefix + retained
        // old relative order". Anything else requires a full native rebuild.
        let newOrder = new.items.map(\.name)
        let incrementalOrder = newOrder.filter { addedNames.contains($0) } + oldSharedOrder

        return ConfigDiff(
            added: added,
            removed: removed,
            changed: changed,
            unchanged: unchanged,
            orderChanged: orderChanged,
            requiresNativeRebuild: incrementalOrder != newOrder,
            newOrder: newOrder
        )
    }
}
