import AppKit
import Foundation
import PinchosCore

struct CLIOutput {
    let stdout: (String) -> Void
    let stderr: (String) -> Void

    init(
        stdout: @escaping (String) -> Void = { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        },
        stderr: @escaping (String) -> Void = { text in
            FileHandle.standardError.write(Data(text.utf8))
        }
    ) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

@MainActor
final class CLICommandRunnerRegistry {
    private var runners: [ObjectIdentifier: CommandRunner] = [:]
    private var shutdownRequested = false

    func register(_ runner: CommandRunner) -> Bool {
        guard !shutdownRequested else { return false }
        runners[ObjectIdentifier(runner)] = runner
        return true
    }

    func unregister(_ runner: CommandRunner) {
        runners.removeValue(forKey: ObjectIdentifier(runner))
    }

    func cancelAll() async {
        shutdownRequested = true
        let runners = Array(runners.values)
        for runner in runners {
            await runner.cancelForShutdown()
        }
    }
}

private enum CLIExitCode {
    static let notEnabled: Int32 = 1
    static let usage: Int32 = 2
    static let config: Int32 = 3
    static let diagnostics: Int32 = 4
    static let execution: Int32 = 125
    static let timeout: Int32 = 124
    static let launchFailure: Int32 = 127
}

private enum CLIError: Error {
    case usage(String)
    case config(String)
    case open(String)

    var exitCode: Int32 {
        switch self {
        case .usage:
            return CLIExitCode.usage
        case .config, .open:
            return CLIExitCode.config
        }
    }

    var message: String {
        switch self {
        case .usage(let message), .config(let message), .open(let message):
            return message
        }
    }
}

@MainActor
struct PinchosCLI {
    private let configPath: String
    private let fileManager: FileManager
    private let output: CLIOutput
    private let opener: (URL) -> Bool
    private let shutdownCoordinator: ShutdownCoordinator?
    private let runnerRegistry: CLICommandRunnerRegistry

    init(
        configPath: String = ConfigLocation.resolve(),
        fileManager: FileManager = .default,
        output: CLIOutput = CLIOutput(),
        opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        shutdownCoordinator: ShutdownCoordinator? = nil,
        runnerRegistry: CLICommandRunnerRegistry? = nil
    ) {
        self.configPath = configPath
        self.fileManager = fileManager
        self.output = output
        self.opener = opener
        self.shutdownCoordinator = shutdownCoordinator
        self.runnerRegistry = runnerRegistry ?? CLICommandRunnerRegistry()
    }

    func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            printGeneralHelp()
            return CLIExitCode.usage
        }

        if command == "--help" || command == "-h" || command == "help" {
            printGeneralHelp()
            return 0
        }

