import Foundation

public enum StructuredOutputState: String, Equatable, Sendable {
    case normal
    case warning
    case error

    var runtimeStatus: ItemRuntimeStatus {
        switch self {
        case .normal: return .fresh
        case .warning: return .warning
        case .error: return .error
        }
    }
}

public struct StructuredCommandOutput: Equatable, Sendable {
    public let text: String?
    public let tooltip: String?
    public let state: StructuredOutputState?
    public let hidden: Bool?
    public let iconSource: ItemIconSource?
    public let actions: [ItemAction]?

    public init(
        text: String? = nil,
        tooltip: String? = nil,
        state: StructuredOutputState? = nil,
        hidden: Bool? = nil,
        iconSource: ItemIconSource? = nil,
        actions: [ItemAction]? = nil
    ) {
        self.text = text
        self.tooltip = tooltip
        self.state = state
        self.hidden = hidden
        self.iconSource = iconSource
        self.actions = actions
    }
}

public enum StructuredOutputParseError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidJSON
    case missingVersion
    case unsupportedVersion(Int)
    case invalidField(String, String)
    case conflictingIconSources
    case invalidAction(index: Int, reason: String)

    public var description: String {
        switch self {
        case .invalidJSON:
            return "structured output is not valid JSON"
        case .missingVersion:
            return "structured output is missing required integer 'version'"
        case .unsupportedVersion(let version):
            return "structured output version \(version) is unsupported (expected 1)"
        case .invalidField(let field, let expected):
            return "structured output field '\(field)' must be \(expected)"
        case .conflictingIconSources:
            return "structured output cannot set both 'icon' and 'symbol'"
        case .invalidAction(let index, let reason):
            return "structured output action[\(index)]: \(reason)"
        }
    }
}

public enum StructuredOutputParser {
    public static func parse(_ text: String) throws -> StructuredCommandOutput {
        guard let data = text.data(using: .utf8) else {
            throw StructuredOutputParseError.invalidJSON
        }

        do {
            let decoder = JSONDecoder()
            let payload = try decoder.decode(Payload.self, from: data)
            guard let version = payload.version else {
                throw StructuredOutputParseError.missingVersion
            }
            guard version == 1 else {
                throw StructuredOutputParseError.unsupportedVersion(version)
            }
            return try payload.output()
        } catch let error as StructuredOutputParseError {
            throw error
        } catch {
            throw StructuredOutputParseError.invalidJSON
        }
    }

    private struct Payload: Decodable {
        let version: Int?
        let text: String?
        let tooltip: String?
        let state: String?
        let hidden: Bool?
        let icon: String?
        let symbol: String?
        let actions: [ActionPayload]?

        private enum CodingKeys: String, CodingKey {
            case version, text, tooltip, state, hidden, icon, symbol, actions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try Self.decodeOptional(container, key: .version, field: "version")
            text = try Self.decodeOptional(container, key: .text, field: "text")
            tooltip = try Self.decodeOptional(container, key: .tooltip, field: "tooltip")
            state = try Self.decodeOptional(container, key: .state, field: "state")
            hidden = try Self.decodeOptional(container, key: .hidden, field: "hidden")
            icon = try Self.decodeOptional(container, key: .icon, field: "icon")
            symbol = try Self.decodeOptional(container, key: .symbol, field: "symbol")
            if container.contains(.actions) {
                do {
                    actions = try container.decode([ActionPayload].self, forKey: .actions)
                } catch {
                    throw StructuredOutputParseError.invalidField("actions", "an array")
                }
            } else {
                actions = nil
            }
        }

        func output() throws -> StructuredCommandOutput {
            let parsedState: StructuredOutputState?
            if let state {
                guard let value = StructuredOutputState(rawValue: state) else {
                    throw StructuredOutputParseError.invalidField("state", "'normal', 'warning', or 'error'")
                }
                parsedState = value
            } else {
                parsedState = nil
            }

            if icon != nil, symbol != nil {
                throw StructuredOutputParseError.conflictingIconSources
            }
            let iconSource: ItemIconSource?
            if let icon {
                guard !icon.isEmpty else {
                    throw StructuredOutputParseError.invalidField("icon", "a non-empty string")
                }
                iconSource = .file(icon)
            } else if let symbol {
                guard !symbol.isEmpty else {
                    throw StructuredOutputParseError.invalidField("symbol", "a non-empty string")
                }
                iconSource = .symbol(symbol)
            } else {
                iconSource = nil
            }

            return StructuredCommandOutput(
                text: text,
                tooltip: tooltip,
                state: parsedState,
                hidden: hidden,
                iconSource: iconSource,
                actions: try actions?.enumerated().map { index, action in
                    try action.itemAction(index: index)
                }
            )
        }

        private static func decodeOptional<T: Decodable>(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys,
            field: String
        ) throws -> T? {
            guard container.contains(key) else { return nil }
            do {
                return try container.decode(T.self, forKey: key)
            } catch {
                throw StructuredOutputParseError.invalidField(field, "a \(T.self)")
            }
        }
    }

    private struct ActionPayload: Decodable {
        let title: String?
        let run: String?
        let refresh: Bool?

        private enum CodingKeys: String, CodingKey { case title, run, refresh }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if !container.contains(.title) {
                title = nil
            } else {
                do {
                    title = try container.decode(String.self, forKey: .title)
                } catch {
                    throw StructuredOutputParseError.invalidField("action.title", "a string")
                }
            }
            do {
                run = try container.decodeIfPresent(String.self, forKey: .run)
            } catch {
                throw StructuredOutputParseError.invalidField("action.run", "a string")
            }
            do {
                refresh = try container.decodeIfPresent(Bool.self, forKey: .refresh)
            } catch {
                throw StructuredOutputParseError.invalidField("action.refresh", "a boolean")
            }
        }

        func itemAction(index: Int) throws -> ItemAction {
            guard let title, !title.isEmpty else {
                throw StructuredOutputParseError.invalidAction(index: index, reason: "'title' is required")
            }
            if run != nil, refresh != nil {
                throw StructuredOutputParseError.invalidAction(index: index, reason: "specify either 'run' or 'refresh', not both")
            }
            if let run {
                guard !run.isEmpty else {
                    throw StructuredOutputParseError.invalidAction(index: index, reason: "'run' must be non-empty")
                }
                return ItemAction(title: title, kind: .command(run))
            }
            guard refresh == true else {
                throw StructuredOutputParseError.invalidAction(index: index, reason: "specify 'run' or 'refresh': true")
            }
            return ItemAction(title: title, kind: .refresh)
        }
    }
}
