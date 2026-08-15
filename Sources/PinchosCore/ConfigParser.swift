import Foundation
import TOMLKit

public enum ConfigParser {
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
            guard let components = headerComponents(in: line), components.count >= 2,
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

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let delimiter = multilineDelimiter {
                if line.contains(delimiter) {
                    multilineDelimiter = nil
                }
                continue
            }

            if let components = headerComponents(in: line), components.count >= 2,
               components[0] == "item" {
                let name = components[1]
                currentItem = name
                currentSection = components.count == 2 ? nil : components.dropFirst(2).joined(separator: ".")
                lines[name] = lines[name] ?? lineNumber
                if let currentSection {
                    lines["\(name).\(currentSection)"] = lineNumber
                }
                continue
            }

            guard let currentItem, let equals = line.firstIndex(of: "=") else { continue }
            let rawKey = line[..<equals].trimmingCharacters(in: .whitespaces)
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !key.isEmpty else { continue }
            let path = [currentItem, currentSection, key]
                .compactMap { $0 }
                .joined(separator: ".")
            lines[path] = lineNumber
            multilineDelimiter = openMultilineDelimiter(in: String(line[line.index(after: equals)...]))
        }

        return lines
    }

    private static func headerComponents(in line: String) -> [String]? {
        guard line.first == "[", line.last == "]" else { return nil }

        var components = [String]()
        var component = ""
        var quote: Character?
        var escaped = false

        func appendComponent() {
            let value = component.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            components.append(value)
            component.removeAll(keepingCapacity: true)
        }

        for character in line.dropFirst().dropLast() {
            if let activeQuote = quote {
                if activeQuote == "\"", escaped {
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

    private static func openMultilineDelimiter(in value: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] {
            var count = 0
            var searchStart = value.startIndex
            while let range = value.range(of: delimiter, range: searchStart..<value.endIndex) {
                count += 1
                searchStart = range.upperBound
            }
            if count % 2 == 1 {
                return delimiter
            }
        }
        return nil
    }

    private static func sourceLine(
        item name: String,
        key: String,
        sourceLines: [String: Int]
    ) -> Int? {
        sourceLines["\(name).\(key)"] ?? sourceLines[name]
    }

    private static func parseItem(
        name: String,
        table: TOMLTable,
        relativeTo configURL: URL?,
        sourceLines: [String: Int]
    ) throws -> ItemConfig {
        guard let type = table["type"]?.string else {
            throw ConfigParseError(
                message: "item.\(name): missing required field 'type'",
                line: sourceLine(item: name, key: "type", sourceLines: sourceLines)
            )
        }
        guard type == "command" else {
            throw ConfigParseError(
                message: "item.\(name): unsupported type '\(type)' (only 'command' is supported)",
                line: sourceLine(item: name, key: "type", sourceLines: sourceLines)
            )
        }
        guard let run = table["run"]?.string else {
            throw ConfigParseError(
                message: "item.\(name): missing required field 'run'",
                line: sourceLine(item: name, key: "run", sourceLines: sourceLines)
            )
        }

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

        let intervalString = table["interval"]?.string ?? "60s"
        let interval: TimeInterval
        do {
            interval = try parseDuration(intervalString)
        } catch {
            throw ConfigParseError(
                message: "item.\(name): invalid interval '\(intervalString)'",
                line: sourceLine(item: name, key: "interval", sourceLines: sourceLines)
            )
        }

        let timeoutString: String
        if let timeoutValue = table["timeout"] {
            guard let value = timeoutValue.string else {
                throw ConfigParseError(
                    message: "item.\(name): invalid timeout value",
                    line: sourceLine(item: name, key: "timeout", sourceLines: sourceLines)
                )
            }
            timeoutString = value
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
            guard let value = maxOutputValue.string else {
                throw ConfigParseError(
                    message: "item.\(name): invalid max_output value",
                    line: sourceLine(item: name, key: "max_output", sourceLines: sourceLines)
                )
            }
            maxOutputString = value
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
            guard let rawIcon = iconValue.string else {
                throw ConfigParseError(
                    message: "item.\(name): invalid icon value",
                    line: sourceLine(item: name, key: "icon", sourceLines: sourceLines)
                )
            }
            icon = resolvePath(rawIcon, relativeTo: configURL)
        } else {
            icon = nil
        }

        return ItemConfig(
            name: name,
            run: run,
            interval: interval,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            shell: shell,
            workingDirectory: workingDirectory,
            environment: environment,
            format: table["format"]?.string,
            click: table["click"]?.string,
            errorText: table["error_text"]?.string ?? "\u{2013}",
            icon: icon
        )
    }

    private static func parseShell(
        name: String,
        value: TOMLValueConvertible?,
        relativeTo configURL: URL?,
        sourceLines: [String: Int]
    ) throws -> [String] {
        guard let value else { return ItemConfig.defaultShell }
        guard let array = value.array else {
            throw ConfigParseError(
                message: "item.\(name): shell must be an array of strings",
                line: sourceLine(item: name, key: "shell", sourceLines: sourceLines)
            )
        }

        var shell = [String]()
        for (index, element) in array.enumerated() {
            guard let argument = element.string, !argument.isEmpty else {
                throw ConfigParseError(
                    message: "item.\(name): shell[\(index)] must be a non-empty string",
                    line: sourceLine(item: name, key: "shell", sourceLines: sourceLines)
                )
            }
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
            throw ConfigParseError(
                message: "item.\(name): working_directory must be a string",
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
            throw ConfigParseError(
                message: "item.\(name).env must be a table of strings",
                line: sourceLines["\(name).env"] ?? sourceLines[name]
            )
        }

        var environment = [String: String]()
        for (key, value) in table {
            guard isValidEnvironmentName(key) else {
                throw ConfigParseError(
                    message: "item.\(name).env.\(key) is not a valid environment name",
                    line: sourceLine(item: name, key: "env.\(key)", sourceLines: sourceLines)
                )
            }
            guard let string = value.string, !string.unicodeScalars.contains(where: { $0.value == 0 }) else {
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

    private static func resolvePath(_ rawPath: String, relativeTo configURL: URL?) -> String {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        guard let configURL else { return expandedPath }
        return URL(fileURLWithPath: expandedPath, relativeTo: configURL.deletingLastPathComponent())
            .standardizedFileURL
            .path
    }
}
