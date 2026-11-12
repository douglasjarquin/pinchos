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

    /// Homebrew first, matching `brew shellenv` on Apple Silicon, then the
    /// launchd system directories.
    public static let pathEntries = appleSiliconHomebrewPathEntries + systemPathEntries

    /// Host keys copied when present and non-empty. `PATH`, `SHELL`, `PWD`,
    /// and arbitrary secrets are not copied.
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
        if environment["HOME"] == nil {
            let home = NSHomeDirectory()
            if !home.isEmpty {
                environment["HOME"] = home
            }
        }
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
                path = URL(fileURLWithPath: command, relativeTo: URL(fileURLWithPath: workingDirectory))
                    .standardizedFileURL.path
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
        "command '\(command)' was not found on the execution PATH (system plus Apple Silicon Homebrew)"
    }
}
