import AppKit
import PinchosCore

@MainActor
protocol StatusItemMenuDelegate: AnyObject {
    func showLifecycleMenu(for statusItem: NSStatusItem)
}

@MainActor
protocol ManagedItemLifecycle: AnyObject {
    var config: ItemConfig { get }
    func owns(statusItem: NSStatusItem) -> Bool
    func activate()
    func prepareUpdate(config: ItemConfig) async
    func commitPreparedUpdate()
    func prepareRemoval() async
    func commitRemoval()
    func tearDown() async
    func runnerSnapshot() async -> CommandRunnerSnapshot
    func refreshNow()
}

@MainActor
protocol ManagedItemFactory: AnyObject {
    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle
}

@MainActor
private final class DefaultManagedItemFactory: ManagedItemFactory {
    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        ManagedItem(
            config: config,
            menuDelegate: menuDelegate,
            initiallyVisible: initiallyVisible
        )
    }
}

private enum RecoveryActionError: LocalizedError {
    case unableToCreateConfig
    case unableToOpenConfig
    case unableToOpenConfigDirectory

    var errorDescription: String? {
        switch self {
        case .unableToCreateConfig:
            return "Unable to create the Pinchos config."
        case .unableToOpenConfig:
            return "Unable to open the Pinchos config."
        case .unableToOpenConfigDirectory:
            return "Unable to open the Pinchos config directory."
        }
    }
}

@MainActor
final class StatusItemController: StatusItemMenuDelegate {
    private let itemFactory: any ManagedItemFactory
    private var items: [String: any ManagedItemLifecycle] = [:]
    private var order: [String] = []
    private var warningItem: NSStatusItem?
    private var recoveryState = RecoveryState()
    private let configPath: String
    private let onReload: () -> Void
    private var lifecycleTail: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init(
        configPath: String,
        onReload: @escaping () -> Void,
        itemFactory: (any ManagedItemFactory)? = nil
    ) {
        self.itemFactory = itemFactory ?? DefaultManagedItemFactory()
        self.configPath = configPath
        self.onReload = onReload
    }

    func apply(config: PinchosConfig) async {
        await enqueueLifecycleOperation { [weak self] in
            await self?.applyNow(config: config)
        }
    }

    private func applyNow(config: PinchosConfig) async {
        let old = currentConfig()
        let diff = ConfigDiffEngine.diff(old: old, new: config)
        recoveryState.apply(config: config)
        if recoveryState.isVisible {
            updateRecoveryItem()
        } else {
            clearWarningItem()
        }
        guard !diff.isEmpty else { return }
        await apply(diff: diff, config: config)
    }

    func showParseError(_ error: Error) async {
        let description = String(describing: error)
        await enqueueLifecycleOperation { [weak self] in
            self?.showRecoveryNow(configExists: true, errorDescription: description)
        }
    }

    func showRecovery(configExists: Bool) async {
        await enqueueLifecycleOperation { [weak self] in
            self?.showRecoveryNow(configExists: configExists, errorDescription: nil)
        }
    }

    private func showRecoveryNow(configExists: Bool, errorDescription: String?) {
        recoveryState.show(configExists: configExists, errorDescription: errorDescription)
        updateRecoveryItem()
    }

    private func updateRecoveryItem() {
        guard recoveryState.isVisible else { return }
        if warningItem == nil {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.target = self
            statusItem.button?.action = #selector(handleWarningClick)
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            warningItem = statusItem
        }
        warningItem?.button?.title = recoveryState.errorDescription == nil
            ? "pinchos"
            : "pinchos \u{26A0}\u{FE0E}"
    }

