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
/// menu-bar title and diagnostics menu. This is the only item
/// kind in v1; `GroupItemConfig` (see below) is the second kind added by
/// the grouped-status-items feature, and `ItemConfig` is the sum type that
/// lets `PinchosConfig.items` hold either without accumulating one kind's
/// fields onto the other's model.
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

/// A `[group.<name>]` module: one native status item that stands in for a
/// list of member items (referenced by stable name, see README "Groups").
/// Icon sources reuse `ItemIconSource`: a local `icon` file or a native
/// `symbol` name, never both.
public struct GroupItemConfig: Equatable, Sendable {
    public let name: String
    public let title: String
    public let members: [String]
    public let iconSource: ItemIconSource?
    public let hidden: Bool

    public init(
        name: String,
        title: String,
        members: [String],
        icon: String? = nil,
        symbol: String? = nil,
        hidden: Bool = false
    ) {
        self.name = name
        self.title = title
        self.members = members
        self.iconSource = ItemIconSource.make(icon: icon, symbol: symbol)
        self.hidden = hidden
    }

    public var icon: String? { iconSource?.filePath }
    public var symbol: String? { iconSource?.symbolName }
}

public enum ItemKind: Equatable, Sendable {
    case command
    case group
}

/// The typed, extensible sum of every configured module kind. Adding a
/// third kind in the future means adding a case here, not widening
/// `CommandItemConfig` with fields that only make sense for the new kind.
public enum ItemConfig: Equatable, Sendable {
    case command(CommandItemConfig)
    case group(GroupItemConfig)

    public var name: String {
        switch self {
        case .command(let config): return config.name
        case .group(let config): return config.name
        }
    }

    public var kind: ItemKind {
        switch self {
        case .command: return .command
        case .group: return .group
        }
    }

    /// `nil` when `self` is `.group`; use this (rather than `command`) at
    /// any call site that already handles a group gracefully, e.g. by
    /// skipping it.
    public var commandConfig: CommandItemConfig? {
        guard case .command(let config) = self else { return nil }
        return config
    }

    /// `nil` when `self` is `.command`.
    public var groupConfig: GroupItemConfig? {
        guard case .group(let config) = self else { return nil }
        return config
    }

    /// Non-optional unwrap for call sites that have already established
    /// (by construction or by switching on `kind`) that this is a command
    /// item. Traps on a group, exactly like force-unwrapping an `Optional`
    /// known to be non-nil -- this is not a place that should ever
    /// fabricate a placeholder `CommandItemConfig` for a group.
    public var command: CommandItemConfig {
        guard case .command(let config) = self else {
            preconditionFailure("ItemConfig.command accessed on a group item ('\(name)')")
        }
        return config
    }

    /// Non-optional unwrap symmetric with `command`, for call sites that have
    /// already established this is a group item. Traps on a command item.
    public var group: GroupItemConfig {
        guard case .group(let config) = self else {
            preconditionFailure("ItemConfig.group accessed on a command item ('\(name)')")
        }
        return config
    }

    public var iconSource: ItemIconSource? {
        switch self {
        case .command(let config): return config.iconSource
        case .group(let config): return config.iconSource
        }
    }

    public var hidden: Bool {
        switch self {
        case .command(let config): return config.hidden
        case .group(let config): return config.hidden
        }
    }
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

    /// Every name that appears in some group's `members` list, at any
    /// nesting depth. Policy: a name used as a group member never gets its
    /// own top-level `NSStatusItem` -- it still runs on its own schedule
    /// and appears (with its live value/state and actions) only inside the
    /// menu of the group(s) that reference it. See README "Groups".
    public var hiddenMemberNames: Set<String> {
        Set(items.flatMap { item -> [String] in
            guard case .group(let group) = item else { return [] }
            return group.members
        })
    }

    /// `items` filtered to the entries that get their own native status
    /// item: everything except names hidden by `hiddenMemberNames`.
    /// Declaration order is preserved.
    public var topLevelItems: [ItemConfig] {
        let hidden = hiddenMemberNames
        return items.filter { !hidden.contains($0.name) }
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
