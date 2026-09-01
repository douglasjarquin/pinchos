import Foundation
import TOMLKit

public enum ConfigParser {
    static let supportedItemKeys: Set<String> = ["run", "interval", "timeout", "format", "symbol", "icon", "menu"]
    static let supportedMenuKeys: Set<String> = ["label", "value", "run", "action", "cache", "separator"]
    static let supportedRootKeys: Set<String> = ["item"]

    public static func parse(_ text: String, relativeTo configURL: URL? = nil) throws -> PinchosConfig {
        try parseCanonical(text, relativeTo: configURL)
    }

    private static func headerComponents(in line: String) -> [String]? {
        let line = withoutInlineComment(from: line)
        guard line.first == "[", line.last == "]" else { return nil }
        guard !line.hasPrefix("[["),
              !line.hasSuffix("]]") else { return nil }

        return components(in: line, openingLength: 1, closingLength: 1)
    }

    private static func arrayHeaderComponents(in line: String) -> [String]? {
        let line = withoutInlineComment(from: line)
        guard line.hasPrefix("[["),
              line.hasSuffix("]]") else { return nil }
        return components(in: line, openingLength: 2, closingLength: 2)
    }

    private static func withoutInlineComment(from line: String) -> String {
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
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index]).trimmingCharacters(in: .whitespaces)
            }
        }

        return line
    }

    private static func components(
        in line: String,
        openingLength: Int,
        closingLength: Int
    ) -> [String]? {
        guard line.count >= openingLength + closingLength else { return nil }

        var components = [String]()
        var component = ""
        var quote: Character?
        var escaped = false
        var basicQuotedComponent = false

        func appendComponent() {
            let value = component.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            components.append(basicQuotedComponent ? decodeBasicKey(value) : value)
            component.removeAll(keepingCapacity: true)
            basicQuotedComponent = false
        }

        let start = line.index(line.startIndex, offsetBy: openingLength)
        let end = line.index(line.endIndex, offsetBy: -closingLength)
        for character in line[start..<end] {
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
                    component.append("\\")
                    component.append(character)
                    escaped = false
                } else if activeQuote == "\"", character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                } else {
                    component.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                basicQuotedComponent = character == "\""
            } else if character == "." {
                appendComponent()
            } else {
                component.append(character)
            }
        }

        guard quote == nil, !escaped else { return nil }
        appendComponent()
        return components
    }

    private static func decodeBasicKey(_ value: String) -> String {
        let characters = Array(value)
        var decoded = String()
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard character == "\\" else {
                decoded.append(character)
                index += 1
                continue
            }

            guard index + 1 < characters.count else { return value }
            let escape = characters[index + 1]
            switch escape {
            case "b": decoded.append("\u{8}")
            case "t": decoded.append("\t")
            case "n": decoded.append("\n")
            case "f": decoded.append("\u{C}")
            case "r": decoded.append("\r")
            case "\"": decoded.append("\"")
            case "\\": decoded.append("\\")
            case "u", "U":
                let digitCount = escape == "u" ? 4 : 8
                let firstDigit = index + 2
                let lastDigit = firstDigit + digitCount
                guard lastDigit <= characters.count else { return value }
                let hex = String(characters[firstDigit..<lastDigit])
                guard let scalarValue = UInt32(hex, radix: 16),
                      let scalar = UnicodeScalar(scalarValue) else { return value }
                decoded.unicodeScalars.append(scalar)
                index = lastDigit
                continue
            default:
                return value
            }
            index += 2
        }

        return decoded
    }

    private static func assignmentKeyComponents(_ rawKey: String) -> [String] {
        let key = rawKey.trimmingCharacters(in: .whitespaces)
        return components(in: key, openingLength: 0, closingLength: 0) ?? [key]
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
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            } else if character == "#" {
                return nil
            }
        }
        return nil
    }

    private static func openMultilineDelimiter(in value: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] {
            let count = unescapedDelimiterCount(delimiter, in: value)
            if count % 2 == 1 {
                return delimiter
            }
        }
        return nil
    }

    private static func unescapedDelimiterCount(_ delimiter: String, in value: String) -> Int {
        var count = 0
        var searchStart = value.startIndex
        while let range = value.range(of: delimiter, range: searchStart..<value.endIndex) {
            if !isEscaped(at: range.lowerBound, in: value) {
                count += 1
            }
            searchStart = range.upperBound
        }
        return count
    }

    private static func isEscaped(at index: String.Index, in value: String) -> Bool {
        var backslashCount = 0
        var cursor = index
        while cursor > value.startIndex {
            cursor = value.index(before: cursor)
            guard value[cursor] == "\\" else { break }
            backslashCount += 1
        }
        return backslashCount % 2 == 1
    }

    private static func validateUnknownKeys(
        in table: TOMLTable,
        allowedKeys: Set<String>,
        context: String,
        lineForKey: (String) -> Int?
    ) throws {
        for key in table.keys.sorted() where !allowedKeys.contains(key) {
            let suggestion = nearestKey(to: key, among: allowedKeys)
                .map { "; did you mean '\($0)'?" } ?? ""
            throw ConfigParseError(
                message: "\(context).\(key): unknown key\(suggestion)",
                line: lineForKey(key)
            )
        }
    }

    private static func typeError(
        path: String,
        expected: String,
        value: TOMLValueConvertible,
        line: Int?
    ) -> ConfigParseError {
        let article = ["array", "integer", "floating-point number"].contains(expected) ? "an" : "a"
        return ConfigParseError(
            message: "\(path): type error, must be \(article) \(expected) (got \(value.type.description))",
            line: line
        )
    }

    private static func nearestKey(to key: String, among allowedKeys: Set<String>) -> String? {
        let candidates = allowedKeys.compactMap { candidate -> (String, Int)? in
            let distance = editDistance(key, candidate)
            return distance <= 2 ? (candidate, distance) : nil
        }
        guard let bestDistance = candidates.map(\.1).min() else { return nil }
        let best = candidates.filter { $0.1 == bestDistance }.map(\.0).sorted()
        guard best.count == 1 else { return nil }
        return best[0]
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        var previous = Array(0...rhsCharacters.count)

        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            var current = [lhsIndex + 1]
            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }

        return previous[rhsCharacters.count]
    }

    private static func resolvePath(_ rawPath: String, relativeTo configURL: URL?) -> String {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let url: URL
        if let configURL {
            url = URL(fileURLWithPath: expandedPath, relativeTo: configURL.deletingLastPathComponent())
        } else {
            url = URL(fileURLWithPath: expandedPath)
        }
        return url
            .standardizedFileURL
            .path
    }

    private struct CanonicalSourceMap {
        var order: [String] = []
        var rootLines: [String: Int] = [:]
        var itemLines: [String: Int] = [:]
        var fieldLines: [String: Int] = [:]
        var menuRows: [String: Int] = [:]

        func line(item: String, key: String, row: Int? = nil) -> Int? {
            if let row {
                return fieldLines["\(item).menu[\(row)].\(key)"]
                    ?? fieldLines["\(item).menu[\(row)]"]
            }
            return fieldLines["\(item).\(key)"] ?? itemLines[item]
        }
    }

    private enum CanonicalSection {
        case item(String)
        case menu(String, Int)
    }

    private static func parseCanonical(_ text: String, relativeTo configURL: URL?) throws -> PinchosConfig {
        let source = try scanCanonicalSource(text)
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            throw ConfigParseError(message: error.description, line: error.source.begin.line)
        }

        for key in table.keys where !supportedRootKeys.contains(key) {
            throw ConfigParseError(
                message: "unsupported root key or table '\(key)' (only [item.<id>] is supported)",
                line: source.rootLines[key]
            )
        }
        guard let itemValue = table["item"] else { return PinchosConfig(items: []) }
        guard let itemSection = itemValue.table else {
            throw ConfigParseError(
                message: "item must contain [item.<id>] tables",
                line: source.rootLines["item"]
            )
        }

        let parsedNames = Set(itemSection.keys)
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
            return try parseCanonicalItem(
                name: name,
                table: itemTable,
                relativeTo: configURL,
                source: source
            )
        }
        return PinchosConfig(items: items)
    }

    private static func scanCanonicalSource(_ text: String) throws -> CanonicalSourceMap {
        var source = CanonicalSourceMap()
        var section: CanonicalSection?
        var multilineDelimiter: String?

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let raw = String(rawLine)
            if let delimiter = multilineDelimiter {
                if unescapedDelimiterCount(delimiter, in: raw) % 2 == 1 { multilineDelimiter = nil }
                continue
            }
            let line = withoutInlineComment(from: raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let components = arrayHeaderComponents(in: line) {
                guard components.count == 3, components[0] == "item", components[2] == "menu",
                      !headerUsesQuotedKey(line), isCanonicalItemID(components[1]) else {
                    throw ConfigParseError(
                        message: "items and menu rows must use [item.<id>] and [[item.<id>.menu]] declarations",
                        line: lineNumber
                    )
                }
                let name = components[1]
                let row = source.menuRows[name, default: 0]
                source.menuRows[name] = row + 1
                if !source.order.contains(name) { source.order.append(name) }
                source.itemLines[name] = source.itemLines[name] ?? lineNumber
                source.fieldLines["\(name).menu[\(row)]"] = lineNumber
                section = .menu(name, row)
                multilineDelimiter = nil
                continue
            }

            if let components = headerComponents(in: line) {
                if components.count == 1 {
                    let root = components[0]
                    source.rootLines[root] = source.rootLines[root] ?? lineNumber
                    throw ConfigParseError(
                        message: "unsupported root key or table '\(root)' (only [item.<id>] is supported)",
                        line: lineNumber
                    )
                }
                guard components.count == 2, components[0] == "item",
                      !headerUsesQuotedKey(line), isCanonicalItemID(components.count > 1 ? components[1] : "") else {
                    let root = components.first ?? "item"
                    source.rootLines[root] = source.rootLines[root] ?? lineNumber
                    let message = components.count == 2 && components[0] != "item"
                        ? "unsupported root key or table '\(components[0])' (only [item.<id>] is supported)"
                        : "items must use exactly [item.<id>] tables"
                    throw ConfigParseError(
                        message: message,
                        line: lineNumber
                    )
                }
                let name = components[1]
                if !source.order.contains(name) { source.order.append(name) }
                source.itemLines[name] = source.itemLines[name] ?? lineNumber
                section = .item(name)
                continue
            }

            if let components = arrayHeaderComponents(in: line), let root = components.first {
                source.rootLines[root] = source.rootLines[root] ?? lineNumber
                throw ConfigParseError(
                    message: "unsupported array table '\(line)'",
                    line: lineNumber
                )
            }

            guard let equals = assignmentSeparator(in: line) else { continue }
            let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
            let key = String(rawKey)
            let keyComponents = assignmentKeyComponents(key)
            let rhs = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            multilineDelimiter = openMultilineDelimiter(in: rhs)

            switch section {
            case .item(let name):
                guard keyComponents.count == 1, !key.contains("\""), !key.contains("'") else {
                    throw ConfigParseError(
                        message: "item.\(name): nested, dotted, or quoted keys are not supported",
                        line: lineNumber
                    )
                }
                if keyComponents[0] == "menu" {
                    throw ConfigParseError(
                        message: "item.\(name).menu: use [[item.\(name).menu]] array tables",
                        line: lineNumber
                    )
                }
                source.fieldLines["\(name).\(keyComponents[0])"] = source.fieldLines["\(name).\(keyComponents[0])"] ?? lineNumber
            case .menu(let name, let row):
                guard keyComponents.count == 1, !key.contains("\""), !key.contains("'") else {
                    throw ConfigParseError(
                        message: "item.\(name).menu[\(row)]: nested, dotted, or quoted keys are not supported",
                        line: lineNumber
                    )
                }
                source.fieldLines["\(name).menu[\(row)].\(keyComponents[0])"] = lineNumber
            case nil:
                guard keyComponents.count == 1, !key.contains("\""), !key.contains("'") else {
                    source.rootLines[keyComponents.first ?? key] = source.rootLines[keyComponents.first ?? key] ?? lineNumber
                    throw ConfigParseError(
                        message: "root keys must be a single supported table name",
                        line: lineNumber
                    )
                }
                source.rootLines[keyComponents[0]] = source.rootLines[keyComponents[0]] ?? lineNumber
            }
        }
        return source
    }

    private static func headerUsesQuotedKey(_ line: String) -> Bool {
        let body = line.dropFirst(line.hasPrefix("[[") ? 2 : 1).dropLast(line.hasSuffix("]]" ) ? 2 : 1)
        return body.contains("\"") || body.contains("'")
    }

    private static func isCanonicalItemID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 95 || byte == 45
        }
    }

    private static func parseCanonicalItem(
        name: String,
        table: TOMLTable,
        relativeTo configURL: URL?,
        source: CanonicalSourceMap
    ) throws -> ItemConfig {
        try validateUnknownKeys(
            in: table,
            allowedKeys: supportedItemKeys,
            context: "item.\(name)",
            lineForKey: { source.line(item: name, key: $0) }
        )
        let run = try canonicalString(
            path: "item.\(name).run",
            value: table["run"],
            line: source.line(item: name, key: "run")
        )
        let interval = try canonicalInterval(name: name, value: table["interval"], source: source)
        let timeout = try canonicalDuration(name: name, key: "timeout", value: table["timeout"], defaultValue: 15, source: source)
        let format = try canonicalFormat(name: name, value: table["format"], source: source)
        let icon = try canonicalOptionalString(name: name, key: "icon", value: table["icon"], source: source)
        let symbol = try canonicalOptionalString(name: name, key: "symbol", value: table["symbol"], source: source)
        if icon != nil, symbol != nil {
            throw ConfigParseError(
                message: "item.\(name): icon and symbol are mutually exclusive",
                line: source.line(item: name, key: "symbol") ?? source.line(item: name, key: "icon")
            )
        }
        let menu: [MenuRowConfig]
        if let value = table["menu"] {
            guard let rows = value.array else {
                throw typeError(
                    path: "item.\(name).menu",
                    expected: "array",
                    value: value,
                    line: source.line(item: name, key: "menu")
                )
            }
            menu = try rows.enumerated().map { index, row in
                try parseCanonicalRow(name: name, index: index, value: row, source: source)
            }
        } else {
            menu = []
        }
        return ItemConfig(
            name: name,
            run: run,
            interval: interval,
            timeout: timeout,
            format: format,
            menu: menu,
            icon: icon.map { resolvePath($0, relativeTo: configURL) },
            symbol: symbol
        )
    }

    private static func parseCanonicalRow(
        name: String,
        index: Int,
        value: TOMLValueConvertible,
        source: CanonicalSourceMap
    ) throws -> MenuRowConfig {
        guard let table = value.table else {
            throw typeError(
                path: "item.\(name).menu[\(index)]",
                expected: "table",
                value: value,
                line: source.line(item: name, key: "menu", row: index)
            )
        }
        try validateUnknownKeys(
            in: table,
            allowedKeys: supportedMenuKeys,
            context: "item.\(name).menu[\(index)]",
            lineForKey: { source.line(item: name, key: $0, row: index) }
        )
        let separator = try canonicalOptionalBool(name: name, key: "separator", table: table, index: index, source: source)
        if separator == true {
            guard table.keys.count == 1 else {
                throw ConfigParseError(
                    message: "item.\(name).menu[\(index)]: separator = true cannot be combined with other fields",
                    line: source.line(item: name, key: "separator", row: index)
                )
            }
            return .init(separator: true)
        }
        if separator == false {
            throw ConfigParseError(
                message: "item.\(name).menu[\(index)].separator must be true when present",
                line: source.line(item: name, key: "separator", row: index)
            )
        }
        let label = try canonicalString(
            path: "item.\(name).menu[\(index)].label",
            value: table["label"],
            line: source.line(item: name, key: "label", row: index)
        )
        let staticValue = try canonicalOptionalString(name: name, key: "value", value: table["value"], row: index, source: source)
        let run = try canonicalOptionalString(name: name, key: "run", value: table["run"], row: index, source: source)
        let action = try canonicalOptionalString(name: name, key: "action", value: table["action"], row: index, source: source)
        let cache = try canonicalOptionalDuration(name: name, key: "cache", value: table["cache"], row: index, source: source)
        if cache != nil, run == nil {
            throw ConfigParseError(
                message: "item.\(name).menu[\(index)].cache requires run",
                line: source.line(item: name, key: "cache", row: index)
            )
        }
        guard staticValue != nil || run != nil || action != nil else {
            throw ConfigParseError(
                message: "item.\(name).menu[\(index)]: specify value, run, or action",
                line: source.line(item: name, key: "label", row: index)
            )
        }
        if staticValue != nil, run != nil {
            throw ConfigParseError(
                message: "item.\(name).menu[\(index)]: specify either value or run, not both",
                line: source.line(item: name, key: "run", row: index) ?? source.line(item: name, key: "value", row: index)
            )
        }
        return MenuRowConfig(label: label, value: staticValue, run: run, action: action, cache: cache)
    }

    private static func canonicalString(path: String, value: TOMLValueConvertible?, line: Int?) throws -> String {
        guard let value else {
            throw ConfigParseError(message: "\(path): missing required field", line: line)
        }
        guard let string = value.string else {
            throw typeError(path: path, expected: "string", value: value, line: line)
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigParseError(message: "\(path) must be a non-empty string", line: line)
        }
        return string
    }

    private static func canonicalOptionalString(
        name: String,
        key: String,
        value: TOMLValueConvertible?,
        row: Int? = nil,
        source: CanonicalSourceMap
    ) throws -> String? {
        guard value != nil else { return nil }
        let path = row.map { "item.\(name).menu[\($0)].\(key)" } ?? "item.\(name).\(key)"
        return try canonicalString(path: path, value: value, line: source.line(item: name, key: key, row: row))
    }

    private static func canonicalOptionalBool(
        name: String,
        key: String,
        table: TOMLTable,
        index: Int,
        source: CanonicalSourceMap
    ) throws -> Bool? {
        guard let value = table[key] else { return nil }
        guard let bool = value.bool else {
            throw typeError(
                path: "item.\(name).menu[\(index)].\(key)",
                expected: "boolean",
                value: value,
                line: source.line(item: name, key: key, row: index)
            )
        }
        return bool
    }

    private static func canonicalInterval(name: String, value: TOMLValueConvertible?, source: CanonicalSourceMap) throws -> RefreshInterval {
        guard let value else { return .scheduled(60) }
        let raw = try canonicalString(path: "item.\(name).interval", value: value, line: source.line(item: name, key: "interval"))
        if raw == "manual" { return .manual }
        do { return .scheduled(try parseDuration(raw)) }
        catch { throw ConfigParseError(message: "item.\(name): invalid interval '\(raw)'", line: source.line(item: name, key: "interval")) }
    }

    private static func canonicalDuration(
        name: String,
        key: String,
        value: TOMLValueConvertible?,
        defaultValue: TimeInterval,
        source: CanonicalSourceMap
    ) throws -> TimeInterval {
        guard let value else { return defaultValue }
        let raw = try canonicalString(path: "item.\(name).\(key)", value: value, line: source.line(item: name, key: key))
        do { return try parseDuration(raw) }
        catch { throw ConfigParseError(message: "item.\(name): invalid \(key) '\(raw)'", line: source.line(item: name, key: key)) }
    }

    private static func canonicalOptionalDuration(
        name: String,
        key: String,
        value: TOMLValueConvertible?,
        row: Int,
        source: CanonicalSourceMap
    ) throws -> TimeInterval? {
        guard let value else { return nil }
        let raw = try canonicalString(path: "item.\(name).menu[\(row)].\(key)", value: value, line: source.line(item: name, key: key, row: row))
        do { return try parseDuration(raw) }
        catch { throw ConfigParseError(message: "item.\(name).menu[\(row)]: invalid cache '\(raw)'", line: source.line(item: name, key: key, row: row)) }
    }

    private static func canonicalFormat(name: String, value: TOMLValueConvertible?, source: CanonicalSourceMap) throws -> String? {
        guard let format = try canonicalOptionalString(name: name, key: "format", value: value, source: source) else { return nil }
        let remainder = format.replacingOccurrences(of: "{output}", with: "")
        guard !remainder.contains("{") && !remainder.contains("}") else {
            throw ConfigParseError(message: "item.\(name).format may contain only {output}", line: source.line(item: name, key: "format"))
        }
        return format
    }
}
