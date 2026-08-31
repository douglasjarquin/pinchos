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

public func formatTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
