import AppKit
import Darwin
import Dispatch
import PinchosCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var controller = StatusItemController(configPath: configPath) { [weak self] in
        self?.requestReload()
    }
    private var watcher: ConfigWatcher?
    private let configPath = ConfigLocation.resolve()
    private var isTerminating = false
    private lazy var loadCoordinator = ConfigLoadCoordinator(
        loader: ConfigFileLoader.load,
        resultHandler: { [weak self] outcome in
            await self?.apply(outcome: outcome)
        }
    )
    private lazy var shutdownCoordinator = ShutdownCoordinator(
        signalNumbers: [SIGTERM, SIGINT],
        cleanup: { [weak self] in
            guard let self else { return }
            self.watcher?.stop()
            self.watcher = nil
            await self.loadCoordinator.shutdown()
            await self.controller.shutdown()
        },
        forcedExit: { code in Darwin.exit(code) },
        autoFinishOnCleanup: true,
        onFinished: { reason in
            switch reason {
            case .normalQuit:
                NSApp.reply(toApplicationShouldTerminate: true)
            case .signal, .cliCompletion:
                NSApp.terminate(nil)
            }
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        shutdownCoordinator.start()
        NSApp.setActivationPolicy(.accessory)
        requestReload()

        let watcher = ConfigWatcher(path: configPath) { [weak self] in
            self?.requestReload()
        }
        watcher.start()
        self.watcher = watcher
    }

    /// Requests a config reload. The actual file read and TOML parse happen off the
    /// main actor inside `loadCoordinator`; only the final `apply(outcome:)` step below
    /// touches AppKit state, and only for the most recently requested revision.
    private func requestReload() {
        guard !isTerminating, !shutdownCoordinator.isShutdownRequested else { return }
        let path = configPath
        let coordinator = loadCoordinator
        Task { await coordinator.requestLoad(path: path) }
    }

    private func apply(outcome: ConfigLoadOutcome) async {
        guard !isTerminating, !shutdownCoordinator.isShutdownRequested else { return }
        switch outcome {
        case .success(let config):
            await controller.apply(config: config)
        case .parseFailure(let description):
            await controller.showParseError(description)
        case .missingFile:
            await controller.showRecovery(configExists: false)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownCoordinator.isFinished {
            return .terminateNow
        }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        shutdownCoordinator.requestShutdown(reason: .normalQuit)
        return .terminateLater
    }
}