    func showLifecycleMenu(for statusItem: NSStatusItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let menu = await self.makeLifecycleMenu(for: statusItem)
            self.present(menu: menu, on: statusItem)
        }
    }

    private func currentConfig() -> PinchosConfig {
        PinchosConfig(items: order.compactMap { items[$0]?.config })
    }

    private func rebuild(with config: PinchosConfig) async {
        let oldItems = order.compactMap { items[$0] }
        for item in oldItems {
            await item.prepareRemoval()
        }
        let newItems = config.items.map {
            itemFactory.make(config: $0, menuDelegate: self, initiallyVisible: false)
        }

        for item in oldItems {
            item.commitRemoval()
        }
        items = Dictionary(uniqueKeysWithValues: newItems.map { ($0.config.name, $0) })
        order = config.items.map(\.name)
        for item in newItems {
            item.activate()
        }
    }

    private func apply(diff: ConfigDiff, config: PinchosConfig) async {
        if diff.requiresNativeRebuild {
            await rebuild(with: config)
            return
        }

        let addedItems = diff.added.map {
            itemFactory.make(config: $0, menuDelegate: self, initiallyVisible: false)
        }
        for item in diff.changed {
            await items[item.name]?.prepareUpdate(config: item)
        }
        for name in diff.removed {
            if let item = items[name] {
                await item.prepareRemoval()
            }
        }

        let removedItems = diff.removed.compactMap { items.removeValue(forKey: $0) }
        for item in removedItems {
            item.commitRemoval()
        }
        for item in diff.changed {
            items[item.name]?.commitPreparedUpdate()
        }
        for item in addedItems {
            items[item.config.name] = item
            item.activate()
        }
        order = diff.newOrder
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
        recoveryState.dismiss()
    }

    @objc private func handleWarningClick() {
        guard warningItem != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, let warningItem = self.warningItem else { return }
            let menu = self.buildRecoveryMenu()
            self.present(menu: menu, on: warningItem)
        }
    }

    private func buildRecoveryMenu() -> NSMenu {
        let menu = NSMenu()
        if let errorDescription = recoveryState.errorDescription {
            let errorItem = NSMenuItem(title: errorDescription, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }
        for action in recoveryState.menu.actions {
            let selector: Selector
            switch action {
            case .createExampleConfig:
                selector = #selector(createExampleConfigAction)
            case .openConfig:
                selector = #selector(openConfigAction)
            case .openConfigDirectory:
                selector = #selector(openConfigDirectoryAction)
            case .reload:
                selector = #selector(reloadConfigAction)
            case .quit:
                selector = #selector(quitAction)
            }
            let item = NSMenuItem(title: action.rawValue, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func makeLifecycleMenu(for statusItem: NSStatusItem?) async -> NSMenu {
        let menu = NSMenu()
        if let statusItem,
            let item = items.values.first(where: { $0.owns(statusItem: statusItem) })
        {
            let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction(_:)), keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = statusItem
            menu.addItem(refresh)
            menu.addItem(NSMenuItem.separator())
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
            case .launchFailed(let message):
                menu.addItem(disabledItem(title: "Last result: launch failed"))
                if !message.isEmpty {
                    menu.addItem(disabledItem(title: "launch: \(String(message.prefix(200)))"))
                }
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

    @objc private func refreshAction(_ sender: NSMenuItem) {
        guard let statusItem = sender.representedObject as? NSStatusItem,
              let item = items.values.first(where: { $0.owns(statusItem: statusItem) }) else { return }
        item.refreshNow()
    }

    @objc private func reloadConfigAction() {
        onReload()
    }

    @objc private func createExampleConfigAction() {
        guard recoveryState.menu.canCreateExampleConfig else { return }
        do {
            try writeExampleConfig()
        } catch {
            showRecoveryError(error)
        }
    }

    func writeExampleConfig() throws {
        try ensureConfigDirectory()
        guard !FileManager.default.fileExists(atPath: configPath) else { return }
        guard let data = PinchosCore.ExampleConfig.text.data(using: .utf8) else {
            throw RecoveryActionError.unableToCreateConfig
        }
        try data.write(to: URL(fileURLWithPath: configPath), options: [.withoutOverwriting])
    }

    @objc private func openConfigAction() {
        do {
            try openConfig()
        } catch {
            showRecoveryError(error)
        }
    }

    func openConfig() throws {
        try ensureConfigDirectory()
        if !FileManager.default.fileExists(atPath: configPath) {
            try Data().write(
                to: URL(fileURLWithPath: configPath),
                options: [.withoutOverwriting]
            )
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) else {
            throw RecoveryActionError.unableToOpenConfig
        }
    }

    @objc private func openConfigDirectoryAction() {
        do {
            try openConfigDirectory()
        } catch {
            showRecoveryError(error)
        }
    }

    func openConfigDirectory() throws {
        try ensureConfigDirectory()
        let directory = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        guard NSWorkspace.shared.open(directory) else {
            throw RecoveryActionError.unableToOpenConfigDirectory
        }
    }

    private func ensureConfigDirectory() throws {
        let directory = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func showRecoveryError(_ error: Error) {
        showRecoveryNow(
            configExists: FileManager.default.fileExists(atPath: configPath),
            errorDescription: String(describing: error)
        )
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
