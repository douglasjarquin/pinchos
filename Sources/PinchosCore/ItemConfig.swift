import Foundation

public enum ItemErrorPolicy: String, Equatable, Sendable {
    case replace = "replace"
    case keepLast = "keep_last"
}

public enum ItemNotificationEvent: String, Equatable, Hashable, Sendable {
    case failure
    case recovery
}

public enum RefreshInterval: Equatable, Sendable {
    case scheduled(TimeInterval)
    case manual
}

public enum CommandOutputFormat: String, Equatable, Sendable {
    case plain
    case jsonV1 = "json-v1"
}

public enum ItemTrigger: String, Equatable, Hashable, Sendable {
    case startup
    case wake
    case networkChange = "network-change"
}

public enum ItemActionKind: Equatable, Sendable {
    case command(String)
    case refresh
}

public struct ItemAction: Equatable, Sendable {
    public let title: String
    public let kind: ItemActionKind

    public init(title: String, kind: ItemActionKind) {
        self.title = title
        self.kind = kind
    }
}

/// A read-only status line shown in an item's menu (e.g. "Reset: Sep 7" or
/// "Pace: ahead"). Unlike an `ItemAction`, it is never clickable: its command
/// is run with the item's shell/environment when the menu opens and its stdout
/// is rendered as a disabled row beside `title`. A failing or empty command
/// renders the title with a `–` value rather than hiding the row.
public struct ItemInfoRow: Equatable, Sendable {
    public let title: String
    public let run: String

    public init(title: String, run: String) {
        self.title = title
        self.run = run
    }
}

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

/// A single `[item.<name>]` command module: everything needed to run a
/// shell command on a schedule (or manually) and project its result onto a
/// menu-bar title and diagnostics menu. This is the only item kind in v1.
public struct CommandItemConfig: Equatable, Sendable {
    public static let defaultShell = ["/bin/sh", "-c"]
    public static let defaultTimeout: TimeInterval = 15
    public static let defaultMaxOutputBytes = 64 * 1024

    public let name: String
    public let run: String
    public let shell: [String]
    public let workingDirectory: String?
    public let environment: [String: String]
    public let interval: RefreshInterval
    public let output: CommandOutputFormat
    public let triggers: Set<ItemTrigger>
    public let watch: [String]
    public let timeout: TimeInterval
    public let maxOutputBytes: Int
    public let format: String?
    public let errorText: String
    public let onError: ItemErrorPolicy
    public let staleAfter: TimeInterval?
    public let actions: [ItemAction]
    public let infoRows: [ItemInfoRow]
    public let menu: [MenuRowConfig]
    public let iconSource: ItemIconSource?
    public let maxLength: Int?
    public let hideWhenEmpty: Bool
    public let hideOnError: Bool
    public let hidden: Bool
    public let iconOnly: Bool
    public let disabled: Bool
    public let notifyOn: Set<ItemNotificationEvent>
    public let notifyCooldown: TimeInterval?

    public init(
        name: String,
        run: String,
        interval: RefreshInterval,
        output: CommandOutputFormat = .plain,
        timeout: TimeInterval = CommandItemConfig.defaultTimeout,
        maxOutputBytes: Int = CommandItemConfig.defaultMaxOutputBytes,
        shell: [String] = CommandItemConfig.defaultShell,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        format: String? = nil,
        triggers: Set<ItemTrigger> = [],
        watch: [String] = [],
        errorText: String = "\u{2013}",
        onError: ItemErrorPolicy = .replace,
        staleAfter: TimeInterval? = nil,
        actions: [ItemAction] = [],
        infoRows: [ItemInfoRow] = [],
        menu: [MenuRowConfig] = [],
        icon: String? = nil,
        symbol: String? = nil,
        maxLength: Int? = nil,
        hideWhenEmpty: Bool = false,
        hideOnError: Bool = false,
        hidden: Bool = false,
        iconOnly: Bool = false,
        disabled: Bool = false,
        notifyOn: Set<ItemNotificationEvent> = [],
        notifyCooldown: TimeInterval? = nil
    ) {
        self.name = name
        self.run = run
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.interval = interval
        self.output = output
        self.triggers = triggers
        self.watch = watch
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.format = format
        self.errorText = errorText
        self.onError = onError
        self.staleAfter = staleAfter
        self.menu = menu
        self.actions = actions.isEmpty ? Self.legacyActions(from: menu) : actions
        self.infoRows = infoRows.isEmpty ? Self.legacyInfoRows(from: menu) : infoRows
        self.iconSource = ItemIconSource.make(icon: icon, symbol: symbol)
        self.maxLength = maxLength
        self.hideWhenEmpty = hideWhenEmpty
        self.hideOnError = hideOnError
        self.hidden = hidden
        self.iconOnly = iconOnly
        self.disabled = disabled
        self.notifyOn = notifyOn
        self.notifyCooldown = notifyCooldown
    }

