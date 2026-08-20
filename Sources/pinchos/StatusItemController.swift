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
    func runtimeSnapshot() async -> ItemRuntimeSnapshot
    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot?
    func clickSnapshot() async -> ClickDiagnosticsSnapshot?
    func invokeAction(at index: Int)
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
private final class RefreshActionTarget: NSObject {
    let item: any ManagedItemLifecycle

    init(item: any ManagedItemLifecycle) {
        self.item = item
    }
}

@MainActor
private final class ItemActionTarget: NSObject {
    let item: any ManagedItemLifecycle
    let index: Int

    init(item: any ManagedItemLifecycle, index: Int) {
        self.item = item
        self.index = index
    }
}

@MainActor
private final class CopyTextTarget: NSObject {
    let text: String

    init(text: String) {
        self.text = text
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

    func showParseError(_ description: String) async {
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
        let item = statusItem.flatMap { statusItem in
            items.values.first(where: { $0.owns(statusItem: statusItem) })
        }
        return await makeLifecycleMenu(forManagedItem: item)
    }

    func makeLifecycleMenu(forManagedItem item: (any ManagedItemLifecycle)?) async -> NSMenu {
        let menu = NSMenu()
        if let item {
            var hasConfiguredRefresh = false
            for (index, action) in item.config.actions.enumerated() {
                let menuItem = NSMenuItem(title: action.title, action: #selector(itemAction(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = ItemActionTarget(item: item, index: index)
                menu.addItem(menuItem)
                if case .refresh = action.kind {
                    hasConfiguredRefresh = true
                }
            }
            if !item.config.actions.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
            if !hasConfiguredRefresh {
                let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction(_:)), keyEquivalent: "")
                refresh.target = self
                refresh.representedObject = RefreshActionTarget(item: item)
                menu.addItem(refresh)
                menu.addItem(NSMenuItem.separator())
            }
            let runtime = await item.runtimeSnapshot()
            addRuntimeState(from: runtime, to: menu)
            menu.addItem(NSMenuItem.separator())
            addDiagnostics(from: runtime.runnerSnapshot, to: menu)
            if let clickSnapshot = await item.clickSnapshot() {
                menu.addItem(NSMenuItem.separator())
                addClickDiagnostics(clickSnapshot, to: menu)
            }
            var actionSnapshots: [(index: Int, snapshot: CommandRunnerSnapshot?)] = []
            for index in item.config.actions.indices {
                actionSnapshots.append((index: index, snapshot: await item.actionSnapshot(at: index)))
            }
            if actionSnapshots.contains(where: { $0.snapshot != nil }) {
                menu.addItem(NSMenuItem.separator())
                addActionDiagnostics(actions: item.config.actions, snapshots: actionSnapshots, to: menu)
            }
            menu.addItem(NSMenuItem.separator())
        }
        let openConfig = NSMenuItem(title: "Open Config", action: #selector(openConfigAction), keyEquivalent: "")
        openConfig.target = self
        menu.addItem(openConfig)
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigAction), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        let quit = NSMenuItem(title: "Quit Pinchos", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func addActionDiagnostics(
        actions: [ItemAction],
        snapshots: [(index: Int, snapshot: CommandRunnerSnapshot?)],
        to menu: NSMenu
    ) {
        for entry in snapshots {
            guard let snapshot = entry.snapshot else { continue }
            let title = actions[entry.index].title
            let actionPrefix = "Action \"\(title)\": "
            menu.addItem(disabledItem(title: actionPrefix + (snapshot.isRunning ? "running" : "waiting")))
            if let execution = snapshot.lastExecution {
                switch execution.terminalReason {
                case .exited(let code):
                    menu.addItem(disabledItem(title: actionPrefix + "last exit code: \(code)"))
                case .signaled(let signal):
                    menu.addItem(disabledItem(title: actionPrefix + "last signal: \(signal)"))
                case .timedOut:
                    menu.addItem(disabledItem(title: actionPrefix + "last result: timed out"))
                case .cancelled:
                    menu.addItem(disabledItem(title: actionPrefix + "last result: cancelled"))
                case .launchFailed(let message):
                    menu.addItem(disabledItem(title: actionPrefix + "launch failed"))
                    if !message.isEmpty {
                        menu.addItem(disabledItem(title: actionPrefix + "launch: \(String(message.prefix(200)))"))
                    }
                }
                let stderrLine = lastTrimmedLine(of: execution.stderr)
                if !stderrLine.isEmpty {
                    menu.addItem(disabledItem(title: actionPrefix + "stderr: \(String(stderrLine.prefix(200)))"))
                }
            }
            if snapshot.skippedRefreshes > 0 {
                menu.addItem(disabledItem(title: actionPrefix + "skipped invocations: \(snapshot.skippedRefreshes)"))
            }
        }
    }

    /// Renders the independent click-command runner's diagnostics. This section
    /// only ever reflects the click runner's own state (never run, running, or
    /// its last terminal reason) and never derives from or feeds back into the
    /// primary item's displayed value or status, matching the fire-and-forget
    /// click contract: a click failure must stay discoverable but invisible to
    /// the menu-bar title.
    private func addClickDiagnostics(_ snapshot: ClickDiagnosticsSnapshot, to menu: NSMenu) {
        let prefix = "Click Action: "
        let runner = snapshot.runner
        menu.addItem(disabledItem(title: prefix + clickStateDescription(runner)))
        if let lastAttemptedAt = snapshot.lastAttemptedAt {
            menu.addItem(disabledItem(title: prefix + "last attempt: \(formatTimestamp(lastAttemptedAt))"))
        }
        if let lastCompletedAt = snapshot.lastCompletedAt {
            menu.addItem(disabledItem(title: prefix + "last completed: \(formatTimestamp(lastCompletedAt))"))
        }
        if let execution = runner.lastExecution {
            switch execution.terminalReason {
            case .exited(let code):
                menu.addItem(disabledItem(title: prefix + "last exit code: \(code)"))
            case .signaled(let signal):
                menu.addItem(disabledItem(title: prefix + "last signal: \(signal)"))
            case .timedOut:
                menu.addItem(disabledItem(title: prefix + "last result: timed out"))
            case .cancelled:
                menu.addItem(disabledItem(title: prefix + "last result: cancelled"))
            case .launchFailed(let message):
                menu.addItem(disabledItem(title: prefix + "last result: launch failed"))
                if !message.isEmpty {
                    menu.addItem(disabledItem(title: prefix + "launch: \(String(message.prefix(200)))"))
                }
            }
            menu.addItem(disabledItem(title: prefix + String(format: "duration: %.3fs", execution.duration)))
            menu.addItem(
                disabledItem(
                    title: prefix
                        + (execution.stdoutTruncated
                            ? "stdout: truncated (\(execution.stdoutBytesRead) bytes)"
                            : "stdout: \(execution.stdoutBytesRead) bytes")))
            menu.addItem(
                disabledItem(
                    title: prefix
                        + (execution.stderrTruncated
                            ? "stderr: truncated (\(execution.stderrBytesRead) bytes)"
                            : "stderr: \(execution.stderrBytesRead) bytes")))
            let stderrLine = lastTrimmedLine(of: execution.stderr)
            if !stderrLine.isEmpty {
                menu.addItem(disabledItem(title: prefix + "stderr: \(String(stderrLine.prefix(200)))"))
            }
            if !execution.stdout.isEmpty {
                menu.addItem(copyItem(title: "Copy Click Output", text: execution.stdout))
            }
            if !execution.stderr.isEmpty {
                menu.addItem(copyItem(title: "Copy Click Error", text: execution.stderr))
            }
        }
        if runner.skippedRefreshes > 0 {
            menu.addItem(disabledItem(title: prefix + "skipped invocations: \(runner.skippedRefreshes)"))
        }
    }

    private func clickStateDescription(_ snapshot: CommandRunnerSnapshot) -> String {
        if snapshot.isRunning {
            return "running"
        }
        guard let execution = snapshot.lastExecution else {
            return "never run"
        }
        switch execution.terminalReason {
        case .exited(let code):
            return code == 0 ? "completed" : "error"
        case .signaled:
            return "error"
        case .timedOut:
            return "timed out"
        case .cancelled:
            return "cancelled"
        case .launchFailed:
            return "error"
        }
    }

    private func copyItem(title: String, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyDiagnosticText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CopyTextTarget(text: text)
        return item
    }

    @objc private func copyDiagnosticText(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CopyTextTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.text, forType: .string)
    }

    private func addRuntimeState(from snapshot: ItemRuntimeSnapshot, to menu: NSMenu) {
        menu.addItem(disabledItem(title: "State: \(snapshot.status.rawValue)"))
        menu.addItem(disabledItem(title: snapshot.fullOutput.map { "Value: \($0)" } ?? "Value: unavailable"))
        menu.addItem(disabledItem(title: "Last attempt: \(snapshot.lastAttemptedAt.map(formatTimestamp) ?? "unavailable")"))
        menu.addItem(disabledItem(title: "Last success: \(snapshot.lastUpdatedAt.map(formatTimestamp) ?? "unavailable")"))
        menu.addItem(disabledItem(title: "Stale: \(snapshot.isStale ? "yes" : "no")"))
        if let duration = snapshot.lastRunDuration {
            menu.addItem(disabledItem(title: String(format: "Last duration: %.3fs", duration)))
        }
        if let exitStatus = snapshot.exitStatus {
            menu.addItem(disabledItem(title: "Last exit: \(exitStatus)"))
        }
        if let errorSummary = snapshot.errorSummary {
            menu.addItem(disabledItem(title: "Error: \(errorSummary)"))
        }
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
        guard let target = sender.representedObject as? RefreshActionTarget else { return }
        target.item.refreshNow()
    }

    @objc private func itemAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ItemActionTarget else { return }
        target.item.invokeAction(at: target.index)
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
