import Foundation

/// A bounded, sanitized projection of retained command output (or any other
/// untrusted diagnostic text) suitable for a native `NSMenuItem.title`.
/// `text` is safe to lay out directly; `isTruncated` tells a caller
/// whether the source was larger than what is shown, so it can decide
/// whether a copy-full-output action is worth offering or whether
/// accessibility text should mention truncation.
public struct DiagnosticPreview: Equatable, Sendable {
    public let text: String
    public let isTruncated: Bool

    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// Bounds and sanitizes retained command output before it is projected into
/// an AppKit menu title. Pinchos retains bounded stdout/stderr output per
/// stream (independently of this formatter -- see `OutputMemoryBudget`), but
/// "available to diagnostics" must not mean
/// "laid out as one `NSMenuItem` title": opening the lifecycle menu has to
/// cost a bounded amount of formatting/layout work regardless of how large a
/// command's retained output is. The complete retained text is always still
/// reachable through a **Copy Full Output**/**Copy Full Error** action that
/// reads the exact retained string, never this preview. See issue #53 and
/// README.md's "Diagnostics menu" section for the preview-vs-retained-output
/// contract this formatter implements.
public enum DiagnosticPreviewFormatter {
    /// The pixel-free layout budget for one preview: caps are expressed in
    /// grapheme clusters (what a human perceives as "one character", so
    /// multi-scalar emoji/combining marks are never split), UTF-8 bytes (a
    /// backstop against cluster-dense but byte-heavy text, e.g. long runs of
    /// combining marks or 4-byte scalars), and lines. `collapsesNewlines`
    /// distinguishes a single-line `NSMenuItem.title` context (newlines are
    /// visibly escaped so they can't fake multiple menu rows or hide the
    /// global action section beneath them).
    public struct Limits: Equatable, Sendable {
        public let maxGraphemeClusters: Int
        public let maxUTF8Bytes: Int
        public let maxLines: Int
        public let collapsesNewlines: Bool

        public init(maxGraphemeClusters: Int, maxUTF8Bytes: Int, maxLines: Int, collapsesNewlines: Bool) {
            precondition(maxGraphemeClusters > 0, "maxGraphemeClusters must be positive")
            precondition(maxUTF8Bytes > 0, "maxUTF8Bytes must be positive")
            precondition(maxLines > 0, "maxLines must be positive")
            self.maxGraphemeClusters = maxGraphemeClusters
            self.maxUTF8Bytes = maxUTF8Bytes
            self.maxLines = maxLines
            self.collapsesNewlines = collapsesNewlines
        }

        /// The primary "Value: {output}" menu line. Renders as one visual
        /// row (embedded line breaks are visibly escaped, never real
        /// newlines), short enough that opening the menu never measures/
        /// lays out more than a small, fixed amount of text no matter how
        /// large command output is retained. A handful of source lines are
        /// still allowed through before the line cap itself contributes to
        /// truncation, so short multi-line output (e.g. three lines of
        /// pretty-printed status) is not needlessly reduced to one line;
        /// pathological line counts are still bounded because a value that
        /// exceeds this line cap is marked truncated even though it would
        /// otherwise fit under the byte/cluster caps.
        public static let menuValue = Limits(maxGraphemeClusters: 240, maxUTF8Bytes: 4096, maxLines: 3, collapsesNewlines: true)

        /// The bounded stderr/error line already used across the primary
        /// and action diagnostics sections (previously an ad hoc
        /// `.prefix(200)` at each call site). Callers pass a single
        /// already-selected line (see `lastTrimmedLine`); the one-line cap
        /// here is a defensive backstop, not the primary line-selection
        /// mechanism.
        public static let menuStderr = Limits(maxGraphemeClusters: 200, maxUTF8Bytes: 2048, maxLines: 1, collapsesNewlines: true)

        /// Declarative-action diagnostics (stderr previews, launch-failure
        /// messages) share the stderr budget; they are the same kind of
        /// single bounded diagnostic line.
        public static let actionDiagnostics = menuStderr
    }

    public static let menuValue = Limits.menuValue
    public static let menuStderr = Limits.menuStderr
    public static let actionDiagnostics = Limits.actionDiagnostics

