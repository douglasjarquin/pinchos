import Foundation

/// Fixed internal execution policy for every user command.
///
/// Finder/open (launchd) and Terminal inherit different process environments.
/// Pinchos does not promise those arbitrary environments are identical.
/// It does apply one PATH, HOME, working directory, and inherited-key set so
/// the same configured command resolves the same executable and working
/// directory in both launch contexts.
///
/// The shell is `/bin/sh -c` (non-login, non-interactive). Startup files are
/// not loaded. There are no public per-item shell, env, or cwd keys.
public struct CommandExecutionPolicy: Equatable, Sendable {
    public static let systemPathEntries = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    public static let appleSiliconHomebrewPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin"
    ]

    /// Homebrew first, then `/usr/local/bin`, then the launchd system directories.
    public static let pathEntries =
        appleSiliconHomebrewPathEntries + ["/usr/local/bin"] + systemPathEntries

    /// Host keys copied when present and non-empty. `PATH`, `SHELL`, `PWD`,
    /// `SSH_AUTH_SOCK`, and arbitrary secrets are not copied.
    public static let inheritedKeys = [
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TZ",
        "__CF_USER_TEXT_ENCODING"
    ]

    public let inheritedEnvironment: [String: String]

    public static var current: CommandExecutionPolicy {
        CommandExecutionPolicy(inheritedEnvironment: ProcessInfo.processInfo.environment)
    }

    public init(inheritedEnvironment: [String: String]) {
        self.inheritedEnvironment = inheritedEnvironment
    }

    public var path: String {
        Self.pathEntries.joined(separator: ":")
    }

    public var home: String {
        if let home = inheritedEnvironment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }

    public var workingDirectory: String {
        home
    }

    public func environment(overlay: [String: String] = [:]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in Self.inheritedKeys {
            if let value = inheritedEnvironment[key], !value.isEmpty {
                environment[key] = value
            }
        }
        environment["HOME"] = home
        if environment["USER"] == nil {
            let user = NSUserName()
            if !user.isEmpty {
                environment["USER"] = user
            }
        }
        if environment["LOGNAME"] == nil, let user = environment["USER"], !user.isEmpty {
            environment["LOGNAME"] = user
        }
        if environment["TMPDIR"] == nil {
            environment["TMPDIR"] = FileManager.default.temporaryDirectory.path
        }
        environment["PATH"] = path
        environment["SHELL"] = "/bin/sh"
        for (key, value) in overlay {
            environment[key] = value
        }
        return environment
    }

    public func resolveExecutable(_ command: String, fileManager: FileManager = .default) -> String? {
        if command.contains("/") {
            let path: String
            if command.hasPrefix("/") {
                path = command
            } else {
                path = URL(
                    fileURLWithPath: command,
                    relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
                ).standardizedFileURL.path
            }
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }

        for directory in Self.pathEntries {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(command).path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func missingCommandMessage(_ command: String) -> String {
        "command '\(command)' was not found on the execution PATH (Homebrew, /usr/local/bin, and system directories)"
    }

    /// Static inspection of a configured command or action. Never executes it.
    /// Compound shell expressions that cannot be inspected safely are
    /// `.unknown`, not `.missing`. Unterminated quotes or a trailing
    /// backslash are `.invalidSyntax` and count as a doctor problem.
    public enum StaticExecutableCheck: Equatable, Sendable {
        case found(path: String)
        case missing(command: String)
        case unknown
        case invalidSyntax
    }

    public static let unknownInspectionMessage =
        "compound shell expression; not statically inspected"

    public static let invalidSyntaxMessage =
        "unterminated quote or escape"

    public func inspectExecutable(
        _ expression: String,
        fileManager: FileManager = .default
    ) -> StaticExecutableCheck {
        switch commandName(from: expression) {
        case .invalidSyntax:
            return .invalidSyntax
        case .unknown:
            return .unknown
        case .word(let command, let quoted):
            if command.contains("`") || isUnsafeTildeWord(command, quoted: quoted) {
                return .unknown
            }
            let inspectTarget = expandUnquotedTilde(command, quoted: quoted)
            if let path = resolveExecutable(inspectTarget, fileManager: fileManager) {
                return .found(path: path)
            }
            return .missing(command: command)
        }
    }

    /// Unquoted `~` and `~/...` follow `/bin/sh` tilde expansion against HOME.
    /// Quoted tildes stay literal. `~user/...` is not expanded here.
    private func expandUnquotedTilde(_ command: String, quoted: Bool) -> String {
        guard !quoted else { return command }
        if command == "~" {
            return home
        }
        if command.hasPrefix("~/") {
            return home + String(command.dropFirst(1))
        }
        return command
    }

    private func isUnsafeTildeWord(_ command: String, quoted: Bool) -> Bool {
        guard !quoted, command.hasPrefix("~") else { return false }
        return command != "~" && !command.hasPrefix("~/")
    }
}

private struct CommandToken {
    var text: String
    var quoted: Bool
}

private enum CommandNameResult: Equatable {
    case word(String, quoted: Bool)
    case unknown
    case invalidSyntax
}

/// Words `/bin/sh` runs without a PATH lookup. Reporting them missing is wrong.
private let shellBuiltinsAndKeywords: Set<String> = [
    "!", "if", "for", "while", "until", "case", "function", "{", "}",
    "exec", "eval", ".", "source", "[[", "export", "set", "unset", "trap"
]

private func commandName(from run: String) -> CommandNameResult {
    var tokens = [CommandToken]()
    var token = ""
    var tokenQuoted = false
    var quote: Character?
    var escaped = false

    func appendToken() {
        guard !token.isEmpty || tokenQuoted else { return }
        tokens.append(CommandToken(text: token, quoted: tokenQuoted))
        token.removeAll(keepingCapacity: true)
        tokenQuoted = false
    }

    for character in run {
        if let activeQuote = quote {
            if activeQuote == "'" {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
            } else if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == activeQuote {
                quote = nil
            } else if character == "`" {
                return .unknown
            } else {
                token.append(character)
            }
            continue
        }

        if character == "'" || character == "\"" {
            if token.isEmpty {
                tokenQuoted = true
            }
            quote = character
        } else if character == "\\" {
            escaped = true
        } else if character.isWhitespace {
            appendToken()
        } else if ";|&()\n\r".contains(character) || character == "`" {
            return .unknown
        } else {
            token.append(character)
        }
    }

    if quote != nil || escaped {
        return .invalidSyntax
    }
    appendToken()

    var commandIndex = 0
    while commandIndex < tokens.count, isEnvironmentAssignment(tokens[commandIndex].text) {
        commandIndex += 1
    }
    if commandIndex < tokens.count, tokens[commandIndex].text == "env", !tokens[commandIndex].quoted {
        commandIndex += 1
        while commandIndex < tokens.count, isEnvironmentAssignment(tokens[commandIndex].text) {
            commandIndex += 1
        }
        if commandIndex < tokens.count, tokens[commandIndex].text == "--" {
            commandIndex += 1
        } else if commandIndex < tokens.count, tokens[commandIndex].text.hasPrefix("-") {
            return .unknown
        }
    }
    guard commandIndex < tokens.count else { return .unknown }

    let command = tokens[commandIndex]
    guard !command.text.isEmpty,
          !command.text.hasPrefix("$"),
          !command.text.contains("$("),
          !command.text.contains("`"),
          !shellBuiltinsAndKeywords.contains(command.text),
          !command.text.hasPrefix(">"),
          !command.text.hasPrefix("<") else { return .unknown }
    return .word(command.text, quoted: command.quoted)
}

private func isEnvironmentAssignment(_ token: String) -> Bool {
    let bytes = Array(token.utf8)
    guard let equals = bytes.firstIndex(of: 61), equals > 0 else { return false }
    let name = bytes[..<equals]
    guard let first = name.first,
          first == 95 || first >= 65 && first <= 90 || first >= 97 && first <= 122 else {
        return false
    }
    return name.dropFirst().allSatisfy { byte in
        byte == 95 || byte >= 48 && byte <= 57 || byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
    }
}
