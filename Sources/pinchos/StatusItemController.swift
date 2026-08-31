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
    var actions: [ItemAction] { get }
    var iconDiagnosticNote: String? { get }
    var isVisible: Bool { get }
    func owns(statusItem: NSStatusItem) -> Bool
    func activate()
    func setStatusItemVisible(_ visible: Bool)
    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async
    func commitPreparedUpdate()
    func prepareRemoval(deadline: ContinuousClock.Instant) async
    func commitRemoval()
    func tearDown(deadline: ContinuousClock.Instant) async
    func runnerSnapshot() async -> CommandRunnerSnapshot
    func runtimeSnapshot() async -> ItemRuntimeSnapshot
    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot?
    func invokeAction(at index: Int)
    func refreshNow()
}

@MainActor
protocol ManagedItemFactory: AnyObject {
    /// `isTopLevel` is `false` exactly when `name` is a member of some
    /// group (see `PinchosConfig.hiddenMemberNames`): the created instance
    /// then gets no real backing `NSStatusItem` at all, since it must never
    /// occupy its own menu-bar slot alongside the group(s) that reference
    /// it. It still runs its schedule and is reachable by name from a
    /// group's menu.
    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool,
        isTopLevel: Bool
    ) -> any ManagedItemLifecycle
}

@MainActor
private final class DefaultManagedItemFactory: ManagedItemFactory {
    private let scheduler: CommandScheduler
    private let notificationSink: ItemNotificationSink

    init(scheduler: CommandScheduler, notificationSink: ItemNotificationSink) {
        self.scheduler = scheduler
        self.notificationSink = notificationSink
    }

    func make(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool,
        isTopLevel: Bool
    ) -> any ManagedItemLifecycle {
        switch config {
        case .command:
            return ManagedItem(
                config: config,
                menuDelegate: menuDelegate,
                initiallyVisible: initiallyVisible,
                isTopLevel: isTopLevel,
                scheduler: scheduler,
                notificationSink: notificationSink
            )
        case .group:
            return ManagedGroupItem(
                config: config,
                menuDelegate: menuDelegate,
                initiallyVisible: initiallyVisible,
                isTopLevel: isTopLevel
            )
        }
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
private final class HideActionTarget: NSObject {
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
    private enum BarPresentation {
        case expanded
        case collapsed
    }

    private let itemFactory: any ManagedItemFactory
    private let statusItemHost: any StatusItemHost
    /// The one application-scoped `CommandScheduler` shared by every
    /// `ManagedItem` this controller owns (see `README.md`'s "Scheduler"
    /// section for the bounded-concurrency/fairness/diagnostics policy).
    /// Exposed at `internal` access for scheduler-integration tests in this
    /// module; a custom `itemFactory` injected for testing (e.g. a fake)
    /// may simply not route work through it, in which case it sits idle.
    let scheduler: CommandScheduler
    private var items: [String: any ManagedItemLifecycle] = [:]
    private var order: [String] = []
    private var warningItem: NSStatusItem?
    private var collapsedStatusItem: NSStatusItem?
    private var collapsedMenuGeneration = 0
    private var barPresentation: BarPresentation = .expanded
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
        let resolvedScheduler = scheduler ?? CommandScheduler()
        self.scheduler = resolvedScheduler
        self.statusItemHost = statusItemHost ?? SystemStatusItemHost()
        self.itemFactory = itemFactory ?? DefaultManagedItemFactory(
            scheduler: resolvedScheduler,
            notificationSink: SystemItemNotificationSink()
        )
        self.configPath = configPath
        self.onReload = onReload
    }

    func apply(config: PinchosConfig) async {
        await enqueueLifecycleOperation { [weak self] in
            await self?.applyNow(config: config)
        }
    }

    private func applyNow(config: PinchosConfig) async {
        collapsedMenuGeneration += 1
        // Always applied, independent of the item diff below: a config
        // reload that only touches `[scheduler]` (no item changes) must
        // still take effect.
        await scheduler.updateMaxActiveSessions(
            config.scheduler.maxActiveSessions ?? CommandScheduler.defaultMaxActiveSessions
        )
        let old = currentConfig()
        let diff = ConfigDiffEngine.diff(old: old, new: config)
        recoveryState.apply(config: config)
        if recoveryState.isVisible {
            updateRecoveryItem()
        } else {
            clearWarningItem()
        }
        if !diff.isEmpty {
            await apply(diff: diff, config: config)
        }
        synchronizeCollapsedVisibility()
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
        if barPresentation == .collapsed {
            warningItem?.isVisible = false
            return
        }
        if warningItem == nil {
            guard let statusItem = statusItemHost.makeStatusItem() else { return }
            statusItem.button?.target = self
            statusItem.button?.action = #selector(handleWarningClick)
            statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            warningItem = statusItem
        }
        warningItem?.button?.title = recoveryState.errorDescription == nil
            ? "pinchos"
            : "pinchos \u{26A0}\u{FE0E}"
    }

    /// A plain left/right click shows the compact menu (actions, one summary
    /// line, Hide, and the global items). Holding Option while clicking reveals
    /// the full diagnostics menu instead -- the same way Option-clicking the
    /// system WiFi item shows signal details.
    func showLifecycleMenu(for statusItem: NSStatusItem) {
        let revealsDiagnostics = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let menu = if self.collapsedStatusItem === statusItem {
                await self.makeCollapsedMenu(revealsDiagnostics: revealsDiagnostics)
            } else {
                await self.makeLifecycleMenu(for: statusItem, revealsDiagnostics: revealsDiagnostics)
            }
            self.present(menu: menu, on: statusItem)
        }
    }