    /// Produces a bounded, sanitized preview of `text` under `limits`.
    ///
    /// Pipeline: normalize line endings, cap line count, sanitize each
    /// remaining line's unsafe scalars (NUL, other C0/C1 controls, bidi
    /// format controls) to visible placeholders, join lines (collapsing them onto
    /// one visible line when `limits.collapsesNewlines`), then cap grapheme
    /// clusters and finally UTF-8 bytes -- both cuts happen at grapheme
    /// cluster boundaries so an extended grapheme cluster (flag emoji,
    /// ZWJ sequence, base character plus combining marks) is never split.
    /// A truncation marker carrying the original byte/line counts is
    /// appended whenever any cap was hit.
    public static func preview(_ text: String, limits: Limits) -> DiagnosticPreview {
        guard !text.isEmpty else { return DiagnosticPreview(text: text, isTruncated: false) }

        let totalByteCount = text.utf8.count
        var lines = normalizedLines(of: text)
        // Only the single-visual-line (menu) contexts collapse a trailing
        // line terminator's otherwise-empty final segment: that mode is
        // already reformatting every line break into a visible separator,
        // so charging one of its (small) line budget/appending a trailing
        // separator for the near-universal "stdout ends in one newline"
        // case would be pure noise.
        if limits.collapsesNewlines, lines.count > 1, let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        let totalLineCount = lines.count

        let lineTruncated = lines.count > limits.maxLines
        let sanitizedLines = lines.prefix(limits.maxLines).map(sanitizeLine)
        let joined = sanitizedLines.joined(separator: limits.collapsesNewlines ? " \u{240A} " : "\n")

        let clusterCapped = capGraphemeClusters(joined, limit: limits.maxGraphemeClusters)
        let byteCapped = capUTF8Bytes(clusterCapped.text, limit: limits.maxUTF8Bytes)

        let isTruncated = lineTruncated || clusterCapped.isTruncated || byteCapped.isTruncated
        guard isTruncated else {
            return DiagnosticPreview(text: byteCapped.text, isTruncated: false)
        }
        return DiagnosticPreview(
            text: byteCapped.text + truncationMarker(totalBytes: totalByteCount, totalLines: totalLineCount),
            isTruncated: true
        )
    }

    /// Splits `text` into lines on `\n`, `\r\n`, and lone `\r` (all three are
    /// legitimate line-ending conventions in untrusted command output).
    /// Walks `unicodeScalars` rather than `Character`s: Swift's grapheme
    /// clustering treats `\r\n` as a single `Character`, which would make a
    /// plain `Character`-level comparison against `"\r"`/`"\n"` miss it
    /// entirely (`String.Index` is shared across both views, so slicing
    /// `text` with scalar-view indices is safe).
    private static func normalizedLines(of text: String) -> [Substring] {
        var lines: [Substring] = []
        var lineStart = text.startIndex
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" {
                lines.append(text[lineStart..<index])
                index = scalars.index(after: index)
                lineStart = index
            } else if scalar == "\r" {
                lines.append(text[lineStart..<index])
                index = scalars.index(after: index)
                if index < scalars.endIndex, scalars[index] == "\n" {
                    index = scalars.index(after: index)
                }
                lineStart = index
            } else {
                index = scalars.index(after: index)
            }
        }
        lines.append(text[lineStart..<text.endIndex])
        return lines
    }

    /// Replaces NUL, other C0/C1 controls, and bidi format controls with a
    /// visible placeholder so they cannot be invisible, misleadingly reorder
    /// surrounding text, or otherwise distort the menu. Tab is included
    /// because an unescaped tab can misalign a single-line menu title just
    /// as effectively as a stray newline. Ordinary printable Unicode
    /// (including combining marks and multi-scalar emoji) passes through
    /// unchanged. Every substitution below is exactly one scalar, so this
    /// appends one scalar per input scalar directly into a shared buffer --
    /// no per-character `String` allocation -- keeping one sanitize pass over
    /// a multi-megabyte retained-output line fast.
    private static func sanitizeLine(_ line: Substring) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars {
            result.append(sanitizedScalar(scalar))
        }
        return String(result)
    }

    private static func sanitizedScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let value = scalar.value
        switch value {
        case 0x00...0x1F:
            // Control Pictures block (U+2400...U+241F) mirrors the C0 range
            // one-to-one, giving every C0 control (including tab) a
            // distinct, visible glyph instead of a lossy generic
            // placeholder.
            return Unicode.Scalar(0x2400 + value)!
        case 0x7F:
            return "\u{2421}" // SYMBOL FOR DELETE
        case 0x80...0x9F: // C1 controls
            return "\u{FFFD}"
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: // bidi format controls
            return "\u{FFFD}"
        default:
            return scalar
        }
    }

    private static func capGraphemeClusters(_ text: String, limit: Int) -> (text: String, isTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    /// Drops whole grapheme clusters from the end until the remainder fits
    /// within `limit` UTF-8 bytes, so the byte cap can never split a
    /// cluster even when individual clusters are multiple bytes wide.
    private static func capUTF8Bytes(_ text: String, limit: Int) -> (text: String, isTruncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var result = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= limit else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return (result, true)
    }

    private static func truncationMarker(totalBytes: Int, totalLines: Int) -> String {
        " \u{2026} (truncated, \(totalBytes) bytes / \(totalLines) line\(totalLines == 1 ? "" : "s") total)"
    }
}
