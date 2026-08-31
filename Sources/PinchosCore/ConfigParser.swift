import Foundation
import TOMLKit

public enum ConfigParser {
    private static let supportedItemKeys: Set<String> = [
        "run", "interval", "timeout", "format", "symbol", "icon",
    ]

    public static func parse(_ text: String, relativeTo configURL: URL? = nil) throws -> PinchosConfig {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            throw ConfigParseError(message: error.description, line: error.source.begin.line)
        }

        let source = try scanSource(text)
        try validateRoot(table, source: source)

        guard let itemValue = table["item"] else {
            return PinchosConfig(items: [])
        }
        guard let itemSection = itemValue.table else {
            throw ConfigParseError(
                message: "'item' must contain [item.<id>] tables",
                line: source.rootLines["item"]
            )
        }

        let parsedNames = Set(itemSection.map { $0.0 })
        let declaredNames = Set(source.order)
        guard parsedNames == declaredNames else {
            let name = parsedNames.subtracting(declaredNames).sorted().first
            throw ConfigParseError(
                message: name.map { "item.\($0): use the canonical [item.\($0)] table declaration" }
                    ?? "items must use canonical [item.<id>] table declarations",
                line: name.flatMap { source.itemLines[$0] } ?? source.rootLines["item"]
            )
        }