    private func currentConfig() -> PinchosConfig {
        PinchosConfig(items: order.compactMap { items[$0]?.config })
    }

    private func rebuild(with config: PinchosConfig) async {
        let oldItems = order.compactMap { items[$0] }
        let deadline = LifecycleDeadline.makeInstant()
        await withTaskGroup(of: Void.self) { group in
            for item in oldItems {
                group.addTask { @MainActor in await item.prepareRemoval(deadline: deadline) }
            }
        }
        let hidden = config.hiddenMemberNames
        // NSStatusBar grows its collection from the right-side anchor toward
        // the left, so creating items in reverse declaration order makes the
        // rendered menu bar read left-to-right like the TOML file.
        let newItems = config.items.reversed().map {
            itemFactory.make(config: $0, menuDelegate: self, initiallyVisible: false, isTopLevel: !hidden.contains($0.name))
        }

        for item in oldItems {
            item.commitRemoval()
        }
        items = Dictionary(uniqueKeysWithValues: newItems.map { ($0.config.name, $0) })
        order = config.items.map(\.name)
        for item in newItems.reversed() {
            item.activate()
        }
    }

    private func apply(diff: ConfigDiff, config: PinchosConfig) async {
        if diff.requiresNativeRebuild {
            await rebuild(with: config)
            return
        }

        let hidden = config.hiddenMemberNames
        // Newly-created status items appear at the visual left edge. Reverse
        // the desired added sequence so multiple prefix additions retain
        // declaration order after AppKit inserts each one.
        let addedItems = diff.added.reversed().map {
            itemFactory.make(config: $0, menuDelegate: self, initiallyVisible: false, isTopLevel: !hidden.contains($0.name))
        }

        // Quiescing and cancellation for every changed and removed item is
        // fired and awaited under one shared, monotonic deadline instead of
        // one item at a time, so total wait time is bounded by the deadline
        // plus small coordination overhead rather than by item count.
        let deadline = LifecycleDeadline.makeInstant()
        await withTaskGroup(of: Void.self) { group in
            for changedConfig in diff.changed {
                if let item = items[changedConfig.name] {
                    group.addTask { @MainActor in
                        await item.prepareUpdate(config: changedConfig, deadline: deadline)
                    }
                }
            }
            for name in diff.removed {
                if let item = items[name] {
                    group.addTask { @MainActor in await item.prepareRemoval(deadline: deadline) }
                }
            }
        }

        let removedItems = diff.removed.compactMap { items.removeValue(forKey: $0) }
        for item in removedItems {
            item.commitRemoval()
        }
        for item in diff.changed {
            items[item.name]?.commitPreparedUpdate()
        }
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
        let itemsToTearDown = order.compactMap { items[$0] }
        await withTaskGroup(of: Void.self) { group in
            for item in itemsToTearDown {
                group.addTask { @MainActor in await item.tearDown(deadline: deadline) }
            }
        }
        items.removeAll()
        order.removeAll()
        clearWarningItem()
        removeCollapsedStatusItem()
        barPresentation = .expanded
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

    private func synchronizeCollapsedVisibility() {
        guard barPresentation == .collapsed else { return }
        warningItem?.isVisible = false
        for item in items.values {
            item.setStatusItemVisible(false)
        }
    }

    private func restoreExpandedVisibility() {
        warningItem?.isVisible = recoveryState.isVisible
        for item in items.values {
            item.setStatusItemVisible(true)
        }
    }

    private func installCollapsedStatusItem() -> Bool {
        guard collapsedStatusItem == nil, let statusItem = statusItemHost.makeStatusItem() else {
            return collapsedStatusItem != nil
        }
        let image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinchos")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Pinchos"
        statusItem.button?.setAccessibilityLabel("Pinchos")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleCollapsedClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        collapsedStatusItem = statusItem
        collapsedMenuGeneration += 1
        return true
    }

    private func removeCollapsedStatusItem() {
        if let collapsedStatusItem {
            statusItemHost.removeStatusItem(collapsedStatusItem)
        }
        collapsedStatusItem = nil
        collapsedMenuGeneration += 1
    }

    @objc private func collapseAction() {
        guard barPresentation == .expanded else { return }
        guard installCollapsedStatusItem() else { return }
        barPresentation = .collapsed
        synchronizeCollapsedVisibility()
    }

    @objc private func expandAction() {
        guard barPresentation == .collapsed else { return }
        barPresentation = .expanded
        restoreExpandedVisibility()
        removeCollapsedStatusItem()
        updateRecoveryItem()
    }

    @objc private func handleCollapsedClick() {
        _ = requestCollapsedMenu()
    }

    @discardableResult
    func requestCollapsedMenu() -> Task<Void, Never>? {
        guard barPresentation == .collapsed, let collapsedStatusItem else { return nil }
        let revealsDiagnostics = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let menuGeneration = collapsedMenuGeneration
        return Task { @MainActor [weak self, collapsedStatusItem, menuGeneration, revealsDiagnostics] in
            guard let self else { return }
            let menu = await self.makeCollapsedMenu(revealsDiagnostics: revealsDiagnostics)
            guard self.barPresentation == .collapsed,
                  self.collapsedStatusItem === collapsedStatusItem,
                  self.collapsedMenuGeneration == menuGeneration else { return }
            self.present(menu: menu, on: collapsedStatusItem)
        }
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

    func makeLifecycleMenu(for statusItem: NSStatusItem?, revealsDiagnostics: Bool = true) async -> NSMenu {
        let item = statusItem.flatMap { statusItem in
            items.values.first(where: { $0.owns(statusItem: statusItem) })
        }
        return await makeLifecycleMenu(forManagedItem: item, revealsDiagnostics: revealsDiagnostics)
    }

    func makeLifecycleMenu(forManagedItem item: (any ManagedItemLifecycle)?, revealsDiagnostics: Bool = true) async -> NSMenu {
        let menu = NSMenu()
        if let item {
            await addMenuContent(for: item, to: menu, revealsDiagnostics: revealsDiagnostics)
        }
        menu.addItem(makePresentationMenuItem())
        await addGlobalMenuContent(to: menu, includesSchedulerDiagnostics: revealsDiagnostics)
        return menu
    }

    func makeCollapsedMenu(revealsDiagnostics: Bool = true) async -> NSMenu {
        let menu = NSMenu()
        let topLevelItems = topLevelManagedItems()
        for item in topLevelItems {
            let submenu = await makeLifecycleMenu(forManagedItem: item, revealsDiagnostics: revealsDiagnostics)
            let row = NSMenuItem(title: await collapsedTitle(for: item), action: nil, keyEquivalent: "")
            row.submenu = submenu
            menu.addItem(row)
        }
        if topLevelItems.isEmpty {
            menu.addItem(disabledItem(title: "No visible Pinchos"))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makePresentationMenuItem())
        await addGlobalMenuContent(to: menu, includesSchedulerDiagnostics: revealsDiagnostics)
        return menu
    }

    private func topLevelManagedItems() -> [any ManagedItemLifecycle] {
        let topLevelNames = Set(currentConfig().topLevelItems.map(\.name))
        return order.compactMap { name in
            guard topLevelNames.contains(name), let item = items[name], item.isVisible else { return nil }
            return item
        }
    }

    private func collapsedTitle(for item: any ManagedItemLifecycle) async -> String {
        switch item.config {
        case .command:
            let snapshot = await item.runtimeSnapshot()
            let value = if let structuredText = snapshot.structuredOutput?.text {
                DiagnosticPreviewFormatter.preview(structuredText, limits: .menuValue).text
            } else {
                snapshot.fullOutput.map { lastTrimmedLine(of: $0) } ?? ""
            }
            return value.isEmpty ? item.config.name : "\(item.config.name): \(truncateTitle(value, maxLength: 40))"
        case .group(let group):
            return group.title
        }
    }

    private func makePresentationMenuItem() -> NSMenuItem {
        let title: String
        let selector: Selector
        switch barPresentation {
        case .expanded:
            title = "Collapse Pinchos"
            selector = #selector(collapseAction)
        case .collapsed:
            title = "Expand Pinchos"
            selector = #selector(expandAction)
        }
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func addGlobalMenuContent(to menu: NSMenu, includesSchedulerDiagnostics: Bool = true) async {
        if includesSchedulerDiagnostics {
            await addSchedulerDiagnostics(to: menu)
        } else {
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
    }

    /// Dispatches on `item.config`'s kind so a command item's own status-item
    /// menu and a group's per-member submenu (see `addGroupContent`) share
    /// exactly one implementation of "what a command item's menu contains" --
    /// nesting falls out for free, since a group member that is itself a
    /// group recurses back into `addGroupContent`.
    private func addMenuContent(
        for item: any ManagedItemLifecycle,
        to menu: NSMenu,
        revealsDiagnostics: Bool
    ) async {
        switch item.config {
        case .command(let commandConfig):
            await addCommandContent(item: item, commandConfig: commandConfig, to: menu, revealsDiagnostics: revealsDiagnostics)
        case .group(let group):
            await addGroupContent(group, to: menu, revealsDiagnostics: revealsDiagnostics)
        }

        if !item.config.hidden {
            menu.addItem(NSMenuItem.separator())
            let hide = NSMenuItem(title: "Hide", action: #selector(hideAction(_:)), keyEquivalent: "")
            hide.target = self
            hide.representedObject = HideActionTarget(item: item)
            menu.addItem(hide)
        }
        menu.addItem(NSMenuItem.separator())
    }

    private func addCommandContent(
        item: any ManagedItemLifecycle,
        commandConfig: CommandItemConfig,
        to menu: NSMenu,
        revealsDiagnostics: Bool
    ) async {
        let run = NSMenuItem(
            title: "Run \(commandConfig.name)",
            action: #selector(refreshAction(_:)),
            keyEquivalent: ""
        )
        run.target = self
        run.representedObject = RefreshActionTarget(item: item)
        run.isEnabled = !commandConfig.disabled
        menu.addItem(run)

        var hasConfiguredRefresh = false
        for (index, action) in item.actions.enumerated() {
            let menuItem = NSMenuItem(title: action.title, action: #selector(itemAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = ItemActionTarget(item: item, index: index)
            menuItem.isEnabled = !commandConfig.disabled
            menu.addItem(menuItem)
            if case .refresh = action.kind {
                hasConfiguredRefresh = true
            }
        }
        if !hasConfiguredRefresh {
            let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction(_:)), keyEquivalent: "")
            refresh.target = self
            refresh.representedObject = RefreshActionTarget(item: item)
            refresh.isEnabled = !commandConfig.disabled
            menu.addItem(refresh)
        }
        menu.addItem(NSMenuItem.separator())
        let runtime = await item.runtimeSnapshot()
        if revealsDiagnostics {
            addRuntimeState(from: runtime, to: menu)
            if let note = item.iconDiagnosticNote {
                menu.addItem(disabledItem(title: "Icon: \(note)"))
            }
            menu.addItem(NSMenuItem.separator())
            addDiagnostics(from: runtime.runnerSnapshot, to: menu)
            var actionSnapshots: [(index: Int, snapshot: CommandRunnerSnapshot?)] = []
            for index in item.actions.indices {
                actionSnapshots.append((index: index, snapshot: await item.actionSnapshot(at: index)))
            }
            if actionSnapshots.contains(where: { $0.snapshot != nil }) {
                menu.addItem(NSMenuItem.separator())
                addActionDiagnostics(actions: item.actions, snapshots: actionSnapshots, to: menu)
            }
            if commandConfig.disabled {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(disabledItem(title: "Disabled: yes"))
            }
        } else {
            menu.addItem(disabledItem(title: compactSummaryTitle(from: runtime, commandConfig: commandConfig)))
        }
    }

    /// The single line the compact (non-Option) menu shows in place of the
    /// full runtime-state and diagnostics sections: the item's current value
    /// plus a terse status qualifier, mirroring the summary line of the
    /// interactive design mockup. No timestamps, byte counts, or other
    /// diagnostics appear here -- Option-click reveals those.
    private func compactSummaryTitle(from snapshot: ItemRuntimeSnapshot, commandConfig: CommandItemConfig) -> String {
        let value: String
        if let structuredText = snapshot.structuredOutput?.text {
            value = DiagnosticPreviewFormatter.preview(structuredText, limits: .menuValue).text
        } else if let fullOutput = snapshot.fullOutput {
            value = DiagnosticPreviewFormatter.preview(fullOutput, limits: .menuValue).text
        } else {
            value = ""
        }
        switch snapshot.status {
        case .fresh:
            return value.isEmpty ? "Fresh" : value
        case .running:
            return value.isEmpty ? "Running\u{2026}" : "\(value) \u{b7} refreshing"
        case .warning:
            return value.isEmpty ? "Warning" : "\(value) \u{b7} warning"
        case .stale:
            return value.isEmpty ? "Stale" : "\(value) \u{b7} stale"
        case .error, .unavailable:
            if value.isEmpty {
                return commandConfig.onError == .keepLast ? "Failed" : commandConfig.errorText
            }
            return "\(value) \u{b7} failed \u{b7} showing last good value"
        }
    }

    /// A group's own status item shows only the static, config-declared
    /// `title` (see `ManagedGroupItem`) -- this menu is where its live
    /// content lives instead. The header line is the one place the compact
    /// join of member values (the "group summary title" from the grouped
    /// status items design) appears; it is recomputed fresh every time this
    /// menu is opened, so it never needs its own change-notification path
    /// from a member back to its group(s). Each member then gets one row
    /// with a submenu holding exactly what that member's own status-item
    /// menu would show (actions, current value/state, diagnostics, manual
    /// refresh) -- nothing about a member's presentation changes because it
    /// is being shown inside a group instead of at the top level.
    private func addGroupContent(_ group: GroupItemConfig, to menu: NSMenu, revealsDiagnostics: Bool) async {
        var memberEntries: [(name: String, item: any ManagedItemLifecycle, valuePreview: String)] = []
        for memberName in group.members {
            guard let member = items[memberName], !member.config.hidden else { continue }
            let preview: String
            switch member.config {
            case .command:
                let snapshot = await member.runtimeSnapshot()
                let value = if let structuredText = snapshot.structuredOutput?.text {
                    DiagnosticPreviewFormatter.preview(structuredText, limits: .menuValue).text
                } else {
                    snapshot.fullOutput.map { lastTrimmedLine(of: $0) } ?? ""
                }
                preview = value.isEmpty ? "\u{2013}" : value
            case .group(let nested):
                preview = nested.title
            }
            memberEntries.append((memberName, member, preview))
        }

        menu.addItem(disabledItem(title: groupSummaryTitle(group, entries: memberEntries)))
        if revealsDiagnostics, let note = items[group.name]?.iconDiagnosticNote {
            menu.addItem(disabledItem(title: "Icon: \(note)"))
        }
        menu.addItem(NSMenuItem.separator())
        for entry in memberEntries {
            let submenu = NSMenu()
            await addMenuContent(for: entry.item, to: submenu, revealsDiagnostics: revealsDiagnostics)
            submenu.addItem(makePresentationMenuItem())
            let memberItem = NSMenuItem(
                title: "\(entry.name): \(truncateTitle(entry.valuePreview, maxLength: 40))",
                action: nil,
                keyEquivalent: ""
            )
            memberItem.submenu = submenu
            menu.addItem(memberItem)
        }
    }

    private func groupSummaryTitle(
        _ group: GroupItemConfig,
        entries: [(name: String, item: any ManagedItemLifecycle, valuePreview: String)]
    ) -> String {
        guard !entries.isEmpty else { return group.title }
        let joined = entries.map { truncateTitle($0.valuePreview, maxLength: 20) }.joined(separator: " \u{b7} ")
        return "\(group.title): \(truncateTitle(joined, maxLength: 80))"
    }

    /// A light-touch, always-present line surfacing the one application-scoped
    /// `CommandScheduler`'s global saturation, independent of which (if any)
    /// item's lifecycle menu is showing. Only mentions queued/coalesced/
    /// delayed counts when they are non-zero so the common, unsaturated case
    /// stays a single short line.
    private func addSchedulerDiagnostics(to menu: NSMenu) async {
        let diagnostics = await scheduler.diagnostics()
        var title = "Scheduler: \(diagnostics.activeSessions)/\(diagnostics.maxActiveSessions) active"
        if diagnostics.queuedSessions > 0 {
            title += ", \(diagnostics.queuedSessions) queued"
        }
        if diagnostics.coalescedCount > 0 {
            title += ", \(diagnostics.coalescedCount) coalesced"
        }
        if diagnostics.delayedAcquisitions > 0 {
            title += ", \(diagnostics.delayedAcquisitions) delayed"
        }
        menu.addItem(disabledItem(title: title))
        menu.addItem(NSMenuItem.separator())
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
                        menu.addItem(launchFailurePreviewItem(prefix: actionPrefix + "launch: ", fullText: message))
                    }
                }
                let stderrLine = lastTrimmedLine(of: execution.stderr)
                if !stderrLine.isEmpty {
                    menu.addItem(stderrPreviewItem(prefix: actionPrefix + "stderr: ", fullText: stderrLine))
                }
                if !execution.stdout.isEmpty {
                    menu.addItem(copyItem(title: "Copy \"\(title)\" Output", text: execution.stdout))
                }
                if !execution.stderr.isEmpty {
                    menu.addItem(copyItem(title: "Copy \"\(title)\" Error", text: execution.stderr))
                }
            }
            if snapshot.skippedRefreshes > 0 {
                menu.addItem(disabledItem(title: actionPrefix + "skipped invocations: \(snapshot.skippedRefreshes)"))
            }
        }
    }