    /// Local-file path when `iconSource` is `.file`; `nil` for a symbol or
    /// a text-only item. Kept as a named field so existing call sites and
    /// docs that talk about `icon` keep working.
    public var icon: String? { iconSource?.filePath }

    /// SF Symbol name when `iconSource` is `.symbol`; `nil` otherwise.
    public var symbol: String? { iconSource?.symbolName }

    private static func legacyActions(from menu: [MenuRowConfig]) -> [ItemAction] {
        menu.compactMap { row in
            guard let action = row.action else { return nil }
            return ItemAction(title: row.label ?? "", kind: .command(action))
        }
    }

    private static func legacyInfoRows(from menu: [MenuRowConfig]) -> [ItemInfoRow] {
        menu.compactMap { row in
            guard let label = row.label, let run = row.run else { return nil }
            return ItemInfoRow(title: label, run: run)
        }
    }
}

/// A configured Pincho item.
public enum ItemConfig: Equatable, Sendable {
    case command(CommandItemConfig)

    public var name: String { command.name }
    public var commandConfig: CommandItemConfig { command }

    public var command: CommandItemConfig {
        switch self {
        case .command(let config): return config
        }
    }

    public var iconSource: ItemIconSource? { command.iconSource }
    public var hidden: Bool { command.hidden }
}

extension ItemConfig {
    /// Convenience initializer mirroring `CommandItemConfig.init` so every
    /// existing "one flat command item" call site keeps working unchanged
    /// against the now-typed `ItemConfig` sum type.
    public init(
        name: String,
        run: String,
        interval: RefreshInterval,
        output: CommandOutputFormat = .plain,
        timeout: TimeInterval = CommandItemConfig.defaultTimeout,
        maxOutputBytes: Int = CommandItemConfig.defaultMaxOutputBytes,
        shell: [String] = CommandItemConfig.defaultShell,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        format: String? = nil,
        triggers: Set<ItemTrigger> = [],
        watch: [String] = [],
        errorText: String = "\u{2013}",
        onError: ItemErrorPolicy = .replace,
        staleAfter: TimeInterval? = nil,
        actions: [ItemAction] = [],
        info: [ItemInfoRow] = [],
        menu: [MenuRowConfig] = [],
        icon: String? = nil,
        symbol: String? = nil,
        maxLength: Int? = nil,
        hideWhenEmpty: Bool = false,
        hideOnError: Bool = false,
        hidden: Bool = false,
        iconOnly: Bool = false,
        disabled: Bool = false,
        notifyOn: Set<ItemNotificationEvent> = [],
        notifyCooldown: TimeInterval? = nil
    ) {
        self = .command(
            CommandItemConfig(
                name: name,
                run: run,
                interval: interval,
                output: output,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes,
                shell: shell,
                workingDirectory: workingDirectory,
                environment: environment,
                format: format,
                triggers: triggers,
                watch: watch,
                errorText: errorText,
                onError: onError,
                staleAfter: staleAfter,
                actions: actions,
                infoRows: info,
                menu: menu,
                icon: icon,
                symbol: symbol,
                maxLength: maxLength,
                hideWhenEmpty: hideWhenEmpty,
                hideOnError: hideOnError,
                hidden: hidden,
                iconOnly: iconOnly,
                disabled: disabled,
                notifyOn: notifyOn,
                notifyCooldown: notifyCooldown
            )
        )
    }
}

/// Optional, validated override of the application-wide `CommandScheduler`
/// policy. `maxActiveSessions` is `nil` when the user did not configure
/// `[scheduler]` at all, in which case `CommandScheduler.defaultMaxActiveSessions`
/// applies. See README "Command scheduler" for the full policy.
public struct SchedulerConfig: Equatable, Sendable {
    public let maxActiveSessions: Int?

    public init(maxActiveSessions: Int? = nil) {
        self.maxActiveSessions = maxActiveSessions
    }
}

public struct PinchosConfig: Equatable, Sendable {
    public let items: [ItemConfig]
    public let scheduler: SchedulerConfig

    public init(items: [ItemConfig], scheduler: SchedulerConfig = SchedulerConfig()) {
        self.items = items
        self.scheduler = scheduler
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