        do {
            switch command {
            case "init":
                return try runInit(arguments: Array(arguments.dropFirst()))
            case "validate":
                return try runValidate(arguments: Array(arguments.dropFirst()))
            case "doctor":
                return try await runDoctor(arguments: Array(arguments.dropFirst()))
            case "config-path":
                return try runConfigPath(arguments: Array(arguments.dropFirst()))
            case "open-config":
                return try runOpenConfig(arguments: Array(arguments.dropFirst()))
            case "run":
                return try await runItem(arguments: Array(arguments.dropFirst()))
            default:
                throw CLIError.usage("unknown command '\(command)'\nTry 'pinchos --help' for usage.")
            }
        } catch let error as CLIError {
            output.stderr("pinchos: \(error.message)\n")
            return error.exitCode
        } catch {
            output.stderr("pinchos: \(error)\n")
            return CLIExitCode.config
        }
    }

    private func runInit(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printInitHelp()
            return 0
        }
        guard arguments.isEmpty else {
            throw CLIError.usage("usage: pinchos init [--help]")
        }

        let url = configURL
        try ensureConfigDirectory()
        try ensureConfigPathIsFile()
        if fileManager.fileExists(atPath: url.path) {
            output.stdout("Config already exists: \(url.path)\n")
            return 0
        }

        do {
            try Data(ExampleConfig.text.utf8).write(to: url, options: [.withoutOverwriting])
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                output.stdout("Config already exists: \(url.path)\n")
                return 0
            }
            throw CLIError.config("unable to create config at \(url.path): \(error)")
        }
        output.stdout("Created example config: \(url.path)\n")
        return 0
    }

    private func runValidate(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printValidateHelp()
            return 0
        }
        guard arguments.isEmpty else {
            throw CLIError.usage("usage: pinchos validate [--help]")
        }

        let config = try loadConfig()
        guard !config.items.isEmpty else {
            throw CLIError.config("config contains no items: \(configPath)")
        }
        output.stdout("Valid config: \(configPath) (\(config.items.count) item\(config.items.count == 1 ? "" : "s"))\n")
        return 0
    }

    private func runConfigPath(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printConfigPathHelp()
            return 0
        }
        guard arguments.isEmpty else {
            throw CLIError.usage("usage: pinchos config-path [--help]")
        }
        output.stdout("\(configPath)\n")
        return 0
    }

    private func runOpenConfig(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printOpenConfigHelp()
            return 0
        }
        guard arguments.isEmpty else {
            throw CLIError.usage("usage: pinchos open-config [--help]")
        }

        let url = configURL
        try ensureConfigDirectory()
        try ensureConfigPathIsFile()
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try Data().write(to: url, options: [.withoutOverwriting])
            } catch {
                if !fileManager.fileExists(atPath: url.path) {
                    throw CLIError.open("unable to create config at \(url.path): \(error)")
                }
            }
        }
        guard opener(url) else {
            throw CLIError.open("unable to open config with the default application: \(url.path)")
        }
        output.stdout("Opened config: \(url.path)\n")
        return 0
    }

    private func runItem(arguments: [String]) async throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printRunHelp()
            return 0
        }
        guard arguments.count == 1, let name = arguments.first, !name.isEmpty else {
            throw CLIError.usage("usage: pinchos run <item> [--help]")
        }

        let config = try loadConfig()
        guard let matchedItem = config.items.first(where: { $0.name == name }) else {
            throw CLIError.config("item '\(name)' is not configured in \(configPath)")
        }
        let item = matchedItem

        guard shutdownCoordinator?.isShutdownRequested != true else {
            return shutdownCoordinator?.terminationExitCode ?? CLIExitCode.execution
        }

        let runner = CommandRunner(
            command: item.run,
            timeout: item.timeout,
            maxOutputBytes: item.maxOutputBytes,
            shell: item.shell,
            workingDirectory: item.workingDirectory,
            environment: item.environment
        )
        guard runnerRegistry.register(runner) else {
            return shutdownCoordinator?.terminationExitCode ?? CLIExitCode.execution
        }
        defer { runnerRegistry.unregister(runner) }
        let outcome = await runner.runIfIdle()
        guard case .completed = outcome else {
            if let terminationExitCode = shutdownCoordinator?.terminationExitCode {
                return terminationExitCode
            }
            output.stderr("pinchos run \(name): command was skipped because another execution is active\n")
            return CLIExitCode.execution
        }
        // The shell may exit while same-group descendants and output pipes are
        // still settling; wait for the definitive session result (bounded by
        // the item's configured timeout or a shutdown signal, which cancels
        // this registered runner via `runnerRegistry`) instead of treating the
        // shell's exit as final and force-killing a still-legitimate child.
        let settledExecution = await runner.awaitSettledExecution()
        if let terminationExitCode = shutdownCoordinator?.terminationExitCode {
            return terminationExitCode
        }
        guard let execution = settledExecution else {
            output.stderr("pinchos run \(name): command was skipped because another execution is active\n")
            return CLIExitCode.execution
        }

        if !execution.stdout.isEmpty {
            output.stdout(execution.stdout)
        }
        if !execution.stderr.isEmpty {
            output.stderr(execution.stderr)
        }

        switch execution.terminalReason {
        case .exited(let code):
            if code != 0 {
                output.stderr("pinchos run \(name): exited with code \(code)\n")
            }
            return normalizedExitCode(code)
        case .signaled(let signal):
            output.stderr("pinchos run \(name): terminated by signal \(signal)\n")
            return min(255, 128 + signal)
        case .timedOut:
            output.stderr("pinchos run \(name): timed out after \(item.timeout)s\n")
            return CLIExitCode.timeout
        case .cancelled:
            output.stderr("pinchos run \(name): cancelled\n")
            return CLIExitCode.execution
        case .launchFailed(let message):
            output.stderr("pinchos run \(name): launch failed: \(message)\n")
            return CLIExitCode.launchFailure
        }
    }

    private func runDoctor(arguments: [String]) async throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printDoctorHelp()
            return 0
        }
        guard arguments.isEmpty else {
            throw CLIError.usage("usage: pinchos doctor [--help]")
        }

        var problemCount = 0
        output.stdout("Pinchos doctor\n")
        output.stdout("Config path: \(configPath)\n")

        var config: PinchosConfig?
        var isDirectory = ObjCBool(false)
        if !fileManager.fileExists(atPath: configPath, isDirectory: &isDirectory) {
            reportFailure("config", "missing; run 'pinchos init'")
            problemCount += 1
        } else if isDirectory.boolValue {
            reportFailure("config", "path is a directory")
            problemCount += 1
        } else if !fileManager.isReadableFile(atPath: configPath) {
            reportFailure("config", "file is not readable")
            problemCount += 1
        } else {
            do {
                config = try loadConfig()
                reportSuccess("config", "readable and parsed")
            } catch let error as CLIError {
                reportFailure("config", error.message)
                problemCount += 1
            } catch {
                reportFailure("config", String(describing: error))
                problemCount += 1
            }
        }

        let processEnvironment = ProcessInfo.processInfo.environment
        if let path = processEnvironment["PATH"], !path.isEmpty {
            reportSuccess("execution environment", "PATH is available")
        } else {
            reportFailure("execution environment", "PATH is missing or empty")
            problemCount += 1
        }
        if let home = processEnvironment["HOME"], !home.isEmpty {
            reportSuccess("execution environment", "HOME is available")
        } else {
            reportFailure("execution environment", "HOME is missing or empty")
            problemCount += 1
        }

        if let config {
            if config.items.isEmpty {
                reportFailure("config", "contains no items")
                problemCount += 1
            }
            for entry in config.items {
                let item = entry
                    if fileManager.isExecutableFile(atPath: item.shell[0]) {
                        reportSuccess("item.\(item.name).shell", item.shell[0])
                    } else {
                        reportFailure("item.\(item.name).shell", "executable cannot be resolved: \(item.shell[0])")
                        problemCount += 1
                    }

                    if let workingDirectory = item.workingDirectory {
                        var itemIsDirectory = ObjCBool(false)
                        if fileManager.fileExists(atPath: workingDirectory, isDirectory: &itemIsDirectory), itemIsDirectory.boolValue {
                            reportSuccess("item.\(item.name).working_directory", workingDirectory)
                        } else {
                            reportFailure("item.\(item.name).working_directory", "directory cannot be resolved: \(workingDirectory)")
                            problemCount += 1
                        }
                    } else {
                        reportSuccess("item.\(item.name).working_directory", "inherits Pinchos working directory")
                    }

                    problemCount += reportIconSource(
                        path: "item.\(item.name)",
                        source: item.iconSource,
                        reportAbsentAsIconNotConfigured: true
                    )

                    if item.environment.isEmpty {
                        reportSuccess("item.\(item.name).env", "inherits process environment")
                    } else {
                        reportSuccess("item.\(item.name).env", "\(item.environment.count) configured variable\(item.environment.count == 1 ? "" : "s")")
                    }

                    if let command = commandName(from: item.run) {
                        if let executablePath = executablePath(
                            for: command,
                            item: item,
                            processEnvironment: processEnvironment
                        ) {
                            reportSuccess("item.\(item.name).run", executablePath)
                        } else {
                            reportFailure("item.\(item.name).run", "command '\(command)' is unavailable in the configured shell environment")
                            problemCount += 1
                        }
                    } else {
                        reportFailure("item.\(item.name).run", "could not identify a single command to check safely")
                        problemCount += 1
                    }
            }
        }

        if problemCount == 0 {
            output.stdout("Doctor found no problems.\n")
            return 0
        }
        output.stdout("Doctor found \(problemCount) problem\(problemCount == 1 ? "" : "s").\n")
        return CLIExitCode.diagnostics
    }

    private func executablePath(
        for command: String,
        item: CommandItemConfig,
        processEnvironment: [String: String]
    ) -> String? {
        if command.contains("/") {
            let path: String
            if command.hasPrefix("/") {
                path = command
            } else {
                let base = item.workingDirectory ?? fileManager.currentDirectoryPath
                path = URL(fileURLWithPath: base).appendingPathComponent(command).path
            }
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }

        let pathValue = item.environment["PATH"] ?? processEnvironment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: false) {
            let directoryPath = directory.isEmpty
                ? fileManager.currentDirectoryPath
                : String(directory)
            let path = URL(fileURLWithPath: directoryPath).appendingPathComponent(command).path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private var configURL: URL {
        URL(fileURLWithPath: configPath)
    }

    private func ensureConfigDirectory() throws {
        let directory = configURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CLIError.config("unable to create config directory \(directory.path): \(error)")
        }
    }

    private func ensureConfigPathIsFile() throws {
        var isDirectory = ObjCBool(false)
        guard !fileManager.fileExists(atPath: configPath, isDirectory: &isDirectory) || !isDirectory.boolValue else {
            throw CLIError.config("config path is a directory: \(configPath)")
        }
    }

    private func loadConfig() throws -> PinchosConfig {
        guard fileManager.fileExists(atPath: configPath) else {
            throw CLIError.config("config does not exist: \(configPath); run 'pinchos init'")
        }
        guard fileManager.isReadableFile(atPath: configPath) else {
            throw CLIError.config("config is not readable: \(configPath)")
        }

        let text: String
        do {
            text = try String(contentsOf: configURL, encoding: .utf8)
        } catch {
            throw CLIError.config("unable to read config \(configPath): \(error)")
        }
        do {
            return try ConfigParser.parse(text, relativeTo: configURL)
        } catch {
            throw CLIError.config("invalid config \(configPath): \(error)")
        }
    }

    private func reportSuccess(_ check: String, _ detail: String) {
        output.stdout("[PASS] \(check): \(detail)\n")
    }

    private func reportFailure(_ check: String, _ detail: String) {
        output.stdout("[FAIL] \(check): \(detail)\n")
    }

    /// Reports the configured icon source. Missing files and unavailable
    /// symbols are doctor failures (the item itself stays valid and renders
    /// text-only). `reportAbsentAsIconNotConfigured` preserves the historical
    /// command-item "icon: not configured" line; groups omit the absent case
    /// so existing doctor output for icon-free groups stays unchanged.
    @discardableResult
    private func reportIconSource(
        path: String,
        source: ItemIconSource?,
        reportAbsentAsIconNotConfigured: Bool
    ) -> Int {
        switch source {
        case .file(let icon):
            if fileManager.isReadableFile(atPath: icon) {
                reportSuccess("\(path).icon", icon)
                return 0
            }
            reportFailure("\(path).icon", "file is missing or unreadable: \(icon)")
            return 1
        case .symbol(let name):
            if StatusItemIconRenderer.isSymbolAvailable(name) {
                reportSuccess("\(path).symbol", name)
                return 0
            }
            reportFailure(
                "\(path).symbol",
                "unavailable on this macOS version; rendering text-only: \(name)"
            )
            return 1
        case nil:
            if reportAbsentAsIconNotConfigured {
                reportSuccess("\(path).icon", "not configured")
            }
            return 0
        }
    }

    private func commandName(from run: String) -> String? {
        var tokens = [String]()
        var token = ""
        var quote: Character?
        var escaped = false

        func appendToken() {
            guard !token.isEmpty else { return }
            tokens.append(token)
            token.removeAll(keepingCapacity: true)
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
                } else {
                    token.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
            } else if character == "\\" {
                escaped = true
            } else if character.isWhitespace {
                appendToken()
            } else if ";|&()\n\r".contains(character) {
                return nil
            } else {
                token.append(character)
            }
        }

        guard quote == nil, !escaped else { return nil }
        appendToken()

        var commandIndex = 0
        while commandIndex < tokens.count, isEnvironmentAssignment(tokens[commandIndex]) {
            commandIndex += 1
        }
        if commandIndex < tokens.count, tokens[commandIndex] == "env" {
            commandIndex += 1
            while commandIndex < tokens.count, isEnvironmentAssignment(tokens[commandIndex]) {
                commandIndex += 1
            }
            if commandIndex < tokens.count, tokens[commandIndex] == "--" {
                commandIndex += 1
            } else if commandIndex < tokens.count, tokens[commandIndex].hasPrefix("-") {
                return nil
            }
        }
        guard commandIndex < tokens.count else { return nil }

        let command = tokens[commandIndex]
        guard !command.isEmpty,
              !command.hasPrefix("$"),
              !command.contains("$("),
              !["!", "if", "for", "while", "until", "case", "function", "{", "}"].contains(command),
              !command.hasPrefix(">"),
              !command.hasPrefix("<") else { return nil }
        return command
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

    private func normalizedExitCode(_ code: Int32) -> Int32 {
        guard code > 0 else { return 0 }
        return min(code, 255)
    }

    private func printGeneralHelp() {
        let help = """
        Usage: pinchos <command> [options]

        Commands:
          init             Create a documented example config safely
          validate         Parse and semantically validate the config
          doctor           Check config and runtime prerequisites
          config-path      Print the resolved config path
          open-config      Open the config in its default application
          run <item>       Execute one configured item

        Use `pinchos <command> --help` for command-specific help.
        """
        output.stdout(help + "\n")
    }

    private func printInitHelp() {
        output.stdout("Usage: pinchos init\n\nCreate the config directory and a documented example config without overwriting an existing config.\n")
    }

    private func printValidateHelp() {
        output.stdout("Usage: pinchos validate\n\nParse and semantically validate the current config. Errors include item/key context and source lines when available.\n")
    }

    private func printDoctorHelp() {
        output.stdout("Usage: pinchos doctor\n\nInspect config accessibility, shells, commands, working directories, icons and SF Symbols, and environment.\n")
    }

    private func printConfigPathHelp() {
        output.stdout("Usage: pinchos config-path\n\nPrint the resolved config path without creating files.\n")
    }

    private func printOpenConfigHelp() {
        output.stdout("Usage: pinchos open-config\n\nOpen the resolved config in its default application, creating an empty file if needed.\n")
    }

    private func printRunHelp() {
        output.stdout("Usage: pinchos run <item>\n\nExecute one configured item with the shell, working directory, merged environment, timeout, and output limits used by Pinchos.\n")
    }

}
