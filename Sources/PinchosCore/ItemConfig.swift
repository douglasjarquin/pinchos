import Foundation

public enum RefreshInterval: Equatable, Sendable {
    case scheduled(TimeInterval)
    case manual
}

/// One effective status-item icon source. `icon` and `symbol` are mutually
/// exclusive in the configuration language, so the runtime never has to rank
/// them.
public enum ItemIconSource: Equatable, Sendable {
    case file(String)
    case symbol(String)

    public var filePath: String? {
        guard case .file(let path) = self else { return nil }
        return path
    }

    public var symbolName: String? {
        guard case .symbol(let name) = self else { return nil }
        return name
    }
}

/// The complete public item model for Pinchos 0.1.
///
/// Shell, working-directory, environment, output-memory, failure-presentation,
/// and scheduler policy are deliberately fixed internal policy rather than
/// configuration surface.
public struct ItemConfig: Equatable, Sendable {
    public static let defaultInterval: TimeInterval = 60
    public static let defaultTimeout: TimeInterval = 15
    public static let defaultMaxOutputBytes = 64 * 1024
    public static let defaultShell = ["/bin/sh", "-c"]

    public static var defaultWorkingDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Preserve the process environment so ordinary CLI credentials and macOS
    /// session values remain available, but replace PATH with one predictable,
    /// GUI-safe search path. LaunchServices does not provide an interactive
    /// shell PATH, so Pinchos supplies the conventional mise, local, Homebrew,
    /// and system locations itself.
    public static var defaultEnvironment: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "\(home)/.local/share/mise/shims",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        environment["HOME"] = home
        return environment
    }

    public let name: String
    public let run: String
    public let interval: RefreshInterval
    public let timeout: TimeInterval
    public let format: String?
    public let iconSource: ItemIconSource?

    public init(
        name: String,
        run: String,
        interval: RefreshInterval = .scheduled(ItemConfig.defaultInterval),
        timeout: TimeInterval = ItemConfig.defaultTimeout,
        format: String? = nil,
        icon: String? = nil,
        symbol: String? = nil
    ) {
        precondition(icon == nil || symbol == nil, "icon and symbol are mutually exclusive")
        self.name = name
        self.run = run
        self.interval = interval
        self.timeout = timeout
        self.format = format
        if let symbol {
            self.iconSource = .symbol(symbol)
        } else if let icon {
            self.iconSource = .file(icon)
        } else {
            self.iconSource = nil
        }
    }

    public var icon: String? { iconSource?.filePath }
    public var symbol: String? { iconSource?.symbolName }
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

/// The single canonical example used by first-run recovery, `pinchos init`,
/// the checked-in example file, and documentation tests.
public enum ExampleConfig {
    public static let text = """
    [item.clock]
    run = "date '+%H:%M'"
    interval = "30s"
    symbol = "clock"

    [item.battery]
    run = "pmset -g batt | awk -F';' 'NR==2 { gsub(/^[ \\t]+/, \"\", $1); print $1 }'"
    format = "{output}"
    """ + "\n"
}
