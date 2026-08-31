import AppKit
import PinchosCore

@MainActor
protocol StatusItemMenuDelegate: AnyObject {
    func showLifecycleMenu(for statusItem: NSStatusItem)
}

@MainActor
protocol StatusItemHost: AnyObject {
    func makeStatusItem() -> NSStatusItem?
    func removeStatusItem(_ statusItem: NSStatusItem)
    func present(menu: NSMenu, on statusItem: NSStatusItem)
}

@MainActor
private final class SystemStatusItemHost: StatusItemHost {
    func makeStatusItem() -> NSStatusItem? {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func removeStatusItem(_ statusItem: NSStatusItem) {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func present(menu: NSMenu, on statusItem: NSStatusItem) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

@MainActor
protocol ManagedItemLifecycle: AnyObject {
    var config: ItemConfig { get }
    var iconDiagnosticNote: String? { get }
    var cachedRuntimeSnapshot: ItemRuntimeSnapshot { get }
    func owns(statusItem: NSStatusItem) -> Bool
    func activate()
    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async
    func commitPreparedUpdate()
    func prepareRemoval(deadline: ContinuousClock.Instant) async
    func commitRemoval()
    func tearDown(deadline: ContinuousClock.Instant) async
    func runnerSnapshot() async -> CommandRunnerSnapshot
    func runtimeSnapshot() async -> ItemRuntimeSnapshot
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
    private let scheduler: CommandScheduler

    init(scheduler: CommandScheduler) {
        self.scheduler = scheduler
    }

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool
    ) -> any ManagedItemLifecycle {
        ManagedItem(
            config: config,
            menuDelegate: menuDelegate,
            initiallyVisible: initiallyVisible,
            scheduler: scheduler
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
    init(item: any ManagedItemLifecycle) { self.item = item }
}

@MainActor
private final class CopyTextTarget: NSObject {
    let text: String
    init(text: String) { self.text = text }
}

@MainActor
final class StatusItemController: StatusItemMenuDelegate {
    private let itemFactory: any ManagedItemFactory
    private let statusItemHost: any StatusItemHost
    let scheduler: CommandScheduler

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
        itemFactory: (any ManagedItemFactory)? = nil,
        scheduler: CommandScheduler? = nil,
        statusItemHost: (any StatusItemHost)? = nil
    ) {
        let scheduler = scheduler ?? CommandScheduler()
        self.scheduler = scheduler
        self.itemFactory = itemFactory ?? DefaultManagedItemFactory(scheduler: scheduler)
        self.statusItemHost = statusItemHost ?? SystemStatusItemHost()
        self.configPath = configPath
        self.onReload = onReload
    }

    func apply(config: PinchosConfig) async {
        await enqueueLifecycleOperation { [weak self] in
            await self?.applyNow(config: config)
        }
    }

    private func applyNow(config: PinchosConfig) async {
        let diff = ConfigDiffEngine.diff(old: currentConfig(), new: config)
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
            guard let statusItem = statusItemHost.makeStatusItem() else { return }
            statusItem.button?.target = self
            statusItem.button?.action = #selector(handleWarningClick)
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            warningItem = statusItem
        }
        warningItem?.button?.title = recoveryState.errorDescription == nil
            ? "pinchos"
            : "pinchos ⚠︎"
    }

    /// Plain click shows the compact operating menu. Option-click adds cached
    /// runtime diagnostics without starting any command.
    func showLifecycleMenu(for statusItem: NSStatusItem) {
        let revealsDiagnostics = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let item = items.values.first(where: { $0.owns(statusItem: statusItem) })
        let menu = makeMenu(
            for: item,
            snapshot: item?.cachedRuntimeSnapshot,
            revealsDiagnostics: revealsDiagnostics
        )
        statusItemHost.present(menu: menu, on: statusItem)
    }

    private func currentConfig() -> PinchosConfig {
        PinchosConfig(items: order.compactMap { items[$0]?.config })
    }

    private func rebuild(with config: PinchosConfig) async {
        let oldItems = order.compactMap { items[$0] }
        let deadline = LifecycleDeadline.makeInstant()
        await withTaskGroup(of: Void.self) { group in
            for item in oldItems {
                group.addTask { @MainActor in
                    await item.prepareRemoval(deadline: deadline)
                }
            }
        }

        // NSStatusBar grows left from its anchor. Reverse creation makes the
        // final visual order match declaration order.
        let newItems = config.items.reversed().map {
            itemFactory.make(config: $0, menuDelegate: self, initiallyVisible: false)
        }

        for item in oldItems { item.commitRemoval() }
        items = Dictionary(uniqueKeysWithValues: newItems.map { ($0.config.name, $0) })
        order = config.items.map(\.name)
        for item in newItems.reversed() { item.activate() }
    }

    private func apply(diff: ConfigDiff, config: PinchosConfig) async {
        if diff.requiresNativeRebuild {
            await rebuild(with: config)
            return
        }

        let addedItems = diff.added.reversed().map {
            itemFactory.make(config: $0, menuDelegate: self, initiallyVisible: false)
        }
        let deadline = LifecycleDeadline.makeInstant()
        await withTaskGroup(of: Void.self) { group in
            for changed in diff.changed {
                if let item = items[changed.name] {
                    group.addTask { @MainActor in
                        await item.prepareUpdate(config: changed, deadline: deadline)
                    }
                }
            }
            for name in diff.removed {
                if let item = items[name] {
                    group.addTask { @MainActor in
                        await item.prepareRemoval(deadline: deadline)
                    }
                }
            }
        }

        let removedItems = diff.removed.compactMap { items.removeValue(forKey: $0) }
        for item in removedItems { item.commitRemoval() }
        for changed in diff.changed { items[changed.name]?.commitPreparedUpdate() }
        for item in addedItems.reversed() {
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
        let deadline = LifecycleDeadline.makeInstant()
        let liveItems = order.compactMap { items[$0] }
        await withTaskGroup(of: Void.self) { group in
            for item in liveItems {
                group.addTask { @MainActor in
                    await item.tearDown(deadline: deadline)
                }
            }
        }
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
            statusItemHost.removeStatusItem(warningItem)
        }
        warningItem = nil
        recoveryState.dismiss()
    }

    @objc private func handleWarningClick() {
        guard let warningItem else { return }
        statusItemHost.present(menu: buildRecoveryMenu(), on: warningItem)
    }

    private func buildRecoveryMenu() -> NSMenu {
        let menu = NSMenu()
        if let errorDescription = recoveryState.errorDescription {
            menu.addItem(previewItem(prefix: "", fullText: errorDescription, limits: .actionDiagnostics))
            menu.addItem(NSMenuItem.separator())
        }
        for action in recoveryState.menu.actions {
            let selector: Selector
            switch action {
            case .createExampleConfig: selector = #selector(createExampleConfigAction)
            case .openConfig: selector = #selector(openConfigAction)
            case .openConfigDirectory: selector = #selector(openConfigDirectoryAction)
            case .reload: selector = #selector(reloadConfigAction)
            case .quit: selector = #selector(quitAction)
            }
            let item = NSMenuItem(title: action.rawValue, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func makeLifecycleMenu(
        for statusItem: NSStatusItem?,
        revealsDiagnostics: Bool = true
    ) async -> NSMenu {
        let item = statusItem.flatMap { statusItem in
            items.values.first(where: { $0.owns(statusItem: statusItem) })
        }
        return await makeLifecycleMenu(forManagedItem: item, revealsDiagnostics: revealsDiagnostics)
    }

    func makeLifecycleMenu(
        forManagedItem item: (any ManagedItemLifecycle)?,
        revealsDiagnostics: Bool = true
    ) async -> NSMenu {
        let snapshot: ItemRuntimeSnapshot?
        if revealsDiagnostics, let item {
            snapshot = await item.runtimeSnapshot()
        } else {
            snapshot = nil
        }
        return makeMenu(for: item, snapshot: snapshot, revealsDiagnostics: revealsDiagnostics)
    }

    private func makeMenu(
        for item: (any ManagedItemLifecycle)?,
        snapshot: ItemRuntimeSnapshot?,
        revealsDiagnostics: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        if let item {
            let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction(_:)), keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = RefreshActionTarget(item: item)
            menu.addItem(refresh)

            if revealsDiagnostics, let snapshot {
                menu.addItem(NSMenuItem.separator())
                addRuntimeState(snapshot, iconDiagnosticNote: item.iconDiagnosticNote, to: menu)
            }
            menu.addItem(NSMenuItem.separator())
        }

        for (title, selector, key) in [
            ("Open Config", #selector(openConfigAction), ""),
            ("Reload Config", #selector(reloadConfigAction), "r"),
            ("Quit Pinchos", #selector(quitAction), "q"),
        ] {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            row.target = self
            menu.addItem(row)
        }
        return menu
    }

    private func addRuntimeState(
        _ snapshot: ItemRuntimeSnapshot,
        iconDiagnosticNote: String?,
        to menu: NSMenu
    ) {
        menu.addItem(disabledItem(title: "State: \(snapshot.status.rawValue)"))
        if let output = snapshot.fullOutput {
            menu.addItem(previewItem(prefix: "Value: ", fullText: output, limits: .menuValue))
            if !output.isEmpty {
                menu.addItem(copyItem(title: "Copy Full Output", text: output))
            }
        } else {
            menu.addItem(disabledItem(title: "Value: unavailable"))
        }
        menu.addItem(disabledItem(title: "Last attempt: \(snapshot.lastAttemptedAt.map(formatTimestamp) ?? "unavailable")"))
        menu.addItem(disabledItem(title: "Last success: \(snapshot.lastUpdatedAt.map(formatTimestamp) ?? "unavailable")"))
        if let duration = snapshot.lastRunDuration {
            menu.addItem(disabledItem(title: String(format: "Last duration: %.3fs", duration)))
        }
        if let exit = snapshot.exitStatus {
            menu.addItem(disabledItem(title: "Last exit: \(exit)"))
        }
        if let error = snapshot.errorSummary {
            menu.addItem(previewItem(prefix: "Error: ", fullText: error, limits: .menuStderr))
        }
        if let stderr = snapshot.lastExecution?.stderr, !stderr.isEmpty {
            menu.addItem(copyItem(title: "Copy Full Error", text: stderr))
        }
        if snapshot.skippedRefreshes > 0 {
            menu.addItem(disabledItem(title: "Skipped refreshes: \(snapshot.skippedRefreshes)"))
        }
        if let iconDiagnosticNote {
            menu.addItem(previewItem(prefix: "Icon: ", fullText: iconDiagnosticNote, limits: .actionDiagnostics))
        }
    }


    private func copyItem(title: String, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyDiagnosticText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CopyTextTarget(text: text)
        item.setAccessibilityHelp("Copies the complete retained text to the clipboard.")
        return item
    }

    @objc private func copyDiagnosticText(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CopyTextTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.text, forType: .string)
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func previewItem(
        prefix: String,
        fullText: String,
        limits: DiagnosticPreviewFormatter.Limits
    ) -> NSMenuItem {
        let preview = DiagnosticPreviewFormatter.preview(fullText, limits: limits)
        let item = disabledItem(title: prefix + preview.text)
        if preview.isTruncated {
            item.setAccessibilityHelp("Truncated preview; use Copy for the full text.")
        }
        return item
    }

    @objc private func refreshAction(_ sender: NSMenuItem) {
        (sender.representedObject as? RefreshActionTarget)?.item.refreshNow()
    }

    @objc private func reloadConfigAction() {
        onReload()
    }

    @objc private func createExampleConfigAction() {
        guard recoveryState.menu.canCreateExampleConfig else { return }
        do { try writeExampleConfig() } catch { showRecoveryError(error) }
    }

    func writeExampleConfig() throws {
        try ensureConfigDirectory()
        guard !FileManager.default.fileExists(atPath: configPath) else { return }
        guard let data = ExampleConfig.text.data(using: .utf8) else {
            throw RecoveryActionError.unableToCreateConfig
        }
        try data.write(to: URL(fileURLWithPath: configPath), options: [.withoutOverwriting])
    }

    @objc private func openConfigAction() {
        do { try openConfig() } catch { showRecoveryError(error) }
    }

    func openConfig() throws {
        try ensureConfigDirectory()
        if !FileManager.default.fileExists(atPath: configPath) {
            try Data().write(to: URL(fileURLWithPath: configPath), options: [.withoutOverwriting])
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) else {
            throw RecoveryActionError.unableToOpenConfig
        }
    }

    @objc private func openConfigDirectoryAction() {
        do { try openConfigDirectory() } catch { showRecoveryError(error) }
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
