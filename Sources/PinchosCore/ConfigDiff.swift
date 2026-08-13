public struct ConfigDiff: Equatable {
    public let added: [ItemConfig]
    public let removed: [String]
    public let changed: [ItemConfig]
    public let unchanged: [String]
    public let orderChanged: Bool
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

        var changed: [ItemConfig] = []
        var unchanged: [String] = []
        for item in new.items {
            guard let oldItem = oldByName[item.name] else { continue }
            if oldItem == item {
                unchanged.append(item.name)
            } else {
                changed.append(item)
            }
        }

        let oldSharedOrder = old.items.map(\.name).filter { newByName[$0] != nil }
        let newSharedOrder = new.items.map(\.name).filter { oldByName[$0] != nil }
        let orderChanged = oldSharedOrder != newSharedOrder

        return ConfigDiff(
            added: added,
            removed: removed,
            changed: changed,
            unchanged: unchanged,
            orderChanged: orderChanged,
            newOrder: new.items.map(\.name)
        )
    }
}
