public struct RecoveryState: Equatable, Sendable {
    public private(set) var isVisible: Bool
    public private(set) var configExists: Bool
    public private(set) var errorDescription: String?

    public init() {
        self.isVisible = false
        self.configExists = true
        self.errorDescription = nil
    }

    public var menu: RecoveryMenu {
        RecoveryMenu(configExists: configExists)
    }

    public mutating func apply(config: PinchosConfig) {
        if config.items.isEmpty {
            show(configExists: true, errorDescription: nil)
        } else {
            dismiss()
        }
    }

    public mutating func show(configExists: Bool, errorDescription: String?) {
        isVisible = true
        self.configExists = configExists
        self.errorDescription = errorDescription
    }

    public mutating func dismiss() {
        isVisible = false
        configExists = true
        errorDescription = nil
    }
}
