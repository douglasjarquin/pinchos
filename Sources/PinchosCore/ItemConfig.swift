import Foundation

public struct ItemConfig: Equatable {
    public let name: String
    public let run: String
    public let interval: TimeInterval
    public let format: String?
    public let click: String?
    public let errorText: String
    public let icon: String?

    public init(
        name: String,
        run: String,
        interval: TimeInterval,
        format: String? = nil,
        click: String? = nil,
        errorText: String = "\u{2013}",
        icon: String? = nil
    ) {
        self.name = name
        self.run = run
        self.interval = interval
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
