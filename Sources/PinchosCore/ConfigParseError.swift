public struct ConfigParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let line: Int?

    public init(message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }

    public var description: String {
        if let line {
            return "line \(line): \(message)"
        }
        return message
    }
}
