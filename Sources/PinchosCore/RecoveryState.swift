/// Which configuration-recovery situation the menu bar is showing, if any.
///
/// Every transition is legal: each visible case can replace another directly,
/// and a config with items (or a dismiss) returns to `hidden` from any of them.
public enum RecoveryState: Equatable, Sendable {
    case hidden
    /// The config file exists but declares no items.
    case emptyConfig
    /// The config file does not exist.
    case missingConfig
    /// A parse error or a failed recovery action. `configExists` keeps the
    /// missing-config menu when the action failed while the file was absent.
    case error(message: String, configExists: Bool)

    public var isVisible: Bool {
        self != .hidden
    }

    public var menu: RecoveryMenu {
        switch self {
        case .missingConfig, .error(_, configExists: false):
            return RecoveryMenu(configExists: false)
        case .hidden, .emptyConfig, .error(_, configExists: true):
            return RecoveryMenu(configExists: true)
        }
    }

    public mutating func apply(config: PinchosConfig) {
        self = config.items.isEmpty ? .emptyConfig : .hidden
    }
}
