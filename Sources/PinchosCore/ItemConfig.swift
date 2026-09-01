import Foundation

public enum RefreshInterval: Equatable, Sendable {
    case scheduled(TimeInterval)
    case manual
}

/// One ordered row in an item's native submenu.
public struct MenuRowConfig: Equatable, Sendable {
    public let label: String?
    public let value: String?
    public let run: String?
    public let action: String?
    public let cache: TimeInterval?
    public let separator: Bool

    public init(
        label: String? = nil,
        value: String? = nil,
        run: String? = nil,
        action: String? = nil,
        cache: TimeInterval? = nil,
        separator: Bool = false
    ) {
        self.label = label
        self.value = value
        self.run = run
        self.action = action
        self.cache = cache
        self.separator = separator
    }

    public static let separator = MenuRowConfig(separator: true)
}

/// One effective status-item icon source. `symbol` and `icon` are mutually
/// exclusive at parse time (a config that sets both is rejected); the runtime
/// model therefore never has to rank them.
public enum ItemIconSource: Equatable, Sendable {
    case file(String)
    case symbol(String)

    public var filePath: String? {
        if case .file(let path) = self { return path }
        return nil
    }

    public var symbolName: String? {
        if case .symbol(let name) = self { return name }
        return nil
    }

    static func make(icon: String?, symbol: String?) -> ItemIconSource? {
        if let symbol {
            return .symbol(symbol)
        }
        if let icon {
            return .file(icon)
        }
        return nil
    }
}

/// A single `[item.<name>]` command module: the canonical 0.1 configuration
/// needed to run a bounded command and project its result onto the menu bar.
public struct CommandItemConfig: Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 15

    public let name: String
    public let run: String
    public let interval: RefreshInterval
    public let format: String?
    public let timeout: TimeInterval
    public let menu: [MenuRowConfig]
    public let iconSource: ItemIconSource?

    public init(
        name: String,
        run: String,
        interval: RefreshInterval,
        timeout: TimeInterval = CommandItemConfig.defaultTimeout,
        format: String? = nil,
        menu: [MenuRowConfig] = [],
        icon: String? = nil,
        symbol: String? = nil
    ) {
        self.name = name
        self.run = run
        self.interval = interval
        self.format = format
        self.timeout = timeout
        self.menu = menu
        self.iconSource = ItemIconSource.make(icon: icon, symbol: symbol)
    }

    /// Local-file path when `iconSource` is `.file`; `nil` for a symbol or
    /// a text-only item. Kept as a named field so existing call sites and
    /// docs that talk about `icon` keep working.
    public var icon: String? { iconSource?.filePath }

    /// SF Symbol name when `iconSource` is `.symbol`; `nil` otherwise.
    public var symbol: String? { iconSource?.symbolName }
}

public typealias ItemConfig = CommandItemConfig

public struct PinchosConfig: Equatable, Sendable {
    public let items: [ItemConfig]

    public init(items: [ItemConfig]) {
        self.items = items
    }

}

public enum RecoveryMenuAction: String, CaseIterable, Equatable, Sendable {
    case createExampleConfig = "Create Example Config"
    case openConfig = "Open Config"
    case openConfigDirectory = "Open Config Directory"
    case reload = "Reload"
    case quit = "Quit"
}

public struct RecoveryMenu: Equatable, Sendable {
    public let canCreateExampleConfig: Bool

    public init(configExists: Bool) {
        self.canCreateExampleConfig = !configExists
    }

    public var actions: [RecoveryMenuAction] {
        var actions: [RecoveryMenuAction] = []
        if canCreateExampleConfig {
            actions.append(.createExampleConfig)
        }
        actions.append(contentsOf: [.openConfig, .openConfigDirectory, .reload, .quit])
        return actions
    }
}

public enum ExampleConfig {
    public static let text = """
    [item.codex]
    run = "quota-axi codex --short"
    interval = "5m"
    timeout = "15s"
    format = "{output}"
    symbol = "terminal"

    [[item.codex.menu]]
    label = "Usage"
    run = "quota-axi codex --usage"
    cache = "5m"

    [[item.codex.menu]]
    label = "Pace"
    run = "quota-axi codex --pace"
    cache = "5m"

    [[item.codex.menu]]
    label = "Reset"
    run = "quota-axi codex --reset"
    cache = "5m"

    [[item.codex.menu]]
    label = "Open Codex"
    action = "open https://chatgpt.com/codex"

    [[item.codex.menu]]
    separator = true
    """
}
