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
        await withTaskGroup(of: Void.self) { group in
            for runner in runners {
                group.addTask { await runner.cancelForShutdown() }
            }
        }
    }
}

private enum CLIExitCode {
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
        case .usage: return CLIExitCode.usage
        case .config, .open: return CLIExitCode.config
        }
    }

    var message: String {
        switch self {
        case .usage(let message), .config(let message), .open(let message): return message
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
        if ["--help", "-h", "help"].contains(command) {
            printGeneralHelp()
            return 0
        }

        do {
            switch command {
            case "init": return try runInit(arguments: Array(arguments.dropFirst()))
            case "validate": return try runValidate(arguments: Array(arguments.dropFirst()))
            case "doctor": return try await runDoctor(arguments: Array(arguments.dropFirst()))
            case "config-path": return try runConfigPath(arguments: Array(arguments.dropFirst()))
            case "open-config": return try runOpenConfig(arguments: Array(arguments.dropFirst()))
            case "run": return try await runItem(arguments: Array(arguments.dropFirst()))
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
        guard arguments.isEmpty else { throw CLIError.usage("usage: pinchos init [--help]") }

        try ensureConfigDirectory()
        try ensureConfigPathIsFile()
        if fileManager.fileExists(atPath: configPath) {
            output.stdout("Config already exists: \(configPath)\n")
            return 0
        }
        do {
            try Data(ExampleConfig.text.utf8).write(to: configURL, options: [.withoutOverwriting])
        } catch {
            if fileManager.fileExists(atPath: configPath) {
                output.stdout("Config already exists: \(configPath)\n")
                return 0
            }
            throw CLIError.config("unable to create config at \(configPath): \(error)")
        }
        output.stdout("Created example config: \(configPath)\n")
        return 0
    }

    private func runValidate(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printValidateHelp()
            return 0
        }
        guard arguments.isEmpty else { throw CLIError.usage("usage: pinchos validate [--help]") }
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
        guard arguments.isEmpty else { throw CLIError.usage("usage: pinchos config-path [--help]") }
        output.stdout("\(configPath)\n")
        return 0
    }

    private func runOpenConfig(arguments: [String]) throws -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            printOpenConfigHelp()
            return 0
        }
        guard arguments.isEmpty else { throw CLIError.usage("usage: pinchos open-config [--help]") }

        try ensureConfigDirectory()
        try ensureConfigPathIsFile()
        if !fileManager.fileExists(atPath: configPath) {
            do {
                try Data().write(to: configURL, options: [.withoutOverwriting])
            } catch where !fileManager.fileExists(atPath: configPath) {
                throw CLIError.open("unable to create config at \(configPath): \(error)")
            }
        }
        guard opener(configURL) else {
            throw CLIError.open("unable to open config with the default application: \(configPath)")
        }
        output.stdout("Opened config: \(configPath)\n")
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
        guard let item = config.items.first(where: { $0.name == name }) else {
            throw CLIError.config("item '\(name)' is not configured in \(configPath)")
        }
        guard shutdownCoordinator?.isShutdownRequested != true else {
            return shutdownCoordinator?.terminationExitCode ?? CLIExitCode.execution
        }

        let runner = makeRunner(for: item)
        guard runnerRegistry.register(runner) else {
            return shutdownCoordinator?.terminationExitCode ?? CLIExitCode.execution
        }
        defer { runnerRegistry.unregister(runner) }

        guard case .completed = await runner.runIfIdle() else {
            if let code = shutdownCoordinator?.terminationExitCode { return code }
            output.stderr("pinchos run \(name): command was skipped because another execution is active\n")
            return CLIExitCode.execution
        }
        let execution = await runner.awaitSettledExecution()
        if let code = shutdownCoordinator?.terminationExitCode { return code }
        guard let execution else {
            output.stderr("pinchos run \(name): command did not produce a settled result\n")
            return CLIExitCode.execution
        }

        if !execution.stdout.isEmpty { output.stdout(execution.stdout) }
        if !execution.stderr.isEmpty { output.stderr(execution.stderr) }

        switch execution.terminalReason {
        case .exited(let code):
            if code != 0 { output.stderr("pinchos run \(name): exited with code \(code)\n") }
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
        guard arguments.isEmpty else { throw CLIError.usage("usage: pinchos doctor [--help]") }

        var problemCount = 0
        output.stdout("Pinchos doctor\nConfig path: \(configPath)\n")

        let config: PinchosConfig?
        var isDirectory = ObjCBool(false)
        if !fileManager.fileExists(atPath: configPath, isDirectory: &isDirectory) {
            reportFailure("config", "missing; run 'pinchos init'")
            problemCount += 1
            config = nil
        } else if isDirectory.boolValue {
            reportFailure("config", "path is a directory")
            problemCount += 1
            config = nil
        } else if !fileManager.isReadableFile(atPath: configPath) {
            reportFailure("config", "file is not readable")
            problemCount += 1
            config = nil
        } else {
            do {
                config = try loadConfig()
                reportSuccess("config", "readable and parsed")
            } catch let error as CLIError {
                reportFailure("config", error.message)
                problemCount += 1
                config = nil
            }
        }

        if fileManager.isExecutableFile(atPath: ItemConfig.defaultShell[0]) {
            reportSuccess("shell", ItemConfig.defaultShell[0])
        } else {
            reportFailure("shell", "missing: \(ItemConfig.defaultShell[0])")
            problemCount += 1
        }

        var workdirIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: ItemConfig.defaultWorkingDirectory, isDirectory: &workdirIsDirectory), workdirIsDirectory.boolValue {
            reportSuccess("working directory", ItemConfig.defaultWorkingDirectory)
        } else {
            reportFailure("working directory", "missing: \(ItemConfig.defaultWorkingDirectory)")
            problemCount += 1
        }
        reportSuccess("PATH", ItemConfig.defaultEnvironment["PATH"] ?? "")

        if let config {
            if config.items.isEmpty {
                reportFailure("config", "contains no items")
                problemCount += 1
            }
            for item in config.items {
                problemCount += reportIconSource(path: "item.\(item.name)", source: item.iconSource)
                if let command = commandName(from: item.run) {
                    if let executable = executablePath(for: command) {
                        reportSuccess("item.\(item.name).run", executable)
                    } else {
                        reportFailure("item.\(item.name).run", "command '\(command)' is unavailable in Pinchos PATH")
                        problemCount += 1
                    }
                } else {
                    reportInfo("item.\(item.name).run", "compound shell command; executable probe skipped")
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

    @discardableResult
    private func reportIconSource(path: String, source: ItemIconSource?) -> Int {
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
            reportFailure("\(path).symbol", "unavailable on this macOS version; rendering text-only")
            return 1
        case nil:
            reportSuccess("\(path).icon", "not configured")
            return 0
        }
    }

    private func executablePath(for command: String) -> String? {
        if command.contains("/") {
            let path = command.hasPrefix("/")
                ? command
                : URL(fileURLWithPath: ItemConfig.defaultWorkingDirectory).appendingPathComponent(command).path
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in (ItemConfig.defaultEnvironment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private var configURL: URL { URL(fileURLWithPath: configPath) }

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

    private func makeRunner(for item: ItemConfig) -> CommandRunner {
        CommandRunner(
            command: item.run,
            timeout: item.timeout,
            maxOutputBytes: ItemConfig.defaultMaxOutputBytes,
            shell: ItemConfig.defaultShell,
            workingDirectory: ItemConfig.defaultWorkingDirectory,
            environment: ItemConfig.defaultEnvironment
        )
    }

    private func reportSuccess(_ check: String, _ detail: String) {
        output.stdout("[PASS] \(check): \(detail)\n")
    }

    private func reportFailure(_ check: String, _ detail: String) {
        output.stdout("[FAIL] \(check): \(detail)\n")
    }

    private func reportInfo(_ check: String, _ detail: String) {
        output.stdout("[INFO] \(check): \(detail)\n")
    }

    private func commandName(from run: String) -> String? {
        var tokens: [String] = []
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
                    if character == activeQuote { quote = nil } else { token.append(character) }
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
            } else if character == "'" || character == "\"" {
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

        var index = 0
        while index < tokens.count, isEnvironmentAssignment(tokens[index]) { index += 1 }
        if index < tokens.count, tokens[index] == "env" {
            index += 1
            while index < tokens.count, isEnvironmentAssignment(tokens[index]) { index += 1 }
            if index < tokens.count, tokens[index] == "--" { index += 1 }
            else if index < tokens.count, tokens[index].hasPrefix("-") { return nil }
        }
        guard index < tokens.count else { return nil }
        let command = tokens[index]
        guard !command.hasPrefix("$"), !command.contains("$("),
              !["!", "if", "for", "while", "until", "case", "function", "{", "}"].contains(command),
              !command.hasPrefix(">"), !command.hasPrefix("<") else { return nil }
        return command
    }

    private func isEnvironmentAssignment(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard let equals = bytes.firstIndex(of: 61), equals > 0 else { return false }
        let name = bytes[..<equals]
        guard let first = name.first,
              first == 95 || (65...90).contains(first) || (97...122).contains(first) else { return false }
        return name.dropFirst().allSatisfy { byte in
            byte == 95 || (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    private func normalizedExitCode(_ code: Int32) -> Int32 {
        guard code > 0 else { return 0 }
        return min(code, 255)
    }

    private func printGeneralHelp() {
        output.stdout("""
        Usage: pinchos <command> [options]

        Commands:
          init             Create the canonical example config safely
          validate         Parse and validate the config
          doctor           Check config and fixed runtime prerequisites
          config-path      Print the resolved config path
          open-config      Open the config in its default application
          run <item>       Execute one configured item

        Use `pinchos <command> --help` for command-specific help.
        """ + "\n")
    }

    private func printInitHelp() {
        output.stdout("Usage: pinchos init\n\nCreate the config directory and canonical example without overwriting an existing config.\n")
    }

    private func printValidateHelp() {
        output.stdout("Usage: pinchos validate\n\nParse and semantically validate the current config.\n")
    }

    private func printDoctorHelp() {
        output.stdout("Usage: pinchos doctor\n\nInspect config accessibility, the fixed command environment, commands, and icons.\n")
    }

    private func printConfigPathHelp() {
        output.stdout("Usage: pinchos config-path\n\nPrint the resolved config path without creating files.\n")
    }

    private func printOpenConfigHelp() {
        output.stdout("Usage: pinchos open-config\n\nOpen the config, creating an empty file if needed.\n")
    }

    private func printRunHelp() {
        output.stdout("Usage: pinchos run <item>\n\nExecute one item with the same fixed shell, PATH, working directory, timeout, and output bound as the app.\n")
    }
}
