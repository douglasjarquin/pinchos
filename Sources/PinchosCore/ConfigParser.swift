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
        "icon",
        "max_length",
        "hide_when_empty",
        "hide_on_error",
        "icon_only",
        "disabled"
    ]

    static let supportedActionKeys: Set<String> = ["title", "run", "refresh"]
    static let supportedRootKeys: Set<String> = ["item", "scheduler", "group"]
    static let supportedSchedulerKeys: Set<String> = ["max_active_sessions"]
    static let supportedGroupKeys: Set<String> = ["title", "members", "icon"]

    /// Which top-level namespace a scanned declaration name belongs to.
    /// Item and group names share one flat lookup space for membership
    /// references, but come from two distinct TOML tables (`[item.*]` vs
    /// `[group.*]`), so the scanner has to remember which table to read
    /// each discovered name back out of.
    private enum ItemNamespace: Equatable {
        case item
        case group
    }

    private enum SourceLineKey: Hashable {
        case rootField(String)
        case item(String)
        case section(item: String, path: String)
        case action(item: String, index: Int)
        case field(item: String, path: String, actionIndex: Int?)
    }

    private typealias SourceLineMap = [SourceLineKey: Int]

    public static func parse(_ text: String, relativeTo configURL: URL? = nil) throws -> PinchosConfig {
        let scan = try scanSource(text)
        let order = scan.order
        let sourceLines = scan.lines
        let namespace = scan.namespace

        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            throw ConfigParseError(message: error.description, line: error.source.begin.line)
        }

        try validateUnknownKeys(
            in: table,
            allowedKeys: supportedRootKeys,
            context: "root",
            lineForKey: { sourceLines[.rootField($0)] }
        )

        let scheduler = try parseScheduler(table: table, sourceLines: sourceLines)

        let itemNames = order.filter { namespace[$0] == .item }
        let groupNames = order.filter { namespace[$0] == .group }

        let itemSection = try namedSection(
            "item",
            table: table,
            discoveredNames: itemNames,
            sourceLines: sourceLines
        )
        let groupSection = try namedSection(
            "group",
            table: table,
            discoveredNames: groupNames,
            sourceLines: sourceLines
        )

        let items = try order.map { name -> ItemConfig in
            switch namespace[name] {
            case .item:
                let itemTable = try requiredTable(
                    name: name,
                    section: itemSection,
                    sectionKey: "item",
                    sourceLines: sourceLines
                )
                return .command(
                    try parseItem(
                        name: name,
                        table: itemTable,
                        relativeTo: configURL,
                        sourceLines: sourceLines
                    )
                )
            case .group:
                let groupTable = try requiredTable(
                    name: name,
                    section: groupSection,
                    sectionKey: "group",
                    sourceLines: sourceLines
                )
                return .group(
                    try parseGroup(
                        name: name,
                        table: groupTable,
                        relativeTo: configURL,
                        sourceLines: sourceLines
                    )
                )
            case nil:
                throw ConfigParseError(
                    message: "\(name): expected item was not found in the parsed configuration",
                    line: sourceLines[.item(name)]
                )
            }
        }

        try validateGroupMembership(items, sourceLines: sourceLines)

        return PinchosConfig(items: items, scheduler: scheduler)
    }

    /// Fetches the `[<sectionKey>.*]` table (`item` or `group`), when the
    /// scanner discovered at least one declaration in that namespace, and
    /// cross-checks the scanned name set against TOMLKit's parsed keys --
    /// mirroring `crossCheckDiscoveredItems`'s "the parsed tree is
    /// authoritative for existence" contract for both namespaces.
    private static func namedSection(
        _ sectionKey: String,
        table: TOMLTable,
        discoveredNames: [String],
        sourceLines: SourceLineMap
    ) throws -> TOMLTable? {
        guard let sectionValue = table[sectionKey] else {
            if discoveredNames.isEmpty {
                return nil
            }
            // The scanner found declarations but TOMLKit has no matching
            // root key at all; this should be unreachable given the
            // scanner and TOMLKit agree on syntax, but fail loudly rather
            // than silently dropping items if it ever happens.
            throw ConfigParseError(
                message: "\(sectionKey): expected declarations were not found in the parsed configuration",
                line: sourceLines[.rootField(sectionKey)]
            )
        }
        guard let sectionTable = sectionValue.table else {
            throw typeError(
                path: sectionKey,
                expected: "table",
                value: sectionValue,
                line: sourceLines[.rootField(sectionKey)]
            )
        }
        try crossCheckDiscoveredNames(
            sectionKey: sectionKey,
            discoveredNames: discoveredNames,
            section: sectionTable,
            sourceLines: sourceLines
        )
        return sectionTable
    }

    private static func requiredTable(
        name: String,
        section: TOMLTable?,
        sectionKey: String,
        sourceLines: SourceLineMap
    ) throws -> TOMLTable {
        guard let section, let value = section[name] else {
            throw ConfigParseError(
                message: "\(sectionKey).\(name): expected item was not found in the parsed configuration",
                line: sourceLines[.item(name)] ?? sourceLines[.rootField(sectionKey)]
            )
        }
        guard let itemTable = value.table else {
            throw typeError(
                path: "\(sectionKey).\(name)",
                expected: "table",
                value: value,
                line: sourceLines[.item(name)] ?? sourceLines[.rootField(sectionKey)]
            )
        }
        return itemTable
    }

    /// Parses the optional `[scheduler]` table, the sole advanced-user
    /// override of `CommandScheduler`'s default active-session bound. Absent
    /// entirely, `SchedulerConfig()` (no override) applies. When present,
    /// `max_active_sessions` must be an integer within
    /// `CommandScheduler.allowedMaxActiveSessionsRange`; anything else fails
    /// validation rather than silently clamping, so a typo'd config cannot
    /// silently run with a very different concurrency budget than intended.
    private static func parseScheduler(
        table: TOMLTable,
        sourceLines: SourceLineMap
    ) throws -> SchedulerConfig {
        guard let schedulerValue = table["scheduler"] else {
            return SchedulerConfig()
        }
        guard let schedulerTable = schedulerValue.table else {
            throw typeError(
                path: "scheduler",
                expected: "table",
                value: schedulerValue,
                line: sourceLines[.rootField("scheduler")]
            )
        }
        try validateUnknownKeys(
            in: schedulerTable,
            allowedKeys: supportedSchedulerKeys,
            context: "scheduler",
            lineForKey: { sourceLines[.rootField($0)] ?? sourceLines[.rootField("scheduler")] }
        )

        guard let maxActiveSessionsValue = schedulerTable["max_active_sessions"] else {
            return SchedulerConfig()
        }
        let line = sourceLines[.rootField("max_active_sessions")] ?? sourceLines[.rootField("scheduler")]
        guard let maxActiveSessions = maxActiveSessionsValue.int else {
            throw typeError(
                path: "scheduler.max_active_sessions",
                expected: "integer",
                value: maxActiveSessionsValue,
                line: line
            )
        }
        guard CommandScheduler.allowedMaxActiveSessionsRange.contains(maxActiveSessions) else {
            throw ConfigParseError(
                message: "scheduler.max_active_sessions must be between "
                    + "\(CommandScheduler.allowedMaxActiveSessionsRange.lowerBound) and "
                    + "\(CommandScheduler.allowedMaxActiveSessionsRange.upperBound)",
                line: line
            )
        }
        return SchedulerConfig(maxActiveSessions: maxActiveSessions)
    }

    private static func crossCheckDiscoveredNames(
        sectionKey: String,
        discoveredNames: [String],
        section: TOMLTable,
        sourceLines: SourceLineMap
    ) throws {
        let parsedNames = Set(section.keys)
        let orderedNames = Set(discoveredNames)
        guard parsedNames != orderedNames else { return }

        if let missing = parsedNames.subtracting(orderedNames).sorted().first {
            throw ConfigParseError(
                message: "\(sectionKey).\(missing): declaration form is not supported; "
                    + "use [\(sectionKey).\(missing)] tables or \(sectionKey).\(missing).<key> dotted keys",
                line: sourceLines[.rootField(sectionKey)]
            )
        }
        if let extra = orderedNames.subtracting(parsedNames).sorted().first {
            throw ConfigParseError(
                message: "\(sectionKey).\(extra): expected item was not found in the parsed configuration",
                line: sourceLines[.item(extra)]
            )
        }
    }

    /// Scans the raw source text for three things in a single left-to-right pass:
    /// - `order`: the left-to-right declaration order of top-level entries (both `[item.*]` and
    ///   `[group.*]`), used for deterministic native menu-bar placement (TOMLKit's `TOMLTable`
    ///   iterates keys alphabetically, not in file order, and its parsed tree carries no
    ///   distinguishable source-order metadata).
    /// - `namespace`: which table (`item` or `group`) each discovered name belongs to, so the
    ///   caller knows where to look its value up in the TOMLKit-parsed tree.
    /// - `lines`: a map from semantic locations (item/group fields, actions, root keys) to the
    ///   1-based source line that declared them, used for diagnostics.
    ///
    /// Supported item-declaring forms are standard `[item.<name>]` / `[[item.<name>.<section>]]`
    /// table headers and top-level dotted-key assignments (`item.<name>.<key> = value`). Groups
    /// support the same two forms minus array-of-tables (`[group.<name>]` / `group.<name>.<key> =
    /// value`), since a group has no repeated sub-sections like an item's `action` array. Inline
    /// table declarations of an item/group or of the whole `item`/`group` namespace (`item = {
    /// ... }` or `item.<name> = { ... }`) are rejected explicitly here rather than silently
    /// producing an incomplete list: TOMLKit can parse them, but this scanner cannot recover
    /// their source order, and `PinchosConfig.parse` must never drop an entry TOMLKit considers
    /// valid.
    private static func scanSource(
        _ text: String
    ) throws -> (order: [String], namespace: [String: ItemNamespace], lines: SourceLineMap) {
        var lines: SourceLineMap = [:]
        var order: [String] = []
        var namespace: [String: ItemNamespace] = [:]
        var seenItemNames = Set<String>()
        var currentItem: String?
        var currentSection: String?
        var multilineDelimiter: String?

        var actionIndices: [String: Int] = [:]
        var currentActionIndex: Int?

        func recordItemName(_ name: String, at lineNumber: Int, namespace entryNamespace: ItemNamespace) throws {
            if let existing = namespace[name], existing != entryNamespace {
                let existingKey = existing == .item ? "item" : "group"
                let newKey = entryNamespace == .item ? "item" : "group"
                throw ConfigParseError(
                    message: "\(newKey).\(name): name is already declared as \(existingKey).\(name); "
                        + "item and group names share one namespace and must be unique",
                    line: lineNumber
                )
            }
            namespace[name] = entryNamespace
            if !seenItemNames.contains(name) {
                seenItemNames.insert(name)
                order.append(name)
            }
            lines[.item(name)] = lines[.item(name)] ?? lineNumber
        }

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
                try recordItemName(name, at: lineNumber, namespace: .item)
                if section == "action" {
                    let index = actionIndices[name, default: 0]
                    actionIndices[name] = index + 1
                    currentActionIndex = index
                    lines[.action(item: name, index: index)] = lineNumber
                } else {
                    currentActionIndex = nil
                }
                lines[.section(item: name, path: section)] = lineNumber
                continue
            }

            if let components = arrayHeaderComponents(in: line), let rootKey = components.first {
                lines[.rootField(rootKey)] = lines[.rootField(rootKey)] ?? lineNumber
                currentItem = nil
                currentSection = nil
                currentActionIndex = nil
                continue
            }

            if let components = headerComponents(in: line), components.count >= 2,
               components[0] == "item" || components[0] == "group" {
                let entryNamespace: ItemNamespace = components[0] == "item" ? .item : .group
                let name = components[1]
                currentItem = name
                currentSection = components.count == 2 ? nil : components.dropFirst(2).joined(separator: ".")
                currentActionIndex = nil
                try recordItemName(name, at: lineNumber, namespace: entryNamespace)
                if let currentSection {
                    lines[.section(item: name, path: currentSection)] = lineNumber
                }
                continue
            }

            if let components = headerComponents(in: line), let rootKey = components.first {
                lines[.rootField(rootKey)] = lines[.rootField(rootKey)] ?? lineNumber
                currentItem = nil
                currentSection = nil
                currentActionIndex = nil
                continue
            }

            guard let equals = assignmentSeparator(in: line) else { continue }
            let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
            let keyComponents = assignmentKeyComponents(String(rawKey))
            guard !keyComponents.isEmpty else { continue }
            if let currentItem, currentSection == "action", let currentActionIndex {
                for path in fieldPathPrefixes(keyComponents) {
                    let sourceKey = SourceLineKey.field(
                        item: currentItem,
                        path: path,
                        actionIndex: currentActionIndex
                    )
                    lines[sourceKey] = lines[sourceKey] ?? lineNumber
                }
            } else if let currentItem {
                let pathComponents = (currentSection?.split(separator: ".").map(String.init) ?? []) + keyComponents
                for path in fieldPathPrefixes(pathComponents) {
                    let sourceKey = SourceLineKey.field(item: currentItem, path: path, actionIndex: nil)
                    lines[sourceKey] = lines[sourceKey] ?? lineNumber
                }
            } else if keyComponents[0] == "item" || keyComponents[0] == "group" {
                let rootKey = keyComponents[0]
                let entryNamespace: ItemNamespace = rootKey == "item" ? .item : .group
                let rhs = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                let isInlineTable = rhs.hasPrefix("{")

                if keyComponents.count == 1 {
                    guard !isInlineTable else {
                        throw ConfigParseError(
                            message: "\(rootKey): inline table declarations are not supported; "
                                + "declare \(rootKey)s with [\(rootKey).<name>] tables or \(rootKey).<name>.<key> dotted keys",
                            line: lineNumber
                        )
                    }
                    for path in fieldPathPrefixes(keyComponents) {
                        lines[.rootField(path)] = lines[.rootField(path)] ?? lineNumber
                    }
                } else {
                    let name = keyComponents[1]
                    let fieldPath = Array(keyComponents.dropFirst(2))
                    guard !(fieldPath.isEmpty && isInlineTable) else {
                        throw ConfigParseError(
                            message: "\(rootKey).\(name): inline table declarations are not supported; "
                                + "declare this \(rootKey) with [\(rootKey).\(name)] instead",
                            line: lineNumber
                        )
                    }
                    try recordItemName(name, at: lineNumber, namespace: entryNamespace)
                    for path in fieldPathPrefixes(fieldPath) {
                        let sourceKey = SourceLineKey.field(item: name, path: path, actionIndex: nil)
                        lines[sourceKey] = lines[sourceKey] ?? lineNumber
                    }
                }
            } else {
                for path in fieldPathPrefixes(keyComponents) {
                    lines[.rootField(path)] = lines[.rootField(path)] ?? lineNumber
                }
            }
            multilineDelimiter = openMultilineDelimiter(in: String(line[line.index(after: equals)...]))
        }

        return (order, namespace, lines)
    }

    private static func fieldPathPrefixes(_ components: [String]) -> [String] {
        var prefixes: [String] = []
        var prefix = ""
        for component in components where !component.isEmpty {
            prefix = prefix.isEmpty ? component : "\(prefix).\(component)"
            prefixes.append(prefix)
        }
        return prefixes
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

    private static func sourceLine(
        item name: String,
        key: String,
        index: Int? = nil,
        sourceLines: SourceLineMap
    ) -> Int? {
        if let index {
            return sourceLines[.field(item: name, path: key, actionIndex: index)]
                ?? sourceLines[.field(item: name, path: "action", actionIndex: nil)]
                ?? sourceLines[.field(item: name, path: key, actionIndex: nil)]
                ?? sourceLines[.action(item: name, index: index)]
                ?? sourceLines[.section(item: name, path: "action")]
                ?? sourceLines[.item(name)]
        }
        return sourceLines[.field(item: name, path: key, actionIndex: nil)] ?? sourceLines[.item(name)]
    }

    private static func parseItem(
        name: String,
        table: TOMLTable,
        relativeTo configURL: URL?,
        sourceLines: SourceLineMap
    ) throws -> CommandItemConfig {
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
        } catch ByteCountParseError.tooLarge {
            throw ConfigParseError(
                message: "item.\(name): max_output '\(maxOutputString)' exceeds the \(maxAllowedOutputBytes / (1024 * 1024))MiB safe maximum per stream",
                line: sourceLine(item: name, key: "max_output", sourceLines: sourceLines)
            )
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

        let maxLength: Int?
        if let maxLengthValue = table["max_length"] {
            guard let value = maxLengthValue.int else {
                throw typeError(
                    path: "item.\(name).max_length",
                    expected: "integer",
                    value: maxLengthValue,
                    line: sourceLine(item: name, key: "max_length", sourceLines: sourceLines)
                )
            }
            guard value > 0 else {
                throw ConfigParseError(
                    message: "item.\(name).max_length must be a positive integer",
                    line: sourceLine(item: name, key: "max_length", sourceLines: sourceLines)
                )
            }
            maxLength = value
        } else {
            maxLength = nil
        }

        let hideWhenEmpty = try optionalBool(
            name: name,
            key: "hide_when_empty",
            table: table,
            sourceLines: sourceLines
        ) ?? false
        let hideOnError = try optionalBool(
            name: name,
            key: "hide_on_error",
            table: table,
            sourceLines: sourceLines
        ) ?? false
        let iconOnly = try optionalBool(
            name: name,
            key: "icon_only",
            table: table,
            sourceLines: sourceLines
        ) ?? false
        let disabled = try optionalBool(
            name: name,
            key: "disabled",
            table: table,
            sourceLines: sourceLines
        ) ?? false

        return CommandItemConfig(
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
            icon: icon,
            maxLength: maxLength,
            hideWhenEmpty: hideWhenEmpty,
            hideOnError: hideOnError,
            iconOnly: iconOnly,
            disabled: disabled
        )
    }

    /// Parses one `[group.<name>]` table. `members` existence, duplicate,
    /// and cycle validation happens once for the whole config after every
    /// item and group has been parsed (see `validateGroupMembership`), not
    /// here, since a member declared later in the file (or a forward
    /// reference to another group) is legal.
    private static func parseGroup(
        name: String,
        table: TOMLTable,
        relativeTo configURL: URL?,
        sourceLines: SourceLineMap
    ) throws -> GroupItemConfig {
        if table["symbol"] != nil {
            throw ConfigParseError(
                message: "group.\(name).symbol: SF Symbol groups are not supported yet (see issue #14); "
                    + "use icon with a local image file path instead",
                line: sourceLine(item: name, key: "symbol", sourceLines: sourceLines)
            )
        }
        try validateUnknownKeys(
            in: table,
            allowedKeys: supportedGroupKeys,
            context: "group.\(name)",
            lineForKey: { sourceLine(item: name, key: $0, sourceLines: sourceLines) }
        )

        let title = try requiredGroupString(name: name, key: "title", table: table, sourceLines: sourceLines)
        let members = try parseGroupMembers(name: name, value: table["members"], sourceLines: sourceLines)

        let icon: String?
        if let iconValue = table["icon"] {
            let rawIcon = try stringValue(
                path: "group.\(name).icon",
                value: iconValue,
                requireNonEmpty: false,
                line: sourceLine(item: name, key: "icon", sourceLines: sourceLines)
            )
            icon = resolvePath(rawIcon, relativeTo: configURL)
        } else {
            icon = nil
        }

        return GroupItemConfig(name: name, title: title, members: members, icon: icon)
    }

    private static func requiredGroupString(
        name: String,
        key: String,
        table: TOMLTable,
        sourceLines: SourceLineMap
    ) throws -> String {
        guard let value = table[key] else {
            throw ConfigParseError(
                message: "group.\(name): missing required field '\(key)'",
                line: sourceLine(item: name, key: key, sourceLines: sourceLines)
            )
        }
        return try stringValue(
            path: "group.\(name).\(key)",
            value: value,
            requireNonEmpty: true,
            line: sourceLine(item: name, key: key, sourceLines: sourceLines)
        )
    }

    private static func parseGroupMembers(
        name: String,
        value: TOMLValueConvertible?,
        sourceLines: SourceLineMap
    ) throws -> [String] {
        guard let value else {
            throw ConfigParseError(
                message: "group.\(name): missing required field 'members'",
                line: sourceLine(item: name, key: "members", sourceLines: sourceLines)
            )
        }
        guard let array = value.array else {
            throw typeError(
                path: "group.\(name).members",
                expected: "array",
                value: value,
                line: sourceLine(item: name, key: "members", sourceLines: sourceLines)
            )
        }
        guard !array.isEmpty else {
            throw ConfigParseError(
                message: "group.\(name).members must not be empty",
                line: sourceLine(item: name, key: "members", sourceLines: sourceLines)
            )
        }

        var members: [String] = []
        var seen = Set<String>()
        for (index, element) in array.enumerated() {
            let member = try stringValue(
                path: "group.\(name).members[\(index)]",
                value: element,
                requireNonEmpty: true,
                line: sourceLine(item: name, key: "members", sourceLines: sourceLines)
            )
            guard seen.insert(member).inserted else {
                throw ConfigParseError(
                    message: "group.\(name).members: duplicate member '\(member)'",
                    line: sourceLine(item: name, key: "members", sourceLines: sourceLines)
                )
            }
            members.append(member)
        }
        return members
    }

    /// Validates cross-item invariants that only make sense once every
    /// item and group in the file has been parsed: every group member
    /// name must resolve to some other declared entry, and following
    /// member references (through nested groups) must never cycle back to
    /// an entry already being visited. Command items have no outgoing
    /// membership edges, so they are always cycle-free leaves in this
    /// graph; only a chain of group memberships can cycle.
    private static func validateGroupMembership(_ items: [ItemConfig], sourceLines: SourceLineMap) throws {
        let groups = items.compactMap(\.groupConfig)
        guard !groups.isEmpty else { return }

        let allNames = Set(items.map(\.name))
        let groupsByName = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })

        for group in groups {
            for member in group.members where !allNames.contains(member) {
                throw ConfigParseError(
                    message: "group.\(group.name).members: unknown member '\(member)'",
                    line: sourceLine(item: group.name, key: "members", sourceLines: sourceLines)
                )
            }
        }

        enum VisitState {
            case visiting
            case done
        }
        var state: [String: VisitState] = [:]

        func visit(_ name: String, path: [String]) throws {
            if state[name] == .done { return }
            if state[name] == .visiting {
                let cycle = (path + [name]).joined(separator: " -> ")
                throw ConfigParseError(
                    message: "group membership cycle detected: \(cycle)",
                    line: sourceLine(item: name, key: "members", sourceLines: sourceLines)
                )
            }
            guard let group = groupsByName[name] else { return }
            state[name] = .visiting
            for member in group.members {
                try visit(member, path: path + [name])
            }
            state[name] = .done
        }

        for group in groups {
            try visit(group.name, path: [])
        }
    }

    private static func parseActions(
        name: String,
        value: TOMLValueConvertible?,
        sourceLines: SourceLineMap
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
        sourceLines: SourceLineMap
    ) throws -> [String] {
        guard let value else { return CommandItemConfig.defaultShell }
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
        sourceLines: SourceLineMap
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
        sourceLines: SourceLineMap
    ) throws -> [String: String] {
        guard let value else { return [:] }
        guard let table = value.table else {
            throw typeError(
                path: "item.\(name).env",
                expected: "table",
                value: value,
                line: sourceLines[.field(item: name, path: "env", actionIndex: nil)]
                    ?? sourceLines[.section(item: name, path: "env")]
                    ?? sourceLines[.item(name)]
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
        sourceLines: SourceLineMap,
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
        sourceLines: SourceLineMap,
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

    private static func optionalBool(
        name: String,
        key: String,
        table: TOMLTable,
        sourceLines: SourceLineMap
    ) throws -> Bool? {
        guard let value = table[key] else { return nil }
        guard let bool = value.bool else {
            throw typeError(
                path: "item.\(name).\(key)",
                expected: "boolean",
                value: value,
                line: sourceLine(item: name, key: key, sourceLines: sourceLines)
            )
        }
        return bool
    }

    private static func stringValue(
        name: String,
        key: String,
        value: TOMLValueConvertible,
        sourceLines: SourceLineMap,
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
