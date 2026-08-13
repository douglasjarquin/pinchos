import AppKit
import PinchosCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var controller = StatusItemController { [weak self] in
        self?.loadAndApply()
    }
    private var watcher: ConfigWatcher?
    private let configPath = ConfigLocation.resolve()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        loadAndApply()

        let watcher = ConfigWatcher(path: configPath) { [weak self] in
            Task { @MainActor in
                self?.loadAndApply()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    @MainActor
    private func loadAndApply() {
        do {
            let text = try String(contentsOfFile: configPath, encoding: .utf8)
            let config = try ConfigParser.parse(text)
            controller.apply(config: config)
        } catch {
            controller.showParseError(error)
        }
    }
}
