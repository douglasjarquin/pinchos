import Darwin
import Foundation

/// Generates, installs, and inspects the per-user `launchd` LaunchAgent that
/// starts Pinchos at login.
///
/// This is intentionally a per-user LaunchAgent under `~/Library/LaunchAgents`
/// rather than an `SMAppService`-managed login item: Pinchos ships today as a
/// standalone SwiftPM binary, not an `.app` bundle, so `SMAppService` (which
/// registers a bundle's helper/agent by bundle identifier) does not apply
/// until the packaging work in issue #15. A LaunchAgent plist needs only a
/// path to an executable, which matches how Pinchos is installed today.
///
/// The label is fixed (`com.pinchos.agent`), so there is exactly one possible
/// plist path for this mechanism; reinstalling (e.g. after an upgrade moves
/// the binary) overwrites that single file and reloads it rather than
/// accumulating stale entries under old labels or paths.
struct LaunchAgentService {
    enum InstallOutcome: Equatable {
        case alreadyInstalled
        case installed
        case failed(String)
    }

    enum UninstallOutcome: Equatable {
        case alreadyAbsent
        case uninstalled
        case failed(String)
    }

    struct Status {
        let plistPath: String
        let plistExists: Bool
        let configuredExecutablePath: String?
        let matchesExpectedExecutable: Bool
        let loaded: Bool
        let running: Bool
        let pid: String?
    }

    static let defaultLabel = "com.pinchos.agent"
    /// launchd's own per-agent default PATH; set explicitly so the launch
    /// agent's environment does not depend on any interactive shell profile,
    /// and stays stable even where launchd's own default might vary.
    static let deterministicPATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    let label: String
    let fileManager: FileManager
    let launchctl: LaunchctlRunning
    let homeDirectory: String
    let userID: uid_t

    init(
        label: String = LaunchAgentService.defaultLabel,
        fileManager: FileManager = .default,
        launchctl: LaunchctlRunning = ProcessLaunchctlRunner(),
        homeDirectory: String = NSHomeDirectory(),
        userID: uid_t = getuid()
    ) {
        self.label = label
        self.fileManager = fileManager
        self.launchctl = launchctl
        self.homeDirectory = homeDirectory
        self.userID = userID
    }

    var launchAgentsDirectory: URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    var logDirectory: URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Logs/pinchos", isDirectory: true)
    }

    var standardOutURL: URL { logDirectory.appendingPathComponent("pinchos.log") }
    var standardErrorURL: URL { logDirectory.appendingPathComponent("pinchos.err.log") }

    var domainTarget: String { "gui/\(userID)" }
    var serviceTarget: String { "\(domainTarget)/\(label)" }

    func makeDocument(executablePath: String) -> LaunchAgentPlistDocument {
        LaunchAgentPlistDocument(
            label: label,
            programArguments: [executablePath],
            runAtLoad: true,
            workingDirectory: homeDirectory,
            standardOutPath: standardOutURL.path,
            standardErrorPath: standardErrorURL.path,
            environmentVariables: [
                "HOME": homeDirectory,
                "PATH": Self.deterministicPATH
            ]
        )
    }

    @discardableResult
    func install(executablePath: String) -> InstallOutcome {
        let desiredDocument = makeDocument(executablePath: executablePath)
        let desiredData: Data
        do {
            desiredData = try desiredDocument.encodedPlist()
        } catch {
            return .failed("unable to generate launch agent configuration: \(error)")
        }

        let queryResult = queryLaunchctl()
        let alreadyLoaded = isLoaded(queryResult)
        let existingMatches = existingDocument() == desiredDocument

        if alreadyLoaded, existingMatches {
            return .alreadyInstalled
        }

        do {
            try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            return .failed("unable to create required directories: \(error)")
        }

        if alreadyLoaded {
            let bootout = launchctl.run(["bootout", serviceTarget])
            if !bootout.succeeded {
                return .failed("unable to unload the existing launch agent before reinstalling: \(trimmed(bootout.stderr))")
            }
        }

        do {
            try desiredData.write(to: plistURL, options: .atomic)
        } catch {
            return .failed("unable to write launch agent configuration to \(plistURL.path): \(error)")
        }

        let bootstrap = launchctl.run(["bootstrap", domainTarget, plistURL.path])
        guard bootstrap.succeeded else {
            return .failed("launchctl bootstrap failed: \(trimmed(bootstrap.stderr))")
        }

        // Best-effort: clears a persisted `launchctl disable` from a prior
        // manual override so a fresh install is reliably enabled.
        _ = launchctl.run(["enable", serviceTarget])

        return .installed
    }

    @discardableResult
    func uninstall() -> UninstallOutcome {
        let queryResult = queryLaunchctl()
        let loaded = isLoaded(queryResult)
        let plistExists = fileManager.fileExists(atPath: plistURL.path)

        guard loaded || plistExists else {
            return .alreadyAbsent
        }

        if loaded {
            let bootout = launchctl.run(["bootout", serviceTarget])
            let message = trimmed(bootout.stderr)
            if !bootout.succeeded, !message.isEmpty, !message.lowercased().contains("could not find") {
                return .failed("unable to unload launch agent: \(message)")
            }
        }

        if plistExists {
            do {
                try fileManager.removeItem(at: plistURL)
            } catch {
                return .failed("unable to remove \(plistURL.path): \(error)")
            }
        }

        return .uninstalled
    }

    func status(expectedExecutablePath: String?) -> Status {
        let queryResult = queryLaunchctl()
        let loaded = isLoaded(queryResult)
        let running = loaded && isRunning(queryResult)
        let pid = running ? extractField("pid", from: queryResult) : nil
        let plistExists = fileManager.fileExists(atPath: plistURL.path)
        let configuredExecutablePath = existingDocument()?.programArguments.first
            ?? extractField("program", from: queryResult)

        let matches: Bool
        if let expected = expectedExecutablePath, let configured = configuredExecutablePath {
            matches = expected == configured
        } else {
            matches = false
        }

        return Status(
            plistPath: plistURL.path,
            plistExists: plistExists,
            configuredExecutablePath: configuredExecutablePath,
            matchesExpectedExecutable: matches,
            loaded: loaded,
            running: running,
            pid: pid
        )
    }

    private func existingDocument() -> LaunchAgentPlistDocument? {
        guard let data = fileManager.contents(atPath: plistURL.path) else { return nil }
        return LaunchAgentPlistDocument.decoded(from: data)
    }

    private func queryLaunchctl() -> LaunchctlInvocation {
        launchctl.run(["print", serviceTarget])
    }

    private func isLoaded(_ invocation: LaunchctlInvocation) -> Bool {
        invocation.succeeded
    }

    private func isRunning(_ invocation: LaunchctlInvocation) -> Bool {
        invocation.stdout.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces) == "state = running"
        }
    }

    private func extractField(_ name: String, from invocation: LaunchctlInvocation) -> String? {
        let prefix = "\(name) = "
        for line in invocation.stdout.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix(prefix) {
                return String(trimmedLine.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