        let items = try source.order.map { name -> ItemConfig in
            guard let value = itemSection[name], let itemTable = value.table else {
                throw ConfigParseError(
                    message: "item.\(name) must be a table",
                    line: source.itemLines[name]
                )
            }
            return try parseItem(
                name: name,
                table: itemTable,
                relativeTo: configURL,
                source: source
            )
        }
        return PinchosConfig(items: items)
    }

    private static func validateRoot(_ table: TOMLTable, source: SourceMap) throws {
        for (key, _) in table where key != "item" {
            throw ConfigParseError(
                message: "unsupported root key or table '\(key)' (only [item.<id>] is supported)",
                line: source.rootLines[key]
            )
        }
    }

    private static func parseItem(
        name: String,
        table: TOMLTable,
        relativeTo configURL: URL?,
        source: SourceMap
    ) throws -> ItemConfig {
        for (key, _) in table where !supportedItemKeys.contains(key) {
            throw ConfigParseError(
                message: "item.\(name): unknown key '\(key)'",
                line: source.line(item: name, key: key)
            )
        }

        let run = try requiredNonEmptyString(
            name: name,
            key: "run",
            value: table["run"],
            source: source
        )
        guard !run.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ConfigParseError(
                message: "item.\(name): run must not contain NUL bytes",
                line: source.line(item: name, key: "run")
            )
        }

        let interval = try parseInterval(name: name, value: table["interval"], source: source)
        let timeout = try parseTimeout(name: name, value: table["timeout"], source: source)
        let format = try parseFormat(name: name, value: table["format"], source: source)
        let icon = try optionalNonEmptyString(name: name, key: "icon", value: table["icon"], source: source)
        let symbol = try optionalNonEmptyString(name: name, key: "symbol", value: table["symbol"], source: source)

        if icon != nil, symbol != nil {
            throw ConfigParseError(
                message: "item.\(name): icon and symbol are mutually exclusive",
                line: source.line(item: name, key: "symbol")
                    ?? source.line(item: name, key: "icon")
            )
        }

        return ItemConfig(
            name: name,
            run: run,
            interval: interval,
            timeout: timeout,
            format: format,
            icon: icon.map { resolvePath($0, relativeTo: configURL) },
            symbol: symbol
        )
    }

    private static func requiredNonEmptyString(
        name: String,
        key: String,
        value: TOMLValueConvertible?,
        source: SourceMap
    ) throws -> String {
        guard let value else {
            throw ConfigParseError(
                message: "item.\(name): missing required field '\(key)'",
                line: source.itemLines[name]
            )
        }
        guard let string = value.string else {
            throw ConfigParseError(
                message: "item.\(name): \(key) must be a string",
                line: source.line(item: name, key: key)
            )
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigParseError(
                message: "item.\(name): \(key) must not be empty",
                line: source.line(item: name, key: key)
            )
        }
        return string
    }

    private static func optionalNonEmptyString(
        name: String,
        key: String,
        value: TOMLValueConvertible?,
        source: SourceMap
    ) throws -> String? {
        guard value != nil else { return nil }
        return try requiredNonEmptyString(name: name, key: key, value: value, source: source)
    }

    private static func parseInterval(
        name: String,
        value: TOMLValueConvertible?,
        source: SourceMap
    ) throws -> RefreshInterval {
        guard let value else { return .scheduled(ItemConfig.defaultInterval) }
        guard let raw = value.string else {
            throw ConfigParseError(
                message: "item.\(name): interval must be a duration string or 'manual'",
                line: source.line(item: name, key: "interval")
            )
        }
        if raw == "manual" { return .manual }
        do {
            return .scheduled(try parseDuration(raw))
        } catch {
            throw ConfigParseError(
                message: "item.\(name): invalid interval '\(raw)'",
                line: source.line(item: name, key: "interval")
            )
        }
    }

    private static func parseTimeout(
        name: String,
        value: TOMLValueConvertible?,
        source: SourceMap
    ) throws -> TimeInterval {
        guard let value else { return ItemConfig.defaultTimeout }
        guard let raw = value.string else {
            throw ConfigParseError(
                message: "item.\(name): timeout must be a duration string",
                line: source.line(item: name, key: "timeout")
            )
        }
        do {
            return try parseDuration(raw)
        } catch {
            throw ConfigParseError(
                message: "item.\(name): invalid timeout '\(raw)'",
                line: source.line(item: name, key: "timeout")
            )
        }
    }

    private static func parseFormat(
        name: String,
        value: TOMLValueConvertible?,
        source: SourceMap
    ) throws -> String? {
        guard let value else { return nil }
        guard let format = value.string else {
            throw ConfigParseError(
                message: "item.\(name): format must be a string",
                line: source.line(item: name, key: "format")
            )
        }
        do {
            try validateFormatTemplate(format)
        } catch {
            throw ConfigParseError(
                message: "item.\(name): invalid format (\(error))",
                line: source.line(item: name, key: "format")
            )
        }
        return format
    }

    private struct SourceMap {
        var order: [String] = []
        var itemLines: [String: Int] = [:]
        var fieldLines: [String: Int] = [:]
        var rootLines: [String: Int] = [:]

        func line(item: String, key: String) -> Int? {
            fieldLines["\(item).\(key)"] ?? itemLines[item]
        }
    }

    /// Narrow source pass used only for declaration order and line diagnostics.
    /// TOMLKit remains authoritative for syntax and values.
    private static func scanSource(_ text: String) throws -> SourceMap {
        var map = SourceMap()
        var currentItem: String?
        var multilineDelimiter: String?

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let raw = String(rawLine)

            if let delimiter = multilineDelimiter {
                if delimiterCount(delimiter, in: raw) % 2 == 1 {
                    multilineDelimiter = nil
                }
                continue
            }

            let line = stripInlineComment(from: raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") {
                throw ConfigParseError(
                    message: "array tables are not supported; use [item.<id>]",
                    line: lineNumber
                )
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { continue } // TOMLKit reports malformed headers.
                let body = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if body == "item" {
                    throw ConfigParseError(
                        message: "items must use [item.<id>] tables",
                        line: lineNumber
                    )
                }
                if body.hasPrefix("item.") {
                    let name = String(body.dropFirst("item.".count))
                    guard isSimpleItemID(name) else {
                        throw ConfigParseError(
                            message: "items must use exactly [item.<id>], where id contains only letters, numbers, '-' and '_'",
                            line: lineNumber
                        )
                    }
                    currentItem = name
                    if map.itemLines[name] == nil {
                        map.itemLines[name] = lineNumber
                        map.order.append(name)
                    }
                } else {
                    currentItem = nil
                    let root = String(body.split(separator: ".", maxSplits: 1).first ?? Substring(body))
                    map.rootLines[root] = map.rootLines[root] ?? lineNumber
                }
                continue
            }

            guard let equals = assignmentSeparator(in: line) else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if let currentItem {
                guard isBareKey(key) else {
                    throw ConfigParseError(
                        message: "item.\(currentItem): nested, dotted, or quoted keys are not supported",
                        line: lineNumber
                    )
                }
                map.fieldLines["\(currentItem).\(key)"] = lineNumber
            } else {
                if key == "item" || key.hasPrefix("item.") {
                    throw ConfigParseError(
                        message: "items must use [item.<id>] tables; dotted and inline declarations are not supported",
                        line: lineNumber
                    )
                }
                let root = String(key.split(separator: ".", maxSplits: 1).first ?? Substring(key))
                map.rootLines[root] = map.rootLines[root] ?? lineNumber
            }

            let value = String(line[line.index(after: equals)...])
            multilineDelimiter = openMultilineDelimiter(in: value)
        }
        return map
    }

    private static func isSimpleItemID(_ value: String) -> Bool {
        !value.isEmpty && isBareKey(value)
    }

    private static func isBareKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte == 45 || byte == 95 || (48...57).contains(byte)
                || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    private static func stripInlineComment(from line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func assignmentSeparator(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }
        return nil
    }

    private static func openMultilineDelimiter(in value: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] where delimiterCount(delimiter, in: value) % 2 == 1 {
            return delimiter
        }
        return nil
    }

    private static func delimiterCount(_ delimiter: String, in value: String) -> Int {
        var count = 0
        var start = value.startIndex
        while let range = value.range(of: delimiter, range: start..<value.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    private static func resolvePath(_ rawPath: String, relativeTo configURL: URL?) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard let configURL else { return expanded }
        return URL(fileURLWithPath: expanded, relativeTo: configURL.deletingLastPathComponent())
            .standardizedFileURL.path
    }
}
