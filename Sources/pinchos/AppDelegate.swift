import AppKit
import Darwin
import Dispatch
import PinchosCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var controller = StatusItemController(configPath: configPath) { [weak self] in
        Task { @MainActor in
            await self?.loadAndApply()
        }
    }
    private var watcher: ConfigWatcher?
    private let configPath = ConfigLocation.resolve()
    private var isTerminating = false
    private lazy var shutdownCoordinator = ShutdownCoordinator(
        signalNumbers: [SIGTERM, SIGINT],
        cleanup: { [weak self] in
            guard let self else { return }
            self.watcher?.stop()
            self.watcher = nil
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
        Task { @MainActor [weak self] in
            await self?.loadAndApply()
        }

        let watcher = ConfigWatcher(path: configPath) { [weak self] in
            Task { @MainActor in
                await self?.loadAndApply()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    @MainActor
    private func loadAndApply() async {
        guard !isTerminating, !shutdownCoordinator.isShutdownRequested else { return }
        do {
            let text = try String(contentsOfFile: configPath, encoding: .utf8)
            let config = try ConfigParser.parse(text, relativeTo: URL(fileURLWithPath: configPath))
            await controller.apply(config: config)
        } catch {
            if FileManager.default.fileExists(atPath: configPath) {
                await controller.showParseError(error)
            } else {
                await controller.showRecovery(configExists: false)
            }
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
