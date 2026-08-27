import AppKit
import PinchosCore

/// The native status item for a `[group.<name>]` config entry.
///
/// A group has no primary command of its own to run, schedule, or click --
/// unlike `ManagedItem`, its `NSStatusItem` exists purely as a fixed anchor
/// for a menu. `StatusItemController` builds that menu (see
/// `addGroupContent`), reading each member's live `ManagedItemLifecycle`
/// directly out of its own `items` dictionary rather than this class
/// knowing anything about its siblings. This keeps `ManagedGroupItem`'s own
/// lifecycle trivial: its config only ever changes `title`/`members`/`icon`/`symbol`,
/// none of which require quiescing any in-flight work, so `prepareUpdate`
/// has nothing to await before `commitPreparedUpdate` can apply it.
///
/// See README "Groups" for the summary-title and member-visibility policy.
@MainActor
final class ManagedGroupItem: ManagedItemLifecycle {
    let statusItem: NSStatusItem?
    private(set) var groupConfig: GroupItemConfig
    var config: ItemConfig { .group(groupConfig) }
    var actions: [ItemAction] { [] }
    private(set) var iconDiagnosticNote: String?
    private let iconRenderer: StatusItemIconRenderer
    private weak var menuDelegate: StatusItemMenuDelegate?
    private var isActive = true
    private var pendingGroupConfig: GroupItemConfig?

    init(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool = true,
        isTopLevel: Bool = true,
        iconRenderer: StatusItemIconRenderer = .system,
        statusItemFactory: @escaping () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
    ) {
        let groupConfig = config.group
        self.groupConfig = groupConfig
        self.menuDelegate = menuDelegate
        self.iconRenderer = iconRenderer
        // A group that is itself a hidden member of some other group (nested
        // groups) gets no real backing `NSStatusItem` at all, mirroring
        // `ManagedItem`'s `isTopLevel` handling -- there is nothing to ever
        // reveal, so every `statusItem?.` access below and elsewhere in this
        // class simply no-ops.
        let statusItem = isTopLevel ? statusItemFactory() : nil
        self.statusItem = statusItem
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleClick)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyTitle()
        applyIcon()
        statusItem?.isVisible = initiallyVisible
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        guard let ownedStatusItem = self.statusItem else { return false }
        return ownedStatusItem === statusItem
    }

    func activate() {
        guard isActive else { return }
        statusItem?.isVisible = true
    }

    /// A group has no click-through command or refresh-on-click of its own,
    /// so both left- and right-click always reveal the member dropdown --
    /// there is no other useful action for either mouse button to take.
    @objc private func handleClick() {
        guard let statusItem else { return }
        menuDelegate?.showLifecycleMenu(for: statusItem)
    }

    func prepareUpdate(config: ItemConfig, deadline: ContinuousClock.Instant) async {
        guard isActive, case .group(let newGroupConfig) = config else { return }
        pendingGroupConfig = newGroupConfig
    }

    func commitPreparedUpdate() {
        guard let pendingGroupConfig else { return }
        groupConfig = pendingGroupConfig
        self.pendingGroupConfig = nil
        applyTitle()
        applyIcon()
    }

    func prepareRemoval(deadline: ContinuousClock.Instant) async {
        isActive = false
    }

    func commitRemoval() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func tearDown(deadline: ContinuousClock.Instant) async {
        await prepareRemoval(deadline: deadline)
        commitRemoval()
    }

    /// Groups have no runner of their own; every snapshot below reports the
    /// same "unavailable" shape a command item would report before its
    /// first run, since `ManagedItemLifecycle` is one protocol shared by
    /// both item kinds (see `StatusItemController.addMenuContent`, which
    /// dispatches on `config.kind` before ever calling these).
    func runnerSnapshot() async -> CommandRunnerSnapshot {
        CommandRunnerSnapshot(isRunning: false, lastExecution: nil, skippedRefreshes: 0)
    }

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        ItemRuntimeSnapshot(
            isRunning: false,
            fullOutput: nil,
            lastAttemptedAt: nil,
            lastUpdatedAt: nil,
            lastExecution: nil,
            staleAfter: nil,
            skippedRefreshes: 0,
            now: Date()
        )
    }

    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot? { nil }
    func clickSnapshot() async -> ClickDiagnosticsSnapshot? { nil }
    func invokeAction(at index: Int) {}
    func refreshNow() {}

    private func applyTitle() {
        statusItem?.button?.title = groupConfig.title
    }

    private func applyIcon() {
        let rendered = iconRenderer.render(groupConfig.iconSource)
        iconRenderer.apply(rendered, to: statusItem?.button)
        iconDiagnosticNote = rendered.diagnosticNote
    }
}
