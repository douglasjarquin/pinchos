import AppKit
import PinchosCore

@MainActor
final class StatusItemController: StatusItemMenuDelegate {
    private var items: [String: ManagedItem] = [:]
    private var order: [String] = []
    private var warningItem: NSStatusItem?
    private var lastErrorDescription = ""
    private let onReload: () -> Void
    private var lifecycleTail: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init(onReload: @escaping () -> Void) {
        self.onReload = onReload
    }

    func apply(config: PinchosConfig) async {
        await enqueueLifecycleOperation { [weak self] in
            await self?.applyNow(config: config)
        }
    }

    private func applyNow(config: PinchosConfig) async {
        clearWarningItem()
        let old = currentConfig()
        let diff = ConfigDiffEngine.diff(old: old, new: config)
        guard !diff.isEmpty else { return }
        await rebuild(with: config)
    }

    func showParseError(_ error: Error) async {
        let description = String(describing: error)
        await enqueueLifecycleOperation { [weak self] in
            self?.showParseErrorNow(description: description)
        }
    }

    private func showParseErrorNow(description: String) {
        lastErrorDescription = description
        guard warningItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "pinchos \u{26A0}\u{FE0E}"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleWarningClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        warningItem = statusItem
    }

    func showLifecycleMenu(for statusItem: NSStatusItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let menu = await self.buildLifecycleMenu(for: statusItem)
            self.present(menu: menu, on: statusItem)
        }
    }

    private func currentConfig() -> PinchosConfig {
        PinchosConfig(items: order.compactMap { items[$0]?.config })
    }

    private func rebuild(with config: PinchosConfig) async {
        for name in order { await items[name]?.tearDown() }
        items.removeAll()
        order = config.items.map(\.name)
        for item in config.items {
            items[item.name] = ManagedItem(config: item, menuDelegate: self)
        }
    }

    func shutdown() async {
        await enqueueLifecycleOperation { [weak self] in
            await self?.shutdownNow()
        }
    }

    private func shutdownNow() async {
        for name in order { await items[name]?.tearDown() }
        items.removeAll()
        order.removeAll()
        clearWarningItem()
    }

    private func enqueueLifecycleOperation(_ operation: @escaping @MainActor () async -> Void) async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let previous = lifecycleTail
        let task = Task { @MainActor in
            _ = await previous?.value
            await operation()
        }
        lifecycleTail = task
        _ = await task.value
        if lifecycleGeneration == generation {
            lifecycleTail = nil
        }
    }

    private func clearWarningItem() {
        if let warningItem {
            NSStatusBar.system.removeStatusItem(warningItem)
        }
        warningItem = nil
    }

    @objc private func handleWarningClick() {
        guard warningItem != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let warningItem = self.warningItem else { return }
            let menu = await self.buildLifecycleMenu(for: nil)
            let errorItem = NSMenuItem(title: self.lastErrorDescription, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.insertItem(errorItem, at: 0)
            menu.insertItem(NSMenuItem.separator(), at: 1)
            self.present(menu: menu, on: warningItem)
        }
    }

    private func buildLifecycleMenu(for statusItem: NSStatusItem?) async -> NSMenu {
        let menu = NSMenu()
        if let statusItem,
            let item = items.values.first(where: { $0.statusItem === statusItem })
        {
            addDiagnostics(from: await item.runnerSnapshot(), to: menu)
            menu.addItem(NSMenuItem.separator())
        }
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigAction), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit Pinchos", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func addDiagnostics(from snapshot: CommandRunnerSnapshot, to menu: NSMenu) {
        menu.addItem(disabledItem(title: snapshot.isRunning ? "Status: running" : "Status: waiting"))
        if let execution = snapshot.lastExecution {
            switch execution.terminalReason {
            case .exited(let code):
                menu.addItem(disabledItem(title: "Last exit code: \(code)"))
            case .signaled(let signal):
                menu.addItem(disabledItem(title: "Last signal: \(signal)"))
            case .timedOut:
                menu.addItem(disabledItem(title: "Last result: timed out"))
            case .cancelled:
                menu.addItem(disabledItem(title: "Last result: cancelled"))
            case .launchFailed:
                menu.addItem(disabledItem(title: "Last result: launch failed"))
            }
            menu.addItem(disabledItem(title: String(format: "Duration: %.3fs", execution.duration)))
            menu.addItem(
                disabledItem(
                    title: execution.stdoutTruncated
                        ? "stdout: truncated (\(execution.stdoutBytesRead) bytes)"
                        : "stdout: \(execution.stdoutBytesRead) bytes"))
            menu.addItem(
                disabledItem(
                    title: execution.stderrTruncated
                        ? "stderr: truncated (\(execution.stderrBytesRead) bytes)"
                        : "stderr: \(execution.stderrBytesRead) bytes"))
            let stderrLine = lastTrimmedLine(of: execution.stderr)
            if !stderrLine.isEmpty {
                menu.addItem(disabledItem(title: "stderr: \(String(stderrLine.prefix(200)))"))
            }
        }
        menu.addItem(disabledItem(title: "Skipped ticks: \(snapshot.skippedRefreshes)"))
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
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
