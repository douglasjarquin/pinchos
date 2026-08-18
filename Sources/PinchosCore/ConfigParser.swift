import Foundation
import TOMLKit

public enum ConfigParser {
    static let supportedItemKeys: Set<String> = [
        "type",
        "run",
        "shell",
        "working_directory",
        "env",
        "interval",
        "timeout",
        "max_output",
        "format",
        "click",
        "refresh_on_click",
        "error_text",
        "on_error",
        "stale_after",
        "tooltip",
        "action",
        "icon"
    ]

    static let supportedActionKeys: Set<String> = ["title", "run", "refresh"]

    public static func parse(_ text: String, relativeTo configURL: URL? = nil) throws -> PinchosConfig {
        let order = declaredItemOrder(in: text)
        let sourceLines = sourceLineMap(in: text)

        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            throw ConfigParseError(message: error.description, line: error.source.begin.line)
        }

        guard let itemSection = table["item"]?.table else {
            return PinchosConfig(items: [])
        }

        let items = try order.compactMap { name -> ItemConfig? in
            guard let itemTable = itemSection[name]?.table else { return nil }
            return try parseItem(
                name: name,
                table: itemTable,
                relativeTo: configURL,
                sourceLines: sourceLines
            )
        }
        return PinchosConfig(items: items)
    }

    private static func declaredItemOrder(in text: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let components = headerComponents(in: line) ?? arrayHeaderComponents(in: line), components.count >= 2,
                  components[0] == "item" else { continue }
            let name = components[1]
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            order.append(name)
        }
        return order
    }

    private static func sourceLineMap(in text: String) -> [String: Int] {
        var lines: [String: Int] = [:]
        var currentItem: String?
        var currentSection: String?
        var multilineDelimiter: String?

        var actionIndices: [String: Int] = [:]
        var currentActionIndex: Int?

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let delimiter = multilineDelimiter {
                if unescapedDelimiterCount(delimiter, in: line) > 0 {
                    multilineDelimiter = nil
                }
                continue
            }

            if let components = arrayHeaderComponents(in: line), components.count >= 3,
               components[0] == "item" {
                let name = components[1]
                currentItem = name
                let section = components.dropFirst(2).joined(separator: ".")
                currentSection = section
                if section == "action" {
                    let index = actionIndices[name, default: 0]
                    actionIndices[name] = index + 1
                    currentActionIndex = index
                    lines["\(name).action[\(index)]"] = lineNumber
                } else {
                    currentActionIndex = nil
                }
                lines["\(name).\(section)"] = lineNumber
                continue
            }

            if let components = headerComponents(in: line), components.count >= 2,
               components[0] == "item" {
                let name = components[1]
                currentItem = name
                currentSection = components.count == 2 ? nil : components.dropFirst(2).joined(separator: ".")
                currentActionIndex = nil
                lines[name] = lines[name] ?? lineNumber
                if let currentSection {
                    lines["\(name).\(currentSection)"] = lineNumber
                }
                continue
            }

            guard let currentItem, let equals = assignmentSeparator(in: line) else { continue }
            let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }
            let path: String
            if currentSection == "action", let currentActionIndex {
                path = "\(currentItem).action[\(currentActionIndex)].\(key)"
            } else {
                path = [currentItem, currentSection, key]
                    .compactMap { $0 }
                    .joined(separator: ".")
            }
            lines[path] = lineNumber
            multilineDelimiter = openMultilineDelimiter(in: String(line[line.index(after: equals)...]))
        }

        return lines
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

    private static func sourceLine(
        item name: String,
        key: String,
        index: Int? = nil,
        sourceLines: [String: Int]
    ) -> Int? {
        if let index {
            return sourceLines["\(name).action[\(index)].\(key)"]
                ?? sourceLines["\(name).action[\(index)]"]
                ?? sourceLines["\(name).action"]
                ?? sourceLines[name]
        }
        return sourceLines["\(name).\(key)"] ?? sourceLines[name]
    }

    private static func parseItem(
        name: String,
        table: TOMLTable,
        relativeTo configURL: URL?,
        sourceLines: [String: Int]
    ) throws -> ItemConfig {
        try validateUnknownKeys(
            in: table,
            allowedKeys: supportedItemKeys,
            context: "item.\(name)",
            lineForKey: { sourceLine(item: name, key: $0, sourceLines: sourceLines) }
        )

        let type = try requiredString(
            name: name,
            key: "type",
            table: table,
            sourceLines: sourceLines
        )
        guard type == "command" else {
            throw ConfigParseError(
                message: "item.\(name).type: unsupported value '\(type)' (only 'command' is supported)",
                line: sourceLine(item: name, key: "type", sourceLines: sourceLines)
            )
        }
        let run = try requiredString(
            name: name,
            key: "run",
            table: table,
            sourceLines: sourceLines,
            requireNonEmpty: true
        )

        let shell = try parseShell(
            name: name,
            value: table["shell"],
            relativeTo: configURL,
            sourceLines: sourceLines
        )
        let workingDirectory = try parseWorkingDirectory(
            name: name,
            value: table["working_directory"],
            relativeTo: configURL,
            sourceLines: sourceLines
        )
        let environment = try parseEnvironment(name: name, value: table["env"], sourceLines: sourceLines)

        let intervalString = try optionalString(
            name: name,
            key: "interval",
            table: table,
            sourceLines: sourceLines
        ) ?? "60s"
        let refreshInterval: RefreshInterval
        if intervalString == "manual" {
            refreshInterval = .manual
        } else {
            let interval: TimeInterval
            do {
                interval = try parseDuration(intervalString)
            } catch {
                throw ConfigParseError(
                    message: "item.\(name): invalid interval '\(intervalString)'",
                    line: sourceLine(item: name, key: "interval", sourceLines: sourceLines)
                )
            }
            refreshInterval = .scheduled(interval)
        }

        let refreshOnClick: Bool
        if let refreshOnClickValue = table["refresh_on_click"] {
            guard let value = refreshOnClickValue.bool else {
                throw typeError(
                    path: "item.\(name).refresh_on_click",
                    expected: "boolean",
                    value: refreshOnClickValue,
                    line: sourceLine(item: name, key: "refresh_on_click", sourceLines: sourceLines)
                )
            }
            refreshOnClick = value
        } else {
            refreshOnClick = false
        }

        let onError: ItemErrorPolicy
        if let onErrorValue = table["on_error"] {
            let rawValue = try stringValue(
                name: name,
                key: "on_error",
                value: onErrorValue,
                sourceLines: sourceLines
            )
            guard let parsedValue = ItemErrorPolicy(rawValue: rawValue) else {
                throw ConfigParseError(
                    message: "item.\(name): on_error must be 'replace' or 'keep_last'",
                    line: sourceLine(item: name, key: "on_error", sourceLines: sourceLines)
                )
            }
            onError = parsedValue
        } else {
            onError = .replace
        }

        let staleAfter: TimeInterval?
        if let staleAfterValue = table["stale_after"] {
            let rawValue = try stringValue(
                name: name,
                key: "stale_after",
                value: staleAfterValue,
                sourceLines: sourceLines
            )
            do {
                staleAfter = try parseDuration(rawValue)
            } catch {
                throw ConfigParseError(
                    message: "item.\(name): invalid stale_after '\(rawValue)'",
                    line: sourceLine(item: name, key: "stale_after", sourceLines: sourceLines)
                )
            }
        } else {
            staleAfter = nil
        }

        let tooltip: String?
        if let tooltipValue = table["tooltip"] {
            let value = try stringValue(
                name: name,
                key: "tooltip",
                value: tooltipValue,
                sourceLines: sourceLines
            )
            do {
                try validateTooltipTemplate(value)
            } catch let error as TooltipTemplateError {
                throw ConfigParseError(
                    message: "item.\(name): invalid tooltip (\(error))",
                    line: sourceLine(item: name, key: "tooltip", sourceLines: sourceLines)
                )
            }
            tooltip = value
        } else {
            tooltip = nil
        }

        let actions = try parseActions(
            name: name,
            value: table["action"],
            sourceLines: sourceLines
        )

        let timeoutString: String
        if let timeoutValue = table["timeout"] {
            timeoutString = try stringValue(
                name: name,
                key: "timeout",
                value: timeoutValue,
                sourceLines: sourceLines
            )
        } else {
            timeoutString = "15s"
        }
        let timeout: TimeInterval
        do {
            timeout = try parseDuration(timeoutString)
        } catch {
            throw ConfigParseError(
                message: "item.\(name): invalid timeout '\(timeoutString)'",
                line: sourceLine(item: name, key: "timeout", sourceLines: sourceLines)
            )
        }

        let maxOutputString: String
        if let maxOutputValue = table["max_output"] {
            maxOutputString = try stringValue(
                name: name,
                key: "max_output",
                value: maxOutputValue,
                sourceLines: sourceLines
            )
        } else {
            maxOutputString = "64KiB"
        }
        let maxOutputBytes: Int
        do {
            maxOutputBytes = try parseByteCount(maxOutputString)
        } catch {
            throw ConfigParseError(
                message: "item.\(name): invalid max_output '\(maxOutputString)'",
                line: sourceLine(item: name, key: "max_output", sourceLines: sourceLines)
            )
        }

        let icon: String?
        if let iconValue = table["icon"] {
            let rawIcon = try stringValue(
                name: name,
                key: "icon",
                value: iconValue,
                sourceLines: sourceLines
            )
            icon = resolvePath(rawIcon, relativeTo: configURL)
        } else {
            icon = nil
        }

        return ItemConfig(
            name: name,
            run: run,
            interval: refreshInterval,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            shell: shell,
            workingDirectory: workingDirectory,
            environment: environment,
            format: try optionalString(
                name: name,
                key: "format",
                table: table,
                sourceLines: sourceLines
            ),
            click: try optionalString(
                name: name,
                key: "click",
                table: table,
                sourceLines: sourceLines,
                requireNonEmpty: true
            ),
            refreshOnClick: refreshOnClick,
            errorText: try optionalString(
                name: name,
                key: "error_text",
                table: table,
                sourceLines: sourceLines
            ) ?? "\u{2013}",
            onError: onError,
            staleAfter: staleAfter,
            tooltip: tooltip,
            actions: actions,
            icon: icon
        )
    }

    private static func parseActions(
        name: String,
        value: TOMLValueConvertible?,
        sourceLines: [String: Int]
    ) throws -> [ItemAction] {
        guard let value else { return [] }
        guard let array = value.array else {
            throw typeError(
                path: "item.\(name).action",
                expected: "array",
                value: value,
                line: sourceLine(item: name, key: "action", sourceLines: sourceLines)
            )
        }

        return try array.enumerated().map { index, element in
            guard let table = element.table else {
                throw typeError(
                    path: "item.\(name).action[\(index)]",
                    expected: "table",
                    value: element,
                    line: sourceLine(item: name, key: "action", index: index, sourceLines: sourceLines)
                )
            }

            try validateUnknownKeys(
                in: table,
                allowedKeys: supportedActionKeys,
                context: "item.\(name).action[\(index)]",
                lineForKey: { sourceLine(item: name, key: $0, index: index, sourceLines: sourceLines) }
            )

            guard let titleValue = table["title"] else {
                throw ConfigParseError(
                    message: "item.\(name).action[\(index)].title: missing required field",
                    line: sourceLine(item: name, key: "action", index: index, sourceLines: sourceLines)
                )
            }
            let title = try stringValue(
                path: "item.\(name).action[\(index)].title",
                value: titleValue,
                requireNonEmpty: true,
                line: sourceLine(item: name, key: "title", index: index, sourceLines: sourceLines)
            )

            let runValue = table["run"]
            let run = try runValue.map {
                try stringValue(
                    path: "item.\(name).action[\(index)].run",
                    value: $0,
                    requireNonEmpty: true,
                    line: sourceLine(item: name, key: "run", index: index, sourceLines: sourceLines)
                )
            }
            let refresh: Bool?
            if let refreshValue = table["refresh"] {
                guard let parsedRefresh = refreshValue.bool else {
                    throw typeError(
                        path: "item.\(name).action[\(index)].refresh",
                        expected: "boolean",
                        value: refreshValue,
                        line: sourceLine(item: name, key: "refresh", index: index, sourceLines: sourceLines)
                    )
                }
                refresh = parsedRefresh
            } else {
                refresh = nil
            }

            if run != nil, refresh != nil {
                throw ConfigParseError(
                    message: "item.\(name).action[\(index)]: specify either run or refresh = true, not both",
                    line: sourceLine(item: name, key: "action", index: index, sourceLines: sourceLines)
                )
            }
            if let run {
                return ItemAction(title: title, kind: .command(run))
            }
            guard refresh == true else {
                throw ConfigParseError(
                    message: "item.\(name).action[\(index)]: specify run or refresh = true",
                    line: sourceLine(item: name, key: "action", index: index, sourceLines: sourceLines)
                )
            }
            return ItemAction(title: title, kind: .refresh)
        }
    }

    private static func parseShell(
        name: String,
        value: TOMLValueConvertible?,
        relativeTo configURL: URL?,
        sourceLines: [String: Int]
    ) throws -> [String] {
        guard let value else { return ItemConfig.defaultShell }
        guard let array = value.array else {
            throw typeError(
                path: "item.\(name).shell",
                expected: "array",
                value: value,
                line: sourceLine(item: name, key: "shell", sourceLines: sourceLines)
            )
        }

        var shell = [String]()
        for (index, element) in array.enumerated() {
            let argument = try stringValue(
                path: "item.\(name).shell[\(index)]",
                value: element,
                requireNonEmpty: true,
                line: sourceLine(item: name, key: "shell", sourceLines: sourceLines)
            )
            shell.append(argument)
        }
        guard let executable = shell.first else {
            throw ConfigParseError(
                message: "item.\(name): shell must include an executable",
                line: sourceLine(item: name, key: "shell", sourceLines: sourceLines)
            )
        }

        shell[0] = resolvePath(executable, relativeTo: configURL)
        guard FileManager.default.isExecutableFile(atPath: shell[0]) else {
            throw ConfigParseError(
                message: "item.\(name): shell executable cannot be resolved: \(shell[0])",
                line: sourceLine(item: name, key: "shell", sourceLines: sourceLines)
            )
        }
        return shell
    }

    private static func parseWorkingDirectory(
        name: String,
        value: TOMLValueConvertible?,
        relativeTo configURL: URL?,
        sourceLines: [String: Int]
    ) throws -> String? {
        guard let value else { return nil }
        guard let rawPath = value.string else {
            throw typeError(
                path: "item.\(name).working_directory",
                expected: "string",
                value: value,
                line: sourceLine(item: name, key: "working_directory", sourceLines: sourceLines)
            )
        }

        let path = resolvePath(rawPath, relativeTo: configURL)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigParseError(
                message: "item.\(name): working_directory cannot be resolved: \(path)",
                line: sourceLine(item: name, key: "working_directory", sourceLines: sourceLines)
            )
        }
        return path
    }

    private static func parseEnvironment(
        name: String,
        value: TOMLValueConvertible?,
        sourceLines: [String: Int]
    ) throws -> [String: String] {
        guard let value else { return [:] }
        guard let table = value.table else {
            throw typeError(
                path: "item.\(name).env",
                expected: "table",
                value: value,
                line: sourceLines["\(name).env"] ?? sourceLines[name]
            )
        }

        var environment = [String: String]()
        for (key, value) in table {
            guard isValidEnvironmentName(key) else {
                throw ConfigParseError(
                    message: "item.\(name).env.\(key): invalid environment key; not a valid environment name",
                    line: sourceLine(item: name, key: "env.\(key)", sourceLines: sourceLines)
                )
            }
            guard let string = value.string else {
                throw typeError(
                    path: "item.\(name).env.\(key)",
                    expected: "string",
                    value: value,
                    line: sourceLine(item: name, key: "env.\(key)", sourceLines: sourceLines)
                )
            }
            guard !string.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ConfigParseError(
                    message: "item.\(name).env.\(key) must be a string without NUL bytes",
                    line: sourceLine(item: name, key: "env.\(key)", sourceLines: sourceLines)
                )
            }
            environment[key] = string
        }
        return environment
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first else { return false }
        guard first == 95 || first >= 65 && first <= 90 || first >= 97 && first <= 122 else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            byte == 95 || byte >= 48 && byte <= 57 || byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
        }
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

    private static func requiredString(
        name: String,
        key: String,
        table: TOMLTable,
        sourceLines: [String: Int],
        requireNonEmpty: Bool = false
    ) throws -> String {
        guard let value = table[key] else {
            throw ConfigParseError(
                message: "item.\(name): missing required field '\(key)'",
                line: sourceLine(item: name, key: key, sourceLines: sourceLines)
            )
        }
        return try stringValue(
            path: "item.\(name).\(key)",
            value: value,
            requireNonEmpty: requireNonEmpty,
            line: sourceLine(item: name, key: key, sourceLines: sourceLines)
        )
    }

    private static func optionalString(
        name: String,
        key: String,
        table: TOMLTable,
        sourceLines: [String: Int],
        requireNonEmpty: Bool = false
    ) throws -> String? {
        guard let value = table[key] else { return nil }
        return try stringValue(
            path: "item.\(name).\(key)",
            value: value,
            requireNonEmpty: requireNonEmpty,
            line: sourceLine(item: name, key: key, sourceLines: sourceLines)
        )
    }

    private static func stringValue(
        name: String,
        key: String,
        value: TOMLValueConvertible,
        sourceLines: [String: Int],
        requireNonEmpty: Bool = false
    ) throws -> String {
        try stringValue(
            path: "item.\(name).\(key)",
            value: value,
            requireNonEmpty: requireNonEmpty,
            line: sourceLine(item: name, key: key, sourceLines: sourceLines)
        )
    }

    private static func stringValue(
        path: String,
        value: TOMLValueConvertible,
        requireNonEmpty: Bool,
        line: Int?
    ) throws -> String {
        guard let string = value.string else {
            throw typeError(path: path, expected: "string", value: value, line: line)
        }
        guard !requireNonEmpty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigParseError(
                message: "\(path) must be a non-empty string",
                line: line
            )
        }
        return string
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
        guard let configURL else { return expandedPath }
        return URL(fileURLWithPath: expandedPath, relativeTo: configURL.deletingLastPathComponent())
            .standardizedFileURL
            .path
    }
}
