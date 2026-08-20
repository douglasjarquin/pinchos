import Foundation

public enum ItemErrorPolicy: String, Equatable, Sendable {
    case replace = "replace"
    case keepLast = "keep_last"
}

public enum RefreshInterval: Equatable, Sendable {
    case scheduled(TimeInterval)
    case manual
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

public struct ItemConfig: Equatable, Sendable {
    public static let defaultShell = ["/bin/sh", "-c"]
    public static let defaultTimeout: TimeInterval = 15
    public static let defaultMaxOutputBytes = 64 * 1024

    public let name: String
    public let run: String
    public let shell: [String]
    public let workingDirectory: String?
    public let environment: [String: String]
    public let interval: RefreshInterval
    public let timeout: TimeInterval
    public let maxOutputBytes: Int
    public let format: String?
    public let click: String?
    public let refreshOnClick: Bool
    public let errorText: String
    public let onError: ItemErrorPolicy
    public let staleAfter: TimeInterval?
    public let tooltip: String?
    public let actions: [ItemAction]
    public let icon: String?
    public let maxLength: Int?
    public let hideWhenEmpty: Bool
    public let hideOnError: Bool
    public let iconOnly: Bool
    public let disabled: Bool

    public init(
        name: String,
        run: String,
        interval: RefreshInterval,
        timeout: TimeInterval = ItemConfig.defaultTimeout,
        maxOutputBytes: Int = ItemConfig.defaultMaxOutputBytes,
        shell: [String] = ItemConfig.defaultShell,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        format: String? = nil,
        click: String? = nil,
        refreshOnClick: Bool = false,
        errorText: String = "\u{2013}",
        onError: ItemErrorPolicy = .replace,
        staleAfter: TimeInterval? = nil,
        tooltip: String? = nil,
        actions: [ItemAction] = [],
        icon: String? = nil,
        maxLength: Int? = nil,
        hideWhenEmpty: Bool = false,
        hideOnError: Bool = false,
        iconOnly: Bool = false,
        disabled: Bool = false
    ) {
        self.name = name
        self.run = run
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.interval = interval
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.format = format
        self.click = click
        self.refreshOnClick = refreshOnClick
        self.errorText = errorText
        self.onError = onError
        self.staleAfter = staleAfter
        self.tooltip = tooltip
        self.actions = actions
        self.icon = icon
        self.maxLength = maxLength
        self.hideWhenEmpty = hideWhenEmpty
        self.hideOnError = hideOnError
        self.iconOnly = iconOnly
        self.disabled = disabled
    }
}

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
    [item.clock]
    type = "command"
    run = "date '+%H:%M:%S'"
    interval = "60s"
    format = "{output}"
    on_error = "keep_last"
    stale_after = "15m"
    tooltip = "Updated {updated_at} ({status})"
    """
}
