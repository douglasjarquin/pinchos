import Foundation

public enum FormatTemplateError: Error, Equatable, CustomStringConvertible {
    case unknownPlaceholder(String)

    public var description: String {
        switch self {
        case .unknownPlaceholder(let placeholder):
            return "unknown placeholder '{\(placeholder)}'"
        }
    }
}

public func validateFormatTemplate(_ template: String) throws {
    var cursor = template.startIndex
    while cursor < template.endIndex {
        switch template[cursor] {
        case "{":
            guard let close = template[cursor...].firstIndex(of: "}") else {
                throw FormatTemplateError.unknownPlaceholder(String(template[template.index(after: cursor)...]))
            }
            let placeholder = String(template[template.index(after: cursor)..<close])
            guard placeholder == "output" else {
                throw FormatTemplateError.unknownPlaceholder(placeholder)
            }
            cursor = template.index(after: close)
        case "}":
            throw FormatTemplateError.unknownPlaceholder("}")
        default:
            cursor = template.index(after: cursor)
        }
    }
}

public func applyFormat(_ template: String?, output: String) -> String {
    guard let template else { return output }
    return template.replacingOccurrences(of: "{output}", with: output)
}

public func formatTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
