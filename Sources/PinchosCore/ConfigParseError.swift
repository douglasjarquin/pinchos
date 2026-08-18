public struct ConfigParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let line: Int?

    public init(message: String, line: Int? = nil) {
        self.message = Self.escapeControlCharacters(in: message)
        self.line = line
    }

    public var description: String {
        if let line {
            return "line \(line): \(message)"
        }
        return message
    }

    private static func escapeControlCharacters(in message: String) -> String {
        message.unicodeScalars.map { scalar in
            if scalar.value < 0x20 || scalar.value == 0x7F {
                return "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
            return String(scalar)
        }.joined()
    }
}
