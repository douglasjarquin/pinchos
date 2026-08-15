import Foundation

public struct ItemConfig: Equatable {
    public static let defaultTimeout: TimeInterval = 15
    public static let defaultMaxOutputBytes = 64 * 1024

    public let name: String
    public let run: String
    public let interval: TimeInterval
    public let timeout: TimeInterval
    public let maxOutputBytes: Int
    public let format: String?
    public let click: String?
    public let errorText: String
    public let icon: String?

    public init(
        name: String,
        run: String,
        interval: TimeInterval,
        timeout: TimeInterval = ItemConfig.defaultTimeout,
        maxOutputBytes: Int = ItemConfig.defaultMaxOutputBytes,
        format: String? = nil,
        click: String? = nil,
        errorText: String = "\u{2013}",
        icon: String? = nil
    ) {
        self.name = name
        self.run = run
        self.interval = interval
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.format = format
        self.click = click
        self.errorText = errorText
        self.icon = icon
    }
}

public struct PinchosConfig: Equatable {
    public let items: [ItemConfig]

    public init(items: [ItemConfig]) {
        self.items = items
    }
}
