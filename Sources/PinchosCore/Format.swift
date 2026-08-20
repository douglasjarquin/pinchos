import Foundation

public func applyFormat(_ template: String?, output: String) -> String {
    guard let template else { return output }
    return template.replacingOccurrences(of: "{output}", with: output)
}

/// Truncates `text` to at most `maxLength` grapheme clusters, appending a single ellipsis
/// character when truncation occurs. Counting grapheme clusters (rather than Unicode scalars
/// or UTF-16 code units) keeps multi-scalar emoji and combining marks intact instead of
/// splitting them mid-cluster. A `nil` or non-positive `maxLength` applies no cap.
public func truncateTitle(_ text: String, maxLength: Int?) -> String {
    guard let maxLength, maxLength > 0, text.count > maxLength else { return text }
    guard maxLength > 1 else { return "\u{2026}" }
    return String(text.prefix(maxLength - 1)) + "\u{2026}"
}

public enum TooltipTemplateError: Error, Equatable, CustomStringConvertible {
    case unclosedPlaceholder
    case unmatchedClosingBrace
    case unsupportedPlaceholder(String)

    public var description: String {
        switch self {
        case .unclosedPlaceholder:
            return "unclosed placeholder"
        case .unmatchedClosingBrace:
            return "unmatched closing brace"
        case .unsupportedPlaceholder(let name):
            return "unsupported placeholder '{\(name)}'"
        }
    }
}

private enum TooltipSegment {
    case literal(String)
    case placeholder(String)
}

private let supportedTooltipPlaceholders: Set<String> = [
    "output",
    "updated_at",
    "attempted_at",
    "duration",
    "exit_status",
    "error",
    "stale",
    "status"
]

public func validateTooltipTemplate(_ template: String) throws {
    _ = try parseTooltipTemplate(template)
}

public func renderTooltip(_ template: String?, state: ItemRuntimeSnapshot) -> String {
    let selectedTemplate = template ?? defaultTooltip(for: state)
    guard let segments = try? parseTooltipTemplate(selectedTemplate) else {
        return defaultTooltip(for: state)
    }
    return segments.map { segment in
        switch segment {
        case .literal(let value):
            return value
        case .placeholder(let name):
            return tooltipValue(name, state: state)
        }
    }.joined()
}

public func formatTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func parseTooltipTemplate(_ template: String) throws -> [TooltipSegment] {
    var segments: [TooltipSegment] = []
    var literal = ""
    var index = template.startIndex

    func flushLiteral() {
        guard !literal.isEmpty else { return }
        segments.append(.literal(literal))
        literal.removeAll(keepingCapacity: true)
    }

    while index < template.endIndex {
        let character = template[index]
        if character == "{" {
            let next = template.index(after: index)
            if next < template.endIndex, template[next] == "{" {
                literal.append("{")
                index = template.index(after: next)
                continue
            }

            guard let closing = template[index...].firstIndex(of: "}") else {
                throw TooltipTemplateError.unclosedPlaceholder
            }
            let nameStart = template.index(after: index)
            let name = String(template[nameStart..<closing])
            guard supportedTooltipPlaceholders.contains(name) else {
                throw TooltipTemplateError.unsupportedPlaceholder(name)
            }
            flushLiteral()
            segments.append(.placeholder(name))
            index = template.index(after: closing)
        } else if character == "}" {
            let next = template.index(after: index)
            if next < template.endIndex, template[next] == "}" {
                literal.append("}")
                index = template.index(after: next)
            } else {
                throw TooltipTemplateError.unmatchedClosingBrace
            }
        } else {
            literal.append(character)
            index = template.index(after: index)
        }
    }

    flushLiteral()
    return segments
}

private func tooltipValue(_ name: String, state: ItemRuntimeSnapshot) -> String {
    switch name {
    case "output":
        return state.fullOutput ?? ""
    case "updated_at":
        return state.lastUpdatedAt.map(formatTimestamp) ?? ""
    case "attempted_at":
        return state.lastAttemptedAt.map(formatTimestamp) ?? ""
    case "duration":
        guard let duration = state.lastRunDuration else { return "" }
        return String(format: "%.3fs", duration)
    case "exit_status":
        return state.exitStatus ?? ""
    case "error":
        return state.errorSummary ?? ""
    case "stale":
        return state.isStale ? "yes" : "no"
    case "status":
        return state.status.rawValue
    default:
        return ""
    }
}

private func defaultTooltip(for state: ItemRuntimeSnapshot) -> String {
    var lines = [
        "Value: \(state.fullOutput ?? "Unavailable")",
        "Status: \(state.status.rawValue)"
    ]
    if let lastUpdatedAt = state.lastUpdatedAt {
        lines.append("Updated: \(formatTimestamp(lastUpdatedAt))")
    }
    if let lastAttemptedAt = state.lastAttemptedAt {
        lines.append("Attempted: \(formatTimestamp(lastAttemptedAt))")
    }
    if let duration = state.lastRunDuration {
        lines.append(String(format: "Duration: %.3fs", duration))
    }
    if let exitStatus = state.exitStatus {
        lines.append("Exit: \(exitStatus)")
    }
    if let errorSummary = state.errorSummary {
        lines.append("Error: \(errorSummary)")
    }
    if state.isStale {
        lines.append("Stale: yes")
    }
    return lines.joined(separator: "\n")
}