    private func copyItem(title: String, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(copyDiagnosticText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = CopyTextTarget(text: text)
        item.setAccessibilityHelp("Copies the complete retained text to the clipboard, unabridged.")
        return item
    }

    @objc private func copyDiagnosticText(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? CopyTextTarget else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target.text, forType: .string)
    }

    private func addRuntimeState(from snapshot: ItemRuntimeSnapshot, to menu: NSMenu) {
        menu.addItem(disabledItem(title: "State: \(snapshot.status.rawValue)"))
        if let fullOutput = snapshot.fullOutput {
            menu.addItem(valuePreviewItem(prefix: "Value: ", fullText: fullOutput))
        } else {
            menu.addItem(disabledItem(title: "Value: unavailable"))
        }
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
            menu.addItem(stderrPreviewItem(prefix: "Error: ", fullText: errorSummary))
        }
        if let fullOutput = snapshot.fullOutput, !fullOutput.isEmpty {
            menu.addItem(copyItem(title: "Copy Full Output", text: fullOutput))
        }
        if let stderr = snapshot.lastExecution?.stderr, !stderr.isEmpty {
            menu.addItem(copyItem(title: "Copy Full Error", text: stderr))
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
                    menu.addItem(launchFailurePreviewItem(prefix: "launch: ", fullText: message))
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
                menu.addItem(stderrPreviewItem(prefix: "stderr: ", fullText: stderrLine))
            }
        }
        menu.addItem(disabledItem(title: "Skipped ticks: \(snapshot.skippedRefreshes)"))
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Builds a disabled, bounded-preview diagnostics line under `limits`
    /// and, when the preview is truncated, an accessibility label/help pair
    /// that names the true byte/line totals so VoiceOver doesn't have to
    /// read a truncation marker embedded in the visible title.
    private func previewItem(prefix: String, fullText: String, limits: DiagnosticPreviewFormatter.Limits) -> NSMenuItem {
        let preview = DiagnosticPreviewFormatter.preview(fullText, limits: limits)
        let item = disabledItem(title: prefix + preview.text)
        if preview.isTruncated {
            item.setAccessibilityLabel(prefix.trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
            item.setAccessibilityHelp("Truncated preview; use the corresponding Copy action for the full text.")
        }
        return item
    }

    private func valuePreviewItem(prefix: String, fullText: String) -> NSMenuItem {
        previewItem(prefix: prefix, fullText: fullText, limits: .menuValue)
    }

    private func stderrPreviewItem(prefix: String, fullText: String) -> NSMenuItem {
        previewItem(prefix: prefix, fullText: fullText, limits: .menuStderr)
    }

    private func launchFailurePreviewItem(prefix: String, fullText: String) -> NSMenuItem {
        previewItem(prefix: prefix, fullText: fullText, limits: .actionDiagnostics)
    }

    private func present(menu: NSMenu, on statusItem: NSStatusItem) {
        statusItemHost.present(menu: menu, on: statusItem)
    }

    @objc private func refreshAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? RefreshActionTarget else { return }
        target.item.refreshNow()
    }

    @objc private func hideAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? HideActionTarget,
              !target.item.config.hidden else { return }
        do {
            try ConfigFileEditor.setHidden(
                true,
                for: target.item.config,
                at: URL(fileURLWithPath: configPath)
            )
            onReload()
        } catch {
            showRecoveryError(error)
        }
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
