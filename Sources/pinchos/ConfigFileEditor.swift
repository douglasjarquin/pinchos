import Foundation
import PinchosCore

enum ConfigFileEditError: LocalizedError {
    case invalidUTF8(path: String)
    case itemNotFound(namespace: String, name: String)
    case sourceChanged(path: String)
    case unableToRead(path: String, reason: String)
    case unableToWrite(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8(let path):
            return "The config at \(path) is not valid UTF-8."
        case .itemNotFound(let namespace, let name):
            return "Unable to find [\(namespace).\(name)] in the config."
        case .sourceChanged(let path):
            return "The config at \(path) changed while it was being updated. Reload the config and try again."
        case .unableToRead(let path, let reason):
            return "Unable to read the config at \(path): \(reason)"
        case .unableToWrite(let path, let reason):
            return "Unable to update the config at \(path): \(reason)"
        }
    }
}

enum ConfigFileEditor {
    static func setHidden(_ hidden: Bool, for item: ItemConfig, at url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var editError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            do {
                try performSetHidden(hidden, for: item, at: coordinatedURL)
            } catch {
                editError = error
            }
        }
        if let editError { throw editError }
        if let coordinationError {
            throw ConfigFileEditError.unableToWrite(path: url.path, reason: coordinationError.localizedDescription)
        }
    }

    private static func performSetHidden(_ hidden: Bool, for item: ItemConfig, at url: URL) throws {
        let originalData: Data
        let source: String
        do {
            originalData = try Data(contentsOf: url)
            guard let decoded = String(data: originalData, encoding: .utf8) else {
                throw ConfigFileEditError.invalidUTF8(path: url.path)
            }
            source = decoded
        } catch let error as ConfigFileEditError {
            throw error
        } catch {
            throw ConfigFileEditError.unableToRead(path: url.path, reason: String(describing: error))
        }

        let namespace: String
        switch item {
        case .command:
            namespace = "item"
        case .group:
            namespace = "group"
        }

        let updated = try update(
            source: source,
            namespace: namespace,
            name: item.name,
            hidden: hidden
        )
        guard updated != source else { return }

        try replaceIfUnchanged(
            originalData: originalData,
            updatedData: Data(updated.utf8),
            at: url
        )
    }

    static func replaceIfUnchanged(originalData: Data, updatedData: Data, at url: URL) throws {
        let currentData: Data
        do {
            currentData = try Data(contentsOf: url)
        } catch {
            throw ConfigFileEditError.unableToRead(path: url.path, reason: String(describing: error))
        }
        guard currentData == originalData else {
            throw ConfigFileEditError.sourceChanged(path: url.path)
        }

        do {
            try updatedData.write(to: url, options: [.atomic])
        } catch {
            throw ConfigFileEditError.unableToWrite(path: url.path, reason: String(describing: error))
        }
    }

    private static func update(
        source: String,
        namespace: String,
        name: String,
        hidden: Bool
    ) throws -> String {
        let lineBreak = source.contains("\r\n") ? "\r\n" : "\n"
        var lines = source.components(separatedBy: lineBreak)
        let target = [namespace, name]
        let value = hidden ? "true" : "false"

        var currentHeader: [String]?
        var multilineDelimiter: String?
        var tableHeaderIndex: Int?
        var existingHiddenIndex: Int?
        var firstHeaderIndex: Int?
        var dottedFieldIndexes: [Int] = []
        var dottedHiddenIndex: Int?

        for index in lines.indices {
            let line = lines[index]
            if let delimiter = multilineDelimiter {
                if unescapedDelimiterCount(delimiter, in: line) % 2 == 1 {
                    multilineDelimiter = nil
                }
                continue
            }

            if let header = headerComponents(in: line) {
                currentHeader = header
                firstHeaderIndex = firstHeaderIndex ?? index
                if header == target, tableHeaderIndex == nil {
                    tableHeaderIndex = index
                }
            } else if currentHeader == target,
                      existingHiddenIndex == nil,
                      assignmentKeyComponents(in: line) == ["hidden"] {
                existingHiddenIndex = index
            } else if firstHeaderIndex == nil,
                      let assignment = assignmentKeyComponents(in: line),
                      assignment.count > target.count,
                      Array(assignment.prefix(target.count)) == target {
                dottedFieldIndexes.append(index)
                if assignment == target + ["hidden"], dottedHiddenIndex == nil {
                    dottedHiddenIndex = index
                }
            }

            if let delimiter = openMultilineDelimiter(in: line) {
                multilineDelimiter = delimiter
            }
        }

        if let tableHeaderIndex {
            if let existingHiddenIndex {
                lines[existingHiddenIndex] = replacedAssignmentLine(
                    lines[existingHiddenIndex],
                    value: value
                )
            } else {
                lines.insert("hidden = \(value)", at: tableHeaderIndex + 1)
            }
            return lines.joined(separator: lineBreak)
        }

        if let dottedHiddenIndex {
            lines[dottedHiddenIndex] = replacedAssignmentLine(lines[dottedHiddenIndex], value: value)
            return lines.joined(separator: lineBreak)
        }

        if let lastDottedFieldIndex = dottedFieldIndexes.last {
            lines.insert(
                "\(namespace).\(tomlKey(name)).hidden = \(value)",
                at: lastDottedFieldIndex + 1
            )
            return lines.joined(separator: lineBreak)
        }

        throw ConfigFileEditError.itemNotFound(namespace: namespace, name: name)
    }

    private static func replacedAssignmentLine(_ line: String, value: String) -> String {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let comment = inlineComment(in: line).map { " \($0)" } ?? ""
        return "\(indentation)hidden = \(value)\(comment)"
    }

    private static func tomlKey(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let isBare = !bytes.isEmpty
            && bytes.allSatisfy { byte in
                byte == 95
                    || byte >= 48 && byte <= 57
                    || byte >= 65 && byte <= 90
                    || byte >= 97 && byte <= 122
            }
        guard !isBare else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func headerComponents(in line: String) -> [String]? {
        let code = lineWithoutComment(line).trimmingCharacters(in: .whitespaces)
        guard code.first == "[", code.last == "]", !code.hasPrefix("[["), !code.hasSuffix("]]"),
              code.count >= 2 else {
            return nil
        }
        let start = code.index(after: code.startIndex)
        let end = code.index(before: code.endIndex)
        return keyComponents(String(code[start..<end]))
    }

    private static func assignmentKeyComponents(in line: String) -> [String]? {
        let code = lineWithoutComment(line)
        guard let separator = assignmentSeparator(in: code) else { return nil }
        let rawKey = String(code[..<separator]).trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty else { return nil }
        return keyComponents(rawKey)
    }

    private static func keyComponents(_ raw: String) -> [String]? {
        var components: [String] = []
        var component = ""
        var quote: Character?
        var escaped = false
        var basicQuoted = false

        func appendComponent() {
            let value = component.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            components.append(basicQuoted ? decodeBasicKey(value) : value)
            component.removeAll(keepingCapacity: true)
            basicQuoted = false
        }

        for character in raw {
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
                basicQuoted = character == "\""
            } else if character == "." {
                appendComponent()
            } else {
                component.append(character)
            }
        }

        guard quote == nil, !escaped else { return nil }
        appendComponent()
        return components.isEmpty ? nil : components
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

    private static func lineWithoutComment(_ line: String) -> String {
        guard let index = commentIndex(in: line) else { return line }
        return String(line[..<index])
    }

    private static func inlineComment(in line: String) -> String? {
        guard let index = commentIndex(in: line) else { return nil }
        return String(line[index...]).trimmingCharacters(in: .whitespaces)
    }

    private static func commentIndex(in line: String) -> String.Index? {
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
                return index
            }
        }
        return nil
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
            }
        }
        return nil
    }

    private static func openMultilineDelimiter(in line: String) -> String? {
        let code = lineWithoutComment(line)
        for delimiter in ["\"\"\"", "'''"] {
            if unescapedDelimiterCount(delimiter, in: code) % 2 == 1 {
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
}
