import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        guard !isTerminating else { return }
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
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        watcher?.stop()
        watcher = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
