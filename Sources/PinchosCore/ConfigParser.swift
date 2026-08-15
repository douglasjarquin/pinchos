import Foundation
import TOMLKit

public enum ConfigParser {
    public static func parse(_ text: String, relativeTo configURL: URL? = nil) throws -> PinchosConfig {
        let order = declaredItemOrder(in: text)

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
            return try parseItem(name: name, table: itemTable, relativeTo: configURL)
        }
        return PinchosConfig(items: items)
    }

    private static func declaredItemOrder(in text: String) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[item."), line.hasSuffix("]") else { continue }
            let inner = line.dropFirst("[item.".count).dropLast()
            let name = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            order.append(name)
        }
        return order
    }

    private static func parseItem(name: String, table: TOMLTable, relativeTo configURL: URL?) throws -> ItemConfig {
        guard let type = table["type"]?.string else {
            throw ConfigParseError(message: "item.\(name): missing required field 'type'")
        }
        guard type == "command" else {
            throw ConfigParseError(message: "item.\(name): unsupported type '\(type)' (only 'command' is supported)")
        }
        guard let run = table["run"]?.string else {
            throw ConfigParseError(message: "item.\(name): missing required field 'run'")
        }

        let shell = try parseShell(name: name, value: table["shell"], relativeTo: configURL)
        let workingDirectory = try parseWorkingDirectory(name: name, value: table["working_directory"], relativeTo: configURL)
        let environment = try parseEnvironment(name: name, value: table["env"])

        let intervalString = table["interval"]?.string ?? "60s"
        let interval: TimeInterval
        do {
            interval = try parseDuration(intervalString)
        } catch {
            throw ConfigParseError(message: "item.\(name): invalid interval '\(intervalString)'")
        }

        let timeoutString: String
        if let timeoutValue = table["timeout"] {
            guard let value = timeoutValue.string else {
                throw ConfigParseError(message: "item.\(name): invalid timeout value")
            }
            timeoutString = value
        } else {
            timeoutString = "15s"
        }
        let timeout: TimeInterval
        do {
            timeout = try parseDuration(timeoutString)
        } catch {
            throw ConfigParseError(message: "item.\(name): invalid timeout '\(timeoutString)'")
        }

        let maxOutputString: String
        if let maxOutputValue = table["max_output"] {
            guard let value = maxOutputValue.string else {
                throw ConfigParseError(message: "item.\(name): invalid max_output value")
            }
            maxOutputString = value
        } else {
            maxOutputString = "64KiB"
        }
        let maxOutputBytes: Int
        do {
            maxOutputBytes = try parseByteCount(maxOutputString)
        } catch {
            throw ConfigParseError(message: "item.\(name): invalid max_output '\(maxOutputString)'")
        }

        let icon: String?
        if let iconValue = table["icon"] {
            guard let rawIcon = iconValue.string else {
                throw ConfigParseError(message: "item.\(name): invalid icon value")
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

    private static func parseShell(name: String, value: TOMLValueConvertible?, relativeTo configURL: URL?) throws -> [String] {
        guard let value else { return ItemConfig.defaultShell }
        guard let array = value.array else {
            throw ConfigParseError(message: "item.\(name): shell must be an array of strings")
        }

        var shell = [String]()
        for (index, element) in array.enumerated() {
            guard let argument = element.string, !argument.isEmpty else {
                throw ConfigParseError(message: "item.\(name): shell[\(index)] must be a non-empty string")
            }
            shell.append(argument)
        }
        guard let executable = shell.first else {
            throw ConfigParseError(message: "item.\(name): shell must include an executable")
        }

        shell[0] = resolvePath(executable, relativeTo: configURL)
        guard FileManager.default.isExecutableFile(atPath: shell[0]) else {
            throw ConfigParseError(message: "item.\(name): shell executable cannot be resolved: \(shell[0])")
        }
        return shell
    }

    private static func parseWorkingDirectory(
        name: String,
        value: TOMLValueConvertible?,
        relativeTo configURL: URL?
    ) throws -> String? {
        guard let value else { return nil }
        guard let rawPath = value.string else {
            throw ConfigParseError(message: "item.\(name): working_directory must be a string")
        }

        let path = resolvePath(rawPath, relativeTo: configURL)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigParseError(message: "item.\(name): working_directory cannot be resolved: \(path)")
        }
        return path
    }

    private static func parseEnvironment(name: String, value: TOMLValueConvertible?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let table = value.table else {
            throw ConfigParseError(message: "item.\(name).env must be a table of strings")
        }

        var environment = [String: String]()
        for (key, value) in table {
            guard isValidEnvironmentName(key) else {
                throw ConfigParseError(message: "item.\(name).env.\(key) is not a valid environment name")
            }
            guard let string = value.string, !string.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ConfigParseError(message: "item.\(name).env.\(key) must be a string without NUL bytes")
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
