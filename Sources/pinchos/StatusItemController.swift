import AppKit
import PinchosCore

@MainActor
final class StatusItemController: StatusItemMenuDelegate {
    private var items: [String: ManagedItem] = [:]
    private var order: [String] = []
    private var warningItem: NSStatusItem?
    private var lastErrorDescription = ""
    private let onReload: () -> Void

    init(onReload: @escaping () -> Void) {
        self.onReload = onReload
    }

    func apply(config: PinchosConfig) {
        clearWarningItem()
        let old = currentConfig()
        let diff = ConfigDiffEngine.diff(old: old, new: config)
        guard !diff.isEmpty else { return }
        rebuild(with: config)
    }

    func showParseError(_ error: Error) {
        lastErrorDescription = String(describing: error)
        guard warningItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "pinchos \u{26A0}\u{FE0E}"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleWarningClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        warningItem = statusItem
    }

    func showLifecycleMenu(for statusItem: NSStatusItem) {
        present(menu: buildLifecycleMenu(), on: statusItem)
    }

    private func currentConfig() -> PinchosConfig {
        PinchosConfig(items: order.compactMap { items[$0]?.config })
    }

    private func rebuild(with config: PinchosConfig) {
        for name in order { items[name]?.tearDown() }
        items.removeAll()
        order = config.items.map(\.name)
        for item in config.items {
            items[item.name] = ManagedItem(config: item, menuDelegate: self)
        }
    }

    private func clearWarningItem() {
        if let warningItem {
            NSStatusBar.system.removeStatusItem(warningItem)
        }
        warningItem = nil
    }

    @objc private func handleWarningClick() {
        guard let warningItem else { return }
        let menu = buildLifecycleMenu()
        let errorItem = NSMenuItem(title: lastErrorDescription, action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        menu.insertItem(errorItem, at: 0)
        menu.insertItem(NSMenuItem.separator(), at: 1)
        present(menu: menu, on: warningItem)
    }

    private func buildLifecycleMenu() -> NSMenu {
        let menu = NSMenu()
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigAction), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit Pinchos", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func present(menu: NSMenu, on statusItem: NSStatusItem) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func reloadConfigAction() {
        onReload()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
