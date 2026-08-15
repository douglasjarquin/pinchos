import Foundation
import TOMLKit

public enum ConfigParser {
    public static func parse(_ text: String) throws -> PinchosConfig {
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
            return try parseItem(name: name, table: itemTable)
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

    private static func parseItem(name: String, table: TOMLTable) throws -> ItemConfig {
        guard let type = table["type"]?.string else {
            throw ConfigParseError(message: "item.\(name): missing required field 'type'")
        }
        guard type == "command" else {
            throw ConfigParseError(message: "item.\(name): unsupported type '\(type)' (only 'command' is supported)")
        }
        guard let run = table["run"]?.string else {
            throw ConfigParseError(message: "item.\(name): missing required field 'run'")
        }

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

        return ItemConfig(
            name: name,
            run: run,
            interval: interval,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            format: table["format"]?.string,
            click: table["click"]?.string,
            errorText: table["error_text"]?.string ?? "\u{2013}",
            icon: table["icon"]?.string
        )
    }
}
