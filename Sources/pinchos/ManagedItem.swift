import AppKit
import PinchosCore

private final class ManagedItemSourceClock: CommandSourceClock, @unchecked Sendable {
    private let read: () -> Date

    init(read: @escaping () -> Date) {
        self.read = read
    }

    func now() -> Date { read() }
}

@MainActor
final class ManagedItem: ManagedItemLifecycle {
    let statusItem: NSStatusItem?
    private(set) var renderedTitle: String
    private(set) var renderedButtonTitle: String = ""
    private(set) var isVisible = true
    private(set) var commandConfig: CommandItemConfig
    var config: ItemConfig { commandConfig }
    private(set) var menuRows: [MenuRowConfig]
    private(set) var actions: [ItemAction]
    private(set) var iconIsLoaded = false
    private(set) var iconDiagnosticNote: String?
    private let iconRenderer: StatusItemIconRenderer
    private var primarySource: CommandSource
    private var actionRunners: [Int: CommandRunner]
    private var menuRowRunners: [Int: CommandRunner]
    private var menuRowSources: [Int: CommandSource]
    private var primarySourceLease: CommandSourceLease
    private var menuRowSourceLeases: [Int: CommandSourceLease]
    private var menuRowCachedValues: [Int: String] = [:]
    private var menuRowLastAttemptedAt: [Int: Date] = [:]
    private var menuRowLastSuccessfulAt: [Int: Date] = [:]
    private var menuRowRefreshTasks: [Int: Task<Void, Never>] = [:]
    private var menuRowTimerTokens: [Int: CommandScheduler.ItemToken] = [:]
    private let sourceClock: ManagedItemSourceClock
    private let sourceRegistry: CommandSourceRegistry
    /// The one application-scoped `CommandScheduler` bounding this item's
    /// scheduled refreshes, manual refreshes, and command actions alongside
    /// every other item's, replacing the per-item `DispatchQueue`/
    /// `DispatchSourceTimer` this class used to own.
    private let scheduler: CommandScheduler
    private var refreshTimerToken: CommandScheduler.ItemToken?
    /// Tracks a refresh/action request while it is only queued for a
    /// global permit (not yet running). A second request arriving in that
    /// window coalesces into this one (see `recordCoalesced`) instead of
    /// enqueuing a second waiter, bounding the interactive/scheduled queue
    /// depth this item can contribute to at most one per work kind. Once a
    /// permit is granted the corresponding entry is cleared immediately
    /// (before the runner actually starts), so a request arriving while the
    /// command itself is running still reaches the runner's own no-overlap
    /// check and increments `skippedRefreshes` exactly as before.
    private var pendingRefreshPermitTask: Task<Void, Never>?
    private var pendingActionPermitTasks: [Int: Task<Void, Never>] = [:]
    private weak var menuDelegate: StatusItemMenuDelegate?
    private let now: () -> Date
    private var isActive = true
    private var configurationGeneration = 0
    private var isPreparingUpdate = false
    private var pendingUpdate: PendingUpdate?
    private var isPreparingRemoval = false
    private var pendingRefreshInvocations = 0
    private var refreshInvocationsDrained: CheckedContinuation<Void, Never>?
    private var pendingActionInvocations = 0
    private var actionInvocationsDrained: CheckedContinuation<Void, Never>?
    private var lastSuccessfulOutput: String?
    private var lastAttemptedAt: Date?
    private var lastUpdatedAt: Date?
    private var lastSuccessfulTitle: String?
    private var stalePresentationTask: Task<Void, Never>?
    private var statusItemSuppressed = false

    /// Test-only seam that pauses a queued action invocation after it has been
    /// accepted (bookkeeping incremented) but before it re-checks lifecycle state
    /// and touches its captured runner. This lets tests deterministically land a
    /// config reload or removal in the acceptance-to-start window without racing
    /// on timing. Production code always passes `nil`, so this is a no-op outside
    /// tests.
    var actionInvocationTestGate: (() async -> Void)?

    /// Test-only seam awaited alongside each runner's real cancellation during
    /// `prepareUpdate`/`prepareRemoval`, keyed by role ("primary" or
    /// "action:<index>"). Real runner cancellation is normally too fast to
    /// distinguish concurrent from sequential execution in a test; this lets
    /// tests inject a controllable settle time per role and prove that all
    /// roles for one item are cancelled concurrently -- every role starts
    /// before any role settles, rather than settling one after another.
    /// Production code always leaves this `nil`.
    var cancellationSettlementDelayForTesting: ((String) async -> Void)?

    /// Test-only observer invoked with the identities reported by
    /// `settleConcurrently` whenever a `prepareUpdate`/`prepareRemoval`
    /// cancellation phase misses its shared deadline.
    var lifecycleSettlementTimeoutHandlerForTesting: (([LifecycleSettlementTimeout]) -> Void)?

    private struct PendingUpdate {
        let commandConfig: CommandItemConfig
        let primarySource: CommandSource?
        let actionRunners: [Int: CommandRunner]?
        let menuRowRunners: [Int: CommandRunner]?
        let menuRowSources: [Int: CommandSource]?
        let primarySourceLease: CommandSourceLease?
        let menuRowSourceLeases: [Int: CommandSourceLease]?
        let actionRunnersConfigurationChanged: Bool
        let menuRowsChanged: Bool
        let timerNeedsRestart: Bool
        let presentationNeedsUpdate: Bool
        let staleAfterChanged: Bool
    }

    init(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool = true,
        scheduler: CommandScheduler = .shared,
        sourceRegistry: CommandSourceRegistry = CommandSourceRegistry(),
        now: @escaping () -> Date = Date.init,
        iconRenderer: StatusItemIconRenderer = .system,
        statusItemFactory: @escaping () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
    ) {
        let commandConfig = config
        self.commandConfig = commandConfig
        self.menuRows = commandConfig.menu
        self.actions = commandConfig.actions
        self.menuDelegate = menuDelegate
        self.scheduler = scheduler
        self.sourceRegistry = sourceRegistry
        self.now = now
        let sourceClock = ManagedItemSourceClock(read: now)
        self.sourceClock = sourceClock
        self.iconRenderer = iconRenderer
        self.renderedTitle = commandConfig.errorText
        let primaryRunner = CommandRunner(
            command: commandConfig.run,
            timeout: commandConfig.timeout,
            maxOutputBytes: commandConfig.maxOutputBytes,
            shell: commandConfig.shell,
            workingDirectory: commandConfig.workingDirectory,
            environment: commandConfig.environment
        )
        let primaryLease = sourceRegistry.acquire(
            configuration: Self.sourceConfiguration(for: commandConfig),
            scheduler: scheduler,
            clock: self.sourceClock,
            runner: primaryRunner
        )
        self.primarySource = primaryLease.source
        self.primarySourceLease = primaryLease
        self.actionRunners = Self.makeActionRunners(for: commandConfig.actions, config: commandConfig)
        self.menuRowRunners = Self.makeMenuRowRunners(for: commandConfig.menu, config: commandConfig)
        let rowLeases = Self.makeMenuRowSourceLeases(
            for: commandConfig.menu,
            config: commandConfig,
            scheduler: scheduler,
            registry: sourceRegistry,
            clock: sourceClock
        )
        self.menuRowSourceLeases = rowLeases
        self.menuRowSources = rowLeases.mapValues(\.source)
        let statusItem = statusItemFactory()
        self.statusItem = statusItem
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleClick)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyIcon()
        applyDisplayedTitle()
        setVisibility(initiallyVisible && !commandConfig.hidden)
        if initiallyVisible {
            startTimer()
            startMenuRowSources()
        }
    }

    func activate() {
        guard isActive else { return }
        setVisibility(!commandConfig.hidden)
        startTimer()
        startMenuRowSources()
    }

    func setStatusItemVisible(_ visible: Bool) {
        statusItemSuppressed = !visible
        statusItem?.isVisible = visible && isVisible
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        guard let ownedStatusItem = self.statusItem else { return false }
        return ownedStatusItem === statusItem
    }

    private func applyIcon(source: ItemIconSource? = nil) {
        // Loading is intentionally independent of `statusItem` (nil in headless
        // tests) so `iconIsLoaded` reflects whether the configured source
        // actually resolved, not whether there is a real status item to paint
        // it onto. An unavailable SF Symbol name stays a valid config and
        // falls back to text-only with a diagnostic note.
        let rendered = iconRenderer.render(source ?? commandConfig.iconSource)
        iconRenderer.apply(rendered, to: statusItem?.button)
        iconIsLoaded = rendered.isLoaded
        iconDiagnosticNote = rendered.diagnosticNote
    }

    func prepareUpdate(
        config: ItemConfig,
        deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()
    ) async {
        guard isActive, !isPreparingRemoval, pendingUpdate == nil else { return }
        let newCommandConfig = config

        let previousConfig = self.commandConfig
        isPreparingUpdate = true

        let runnerConfigurationChanged = previousConfig.run != newCommandConfig.run
            || previousConfig.timeout != newCommandConfig.timeout
            || previousConfig.maxOutputBytes != newCommandConfig.maxOutputBytes
            || previousConfig.shell != newCommandConfig.shell
            || previousConfig.workingDirectory != newCommandConfig.workingDirectory
            || previousConfig.environment != newCommandConfig.environment
        let timerNeedsRestart = runnerConfigurationChanged
            || previousConfig.interval != newCommandConfig.interval
            || previousConfig.disabled != newCommandConfig.disabled
        let staleAfterChanged = previousConfig.staleAfter != newCommandConfig.staleAfter || runnerConfigurationChanged
        let presentationNeedsUpdate = previousConfig.format != newCommandConfig.format
            || previousConfig.errorText != newCommandConfig.errorText
            || previousConfig.onError != newCommandConfig.onError
            || previousConfig.staleAfter != newCommandConfig.staleAfter
            || previousConfig.maxLength != newCommandConfig.maxLength
            || previousConfig.hideWhenEmpty != newCommandConfig.hideWhenEmpty
            || previousConfig.hideOnError != newCommandConfig.hideOnError
            || previousConfig.hidden != newCommandConfig.hidden
            || previousConfig.iconOnly != newCommandConfig.iconOnly
            || previousConfig.disabled != newCommandConfig.disabled
            || previousConfig.iconSource != newCommandConfig.iconSource
        let becameDisabled = !previousConfig.disabled && newCommandConfig.disabled
        if timerNeedsRestart {
            cancelRefreshTimer()
        }

        // Quiesce every runner whose configuration is changing before this
        // function awaits anything: `configurationGeneration` has already
        // been bumped for the primary runner and `isPreparingUpdate` was set
        // above, so no new scheduled/manual/click/action work can start
        // against the old runners from this point on. Cancellation requests
        // for all of them are then fired and awaited concurrently under one
        // shared deadline instead of one after another.
        var replacementPrimarySource: CommandSource?
        var replacementPrimarySourceLease: CommandSourceLease?
        let sourceConfigurationChanged = runnerConfigurationChanged
            || previousConfig.interval != newCommandConfig.interval
            || previousConfig.staleAfter != newCommandConfig.staleAfter
        let runnerNeedsCancel = sourceConfigurationChanged || becameDisabled
        if runnerNeedsCancel {
            configurationGeneration &+= 1
            if runnerConfigurationChanged {
                let newRunner = CommandRunner(
                    command: newCommandConfig.run,
                    timeout: newCommandConfig.timeout,
                    maxOutputBytes: newCommandConfig.maxOutputBytes,
                    shell: newCommandConfig.shell,
                    workingDirectory: newCommandConfig.workingDirectory,
                    environment: newCommandConfig.environment
                )
                let lease = sourceRegistry.acquire(
                    configuration: Self.sourceConfiguration(for: newCommandConfig),
                    scheduler: scheduler,
                    clock: sourceClock,
                    runner: newRunner
                )
                replacementPrimarySource = lease.source
                replacementPrimarySourceLease = lease
            } else if sourceConfigurationChanged {
                let lease = sourceRegistry.acquire(
                    configuration: Self.sourceConfiguration(for: newCommandConfig),
                    scheduler: scheduler,
                    clock: sourceClock,
                    runner: nil
                )
                replacementPrimarySource = lease.source
                replacementPrimarySourceLease = lease
            }
        }

        let actionRunnersConfigurationChanged = previousConfig.actions != newCommandConfig.actions
            || previousConfig.timeout != newCommandConfig.timeout
            || previousConfig.maxOutputBytes != newCommandConfig.maxOutputBytes
            || previousConfig.shell != newCommandConfig.shell
            || previousConfig.workingDirectory != newCommandConfig.workingDirectory
            || previousConfig.environment != newCommandConfig.environment
        let actionsNeedCancel = actionRunnersConfigurationChanged || becameDisabled
        let replacementActionRunners = actionRunnersConfigurationChanged
            ? Self.makeActionRunners(for: newCommandConfig.actions, config: newCommandConfig)
            : nil
        let menuRowsChanged = previousConfig.menu != newCommandConfig.menu
        let replacementMenuRowRunners = menuRowsChanged
            ? Self.makeMenuRowRunners(for: newCommandConfig.menu, config: newCommandConfig)
            : nil
        let replacementMenuRowLeases = menuRowsChanged
            ? Self.makeMenuRowSourceLeases(
                for: newCommandConfig.menu,
                config: newCommandConfig,
                scheduler: scheduler,
                registry: sourceRegistry,
                clock: sourceClock
            )
            : nil
        let replacementMenuRowSources = replacementMenuRowLeases?.mapValues(\.source)
        let menuRowsNeedCancel = menuRowsChanged || becameDisabled

        // A permit request only queued (not yet running) for a runner whose
        // configuration is changing belongs to the outgoing generation, so it
        // is cancelled here alongside that runner's cancellation rather than
        // left to eventually acquire a permit and no-op against the new
        // config. A permit wait for an unaffected runner (e.g. a
        // presentation-only update) is left alone and runs normally once
        // this update commits.
        if runnerNeedsCancel {
            pendingRefreshPermitTask?.cancel()
        }
        if menuRowsChanged {
            for task in menuRowRefreshTasks.values {
                task.cancel()
            }
            menuRowRefreshTasks.removeAll()
            cancelMenuRowTimers()
        }
        if actionsNeedCancel || menuRowsNeedCancel {
            for task in pendingActionPermitTasks.values {
                task.cancel()
            }
        }

        await settleConcurrently(
            cancellationOperations(
                includingPrimary: runnerNeedsCancel,
                includingActions: actionsNeedCancel,
                includingMenuRows: menuRowsNeedCancel
            ),
            deadline: deadline,
            onTimeout: { [weak self] timeouts in
                self?.handleLifecycleSettlementTimeout(timeouts, phase: "update")
            }
        )

        pendingUpdate = PendingUpdate(
            commandConfig: newCommandConfig,
            primarySource: replacementPrimarySource,
            actionRunners: replacementActionRunners,
            menuRowRunners: replacementMenuRowRunners,
            menuRowSources: replacementMenuRowSources,
            primarySourceLease: replacementPrimarySourceLease,
            menuRowSourceLeases: replacementMenuRowLeases,
            actionRunnersConfigurationChanged: actionRunnersConfigurationChanged,
            menuRowsChanged: menuRowsChanged,
            timerNeedsRestart: timerNeedsRestart,
            presentationNeedsUpdate: presentationNeedsUpdate,
            staleAfterChanged: staleAfterChanged,
        )
    }

    func commitPreparedUpdate() {
        guard isActive, let pendingUpdate else { return }
        self.pendingUpdate = nil
        commandConfig = pendingUpdate.commandConfig
        if let primarySource = pendingUpdate.primarySource {
            sourceRegistry.release(primarySourceLease)
            self.primarySource = primarySource
            primarySourceLease = pendingUpdate.primarySourceLease!
        }
        if pendingUpdate.menuRowsChanged {
            for lease in menuRowSourceLeases.values {
                sourceRegistry.release(lease)
            }
            menuRows = commandConfig.menu
            menuRowRunners = pendingUpdate.menuRowRunners ?? Self.makeMenuRowRunners(for: menuRows, config: commandConfig)
            menuRowSources = pendingUpdate.menuRowSources ?? Self.makeMenuRowSourceLeases(
                for: menuRows,
                config: commandConfig,
                scheduler: scheduler,
                registry: sourceRegistry,
                clock: sourceClock
            ).mapValues(\.source)
            menuRowSourceLeases = pendingUpdate.menuRowSourceLeases ?? [:]
            menuRowCachedValues.removeAll()
            startMenuRowSources()
        }
        actions = commandConfig.actions
        if pendingUpdate.actionRunnersConfigurationChanged {
            actionRunners = Self.makeActionRunners(for: actions, config: commandConfig)
        }
        applyIcon()
        if pendingUpdate.timerNeedsRestart {
            startTimer(runInitialRefresh: false)
        }
        if pendingUpdate.staleAfterChanged {
            scheduleStalePresentation()
        }
        if pendingUpdate.presentationNeedsUpdate {
            lastSuccessfulTitle = lastSuccessfulOutput.map { applyFormat(commandConfig.format, output: lastTrimmedLine(of: $0)) }
            requestPresentationUpdate()
        }
        isPreparingUpdate = false
    }

    func prepareRemoval(deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()) async {
        guard isActive, !isPreparingRemoval else { return }
        isPreparingRemoval = true
        configurationGeneration &+= 1
        stalePresentationTask?.cancel()
        stalePresentationTask = nil
        cancelRefreshTimer()
        pendingRefreshPermitTask?.cancel()
        for task in pendingActionPermitTasks.values {
            task.cancel()
        }

        // Everything above is synchronous quiescing: no scheduled, manual,
        // or action invocation can start against this item past this point.
        // All primary/action cancellation, plus draining any action
        // invocation already accepted before quiescing, is then fired and
        // awaited concurrently under one shared deadline.
        let name = config.name
        var operations = cancellationOperations(
            includingPrimary: true,
            includingActions: true,
            includingMenuRows: true
        )
        if pendingActionInvocations > 0 {
            operations.append((identity: "\(name):action-drain", run: { [weak self] in
                await self?.drainActionInvocations()
            }))
        }

        await settleConcurrently(
            operations,
            deadline: deadline,
            onTimeout: { [weak self] timeouts in
                self?.handleLifecycleSettlementTimeout(timeouts, phase: "removal")
            }
        )
    }

    func commitRemoval() {
        guard isActive else { return }
        isActive = false
        isPreparingRemoval = false
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        sourceRegistry.release(primarySourceLease)
        for lease in menuRowSourceLeases.values {
            sourceRegistry.release(lease)
        }
    }

    func tearDown(deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()) async {
        await prepareRemoval(deadline: deadline)
        commitRemoval()
    }

    /// Builds the concurrent-cancellation operation list shared by
    /// `prepareUpdate`/`prepareRemoval`: one operation per runner role that
    /// needs cancelling, each identified by item name and role so
    /// diagnostics and tests can tell them apart. Building this list is
    /// itself synchronous; none of the operations run until
    /// `settleConcurrently` fires them.
    private func cancellationOperations(
        includingPrimary: Bool,
        includingActions: Bool,
        includingMenuRows: Bool
    ) -> [(identity: String, run: () async -> Void)] {
        var operations: [(identity: String, run: () async -> Void)] = []
        let name = config.name
        if includingPrimary {
            let source = self.primarySource
            operations.append((identity: "\(name):primary", run: { [weak self] in
                await source.cancel()
                await self?.drainRefreshInvocations()
                await self?.awaitCancellationSettlementDelayForTesting(role: "primary")
            }))
        }
        if includingActions {
            for (index, actionRunner) in actionRunners {
                operations.append((identity: "\(name):action[\(index)]", run: { [weak self] in
                    await actionRunner.cancelActive()
                    await self?.awaitCancellationSettlementDelayForTesting(role: "action:\(index)")
                }))
            }
        }
        if includingMenuRows {
            for (index, menuRowRunner) in menuRowRunners {
                operations.append((identity: "\(name):menu-row[\(index)]", run: { [weak self] in
                    await menuRowRunner.cancelActive()
                    await self?.awaitCancellationSettlementDelayForTesting(role: "menu-row:\(index)")
                }))
            }
            for (index, source) in menuRowSources {
                operations.append((identity: "\(name):source[\(index)]", run: { [weak self] in
                    await source.cancel()
                    await self?.awaitCancellationSettlementDelayForTesting(role: "source:\(index)")
                }))
            }
        }
        return operations
    }

    private func awaitCancellationSettlementDelayForTesting(role: String) async {
        guard let hook = cancellationSettlementDelayForTesting else { return }
        await hook(role)
    }

    private static func sourceConfiguration(for config: CommandItemConfig) -> CommandSourceConfiguration {
        let refreshPolicy: CommandSourceRefreshPolicy
        switch config.interval {
        case .manual:
            refreshPolicy = .manual
        case .scheduled(let interval):
            refreshPolicy = .scheduled(interval)
        }
        return CommandSourceConfiguration(
            command: config.run,
            timeout: config.timeout,
            maxOutputBytes: config.maxOutputBytes,
            shell: config.shell,
            workingDirectory: config.workingDirectory,
            environment: config.environment,
            refreshPolicy: refreshPolicy,
            staleAfter: config.staleAfter
        )
    }

    private static func makeMenuRowSourceLeases(
        for rows: [MenuRowConfig],
        config: CommandItemConfig,
        scheduler: CommandScheduler,
        registry: CommandSourceRegistry,
        clock: any CommandSourceClock
    ) -> [Int: CommandSourceLease] {
        var leases: [Int: CommandSourceLease] = [:]
        for (index, row) in rows.enumerated() {
            guard let command = row.run else { continue }
            let policy: CommandSourceRefreshPolicy
            if let cache = row.cache {
                policy = .scheduled(cache)
            } else {
                policy = .manual
            }
            let configuration = CommandSourceConfiguration(
                command: command,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes,
                shell: config.shell,
                workingDirectory: config.workingDirectory,
                environment: config.environment,
                refreshPolicy: policy,
                staleAfter: row.cache
            )
            leases[index] = registry.acquire(
                configuration: configuration,
                scheduler: scheduler,
                clock: clock
            )
        }
        return leases
    }

    private func startMenuRowSources() {
        cancelMenuRowTimers()
        for (index, source) in menuRowSources {
            requestMenuRowRefresh(at: index, source: source)
            guard let interval = menuRows[index].cache else { continue }
            let token = CommandScheduler.ItemToken()
            menuRowTimerTokens[index] = token
            let scheduler = self.scheduler
            Task {
                await scheduler.registerRecurring(token: token, interval: interval) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.requestMenuRowRefresh(at: index)
                    }
                }
            }
        }
    }

    private func cancelMenuRowTimers() {
        let tokens = Array(menuRowTimerTokens.values)
        menuRowTimerTokens.removeAll()
        let scheduler = self.scheduler
        for token in tokens {
            Task { await scheduler.cancelTimer(token) }
        }
    }

    private func requestMenuRowRefresh(at index: Int, source: CommandSource? = nil) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval,
              menuRows.indices.contains(index),
              let source = source ?? menuRowSources[index],
              menuRowRefreshTasks[index] == nil
        else { return }
        let generation = configurationGeneration
        menuRowLastAttemptedAt[index] = now()
        menuRowRefreshTasks[index] = Task { @MainActor [weak self, source] in
            let cached = await source.refresh()
            guard let self,
                  self.isActive,
                  self.configurationGeneration == generation
            else { return }
            if let value = cached.value {
                self.menuRowCachedValues[index] = lastTrimmedLine(of: value)
            }
            if let lastSuccessfulAt = cached.lastSuccessfulAt {
                self.menuRowLastSuccessfulAt[index] = lastSuccessfulAt
            }
            self.menuRowRefreshTasks[index] = nil
        }
    }

    private func handleLifecycleSettlementTimeout(
        _ timeouts: [LifecycleSettlementTimeout],
        phase: String
    ) {
        lifecycleSettlementTimeoutHandlerForTesting?(timeouts)
        for timeout in timeouts {
            FileHandle.standardError.write(
                Data("pinchos: \(phase) settlement timeout waiting for \(timeout.identity)\n".utf8)
            )
        }
    }

    private func drainActionInvocations() async {
        guard pendingActionInvocations > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            actionInvocationsDrained = continuation
        }
    }

    private func startTimer(runInitialRefresh: Bool = true) {
        cancelRefreshTimer()
        guard !commandConfig.disabled else { return }
        guard case .scheduled(let interval) = commandConfig.interval else {
            if runInitialRefresh {
                requestRefresh()
            }
            return
        }
        let token = CommandScheduler.ItemToken()
        refreshTimerToken = token
        let scheduler = self.scheduler
        Task { [weak self] in
            guard let self else { return }
            await scheduler.registerRecurring(token: token, interval: interval) { [weak self] in
                let item = self
                Task { @MainActor in
                    item?.tick()
                }
            }
        }
    }

    /// Cancels this item's registration with the shared scheduler timer, if
    /// any. Safe to call unconditionally (e.g. at the top of `startTimer`,
    /// or during removal) since it is a no-op when nothing is registered.
    private func cancelRefreshTimer() {
        guard let token = refreshTimerToken else { return }
        refreshTimerToken = nil
        let scheduler = self.scheduler
        Task {
            await scheduler.cancelTimer(token)
        }
    }

    private func tick() {
        requestRefresh()
    }

    func refreshNow() {
        requestRefresh()
    }

    /// Requests a refresh, coalescing with any refresh already queued for the
    /// primary source. The source owns scheduler admission and holds its
    /// permit until the complete process session settles.
    private func requestRefresh() {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, !commandConfig.disabled else { return }
        guard pendingRefreshPermitTask == nil else {
            recordCoalesced()
            Task { await primarySource.recordSkippedRefresh() }
            return
        }
        pendingRefreshInvocations += 1
        pendingRefreshPermitTask = Task { @MainActor [self] in
            await refresh()
            pendingRefreshPermitTask = nil
            finishRefreshInvocation()
        }
    }

    /// Records that a request coalesced into an already-queued permit wait
    /// for this item's diagnostics, without blocking on the scheduler actor.
    private func recordCoalesced() {
        let scheduler = self.scheduler
        Task {
            await scheduler.recordCoalesced()
        }
    }

    private func refresh() async {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        let generation = configurationGeneration
        lastAttemptedAt = now()
        let cached = await primarySource.refresh()
        guard isActive, generation == configurationGeneration else { return }
        guard let execution = cached.lastExecution else { return }
        guard isActive, generation == configurationGeneration else { return }
        lastSuccessfulOutput = cached.value
        lastAttemptedAt = cached.lastAttemptedAt
        lastUpdatedAt = cached.lastSuccessfulAt
        if execution.terminalReason == .exited(code: 0) {
            actions = commandConfig.actions
            lastSuccessfulTitle = applyFormat(
                commandConfig.format,
                output: lastTrimmedLine(of: execution.stdout)
            )
            scheduleStalePresentation()
        }
        let runnerSnapshot = await primarySource.runnerSnapshot()
        guard isActive, generation == configurationGeneration else { return }
        let snapshot = makeRuntimeSnapshot(runnerSnapshot)
        renderPresentation(snapshot)
    }

    private func requestPresentationUpdate() {
        Task { @MainActor [weak self] in
            await self?.updatePresentation()
        }
    }

    private func updatePresentation() async {
        let runnerSnapshot = await primarySource.runnerSnapshot()
        guard isActive else { return }
        let snapshot = makeRuntimeSnapshot(runnerSnapshot)
        renderPresentation(snapshot)
    }

    private func scheduleStalePresentation() {
        stalePresentationTask?.cancel()
        stalePresentationTask = nil
        guard let staleAfter = commandConfig.staleAfter, let lastUpdatedAt else { return }
        let generation = configurationGeneration
        let remaining = lastUpdatedAt.addingTimeInterval(staleAfter).timeIntervalSince(now())
        guard remaining > 0 else {
            requestPresentationUpdate()
            return
        }
        let nanoseconds = stalePresentationNanoseconds(for: remaining)
        stalePresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, self.isActive, self.configurationGeneration == generation else { return }
            await self.updatePresentation()
        }
    }

    private func stalePresentationNanoseconds(for remaining: TimeInterval) -> UInt64 {
        let value = remaining * 1_000_000_000
        guard value.isFinite, value < Double(UInt64.max) else { return .max }
        return UInt64(max(1, value))
    }

    private func renderPresentation(_ snapshot: ItemRuntimeSnapshot) {
        let baseTitle: String
        switch snapshot.status {
        case .fresh, .stale:
            baseTitle = lastSuccessfulTitle ?? commandConfig.errorText
        case .warning:
            baseTitle = lastSuccessfulTitle ?? commandConfig.errorText
        case .error:
            baseTitle = (commandConfig.onError == .keepLast)
                ? (lastSuccessfulTitle ?? commandConfig.errorText)
                : commandConfig.errorText
        case .running:
            baseTitle = lastSuccessfulTitle ?? renderedTitle
        case .unavailable:
            baseTitle = commandConfig.errorText
        }

        let marker: String
        switch snapshot.status {
        case .stale:
            marker = " ⌛︎"
        case .warning, .error, .unavailable:
            marker = " ⚠︎"
        case .running, .fresh:
            marker = ""
        }
        setTitle(truncateTitle(baseTitle, maxLength: commandConfig.maxLength) + marker)
        applyIcon(source: commandConfig.iconSource)
        setVisibility(
            computeVisibility(
                lastExecution: snapshot.lastExecution,
                fullOutput: snapshot.fullOutput
            )
        )
    }

    /// `hide_when_empty` and `hide_on_error` only take effect after a completed
    /// attempt (`lastExecution` becomes non-nil), so an item never disappears before
    /// its first result lands. `disabled` overrides both policies to keep a disabled
    /// item visible and inspectable via its diagnostics menu unless the
    /// persistent `hidden` policy is also enabled.
    private func computeVisibility(lastExecution: CommandExecution?, fullOutput: String?, hidden: Bool? = nil) -> Bool {
        guard !commandConfig.hidden else { return false }
        guard !commandConfig.disabled else { return true }
        guard let lastExecution else { return true }
        if lastExecution.terminalReason != .exited(code: 0) {
            return !commandConfig.hideOnError
        }
        if let hidden { return !hidden }
        if commandConfig.hideWhenEmpty {
            return !lastTrimmedLine(of: fullOutput ?? "").isEmpty
        }
        return true
    }

    private func makeRuntimeSnapshot(_ runnerSnapshot: CommandRunnerSnapshot) -> ItemRuntimeSnapshot {
        ItemRuntimeSnapshot(
            isRunning: runnerSnapshot.isRunning,
            fullOutput: lastSuccessfulOutput,
            lastAttemptedAt: lastAttemptedAt,
            lastUpdatedAt: lastUpdatedAt,
            lastExecution: runnerSnapshot.lastExecution,
            staleAfter: commandConfig.staleAfter,
            skippedRefreshes: runnerSnapshot.skippedRefreshes,
            now: now()
        )
    }

    private func replaceActions(_ newActions: [ItemAction], config: CommandItemConfig) async {
        guard actions != newActions else { return }
        for task in pendingActionPermitTasks.values {
            task.cancel()
        }
        let runners = Array(actionRunners.values)
        await withTaskGroup(of: Void.self) { group in
            for runner in runners {
                group.addTask { await runner.cancelActive() }
            }
        }
        actions = newActions
        actionRunners = Self.makeActionRunners(for: newActions, config: config)
    }

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        let runnerSnapshot = await primarySource.runnerSnapshot()
        let snapshot = makeRuntimeSnapshot(runnerSnapshot)
        renderPresentation(snapshot)
        return snapshot
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        await primarySource.runnerSnapshot()
    }

    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot? {
        guard actions.indices.contains(index),
            case .command = actions[index].kind,
            let actionRunner = actionRunners[index]
        else {
            return nil
        }
        return await actionRunner.snapshot()
    }

    func menuRowValue(at index: Int) -> String? {
        guard menuRows.indices.contains(index) else { return nil }
        requestMenuRowRefreshIfNeeded(at: index)
        return menuRows[index].value ?? menuRowCachedValues[index]
    }

    private func requestMenuRowRefreshIfNeeded(at index: Int) {
        guard menuRows[index].run != nil,
              menuRowRefreshTasks[index] == nil
        else { return }
        let now = now()
        if menuRowCachedValues[index] == nil {
            guard menuRowLastAttemptedAt[index] == nil
                || menuRows[index].cache.map({ now.timeIntervalSince(menuRowLastAttemptedAt[index]!) >= $0 }) == true
            else { return }
            requestMenuRowRefresh(at: index)
            return
        }
        guard let cache = menuRows[index].cache,
              let lastSuccessfulAt = menuRowLastSuccessfulAt[index],
              now.timeIntervalSince(lastSuccessfulAt) >= cache
        else { return }
        requestMenuRowRefresh(at: index)
    }

    func menuRowSnapshot(at index: Int) async -> CommandRunnerSnapshot? {
        guard menuRows.indices.contains(index),
            menuRows[index].action != nil,
            let menuRowRunner = menuRowRunners[index]
        else {
            return nil
        }
        return await menuRowRunner.snapshot()
    }

    func invokeMenuRow(at index: Int) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, !commandConfig.disabled,
            menuRows.indices.contains(index),
            menuRows[index].action != nil,
            let menuRowRunner = menuRowRunners[index]
        else {
            return
        }
        guard pendingActionPermitTasks[index] == nil else {
            recordCoalesced()
            return
        }
        pendingActionInvocations += 1
        pendingActionPermitTasks[index] = Task { @MainActor [self] in
            do {
                try await scheduler.acquirePermit()
            } catch {
                pendingActionPermitTasks[index] = nil
                finishActionInvocation()
                return
            }
            pendingActionPermitTasks[index] = nil
            await invokeGuarded(
                runner: menuRowRunner,
                testGate: actionInvocationTestGate,
                currentRunner: { $0.menuRowRunners[index] }
            )
            await scheduler.releasePermit()
            finishActionInvocation()
        }
    }

    /// Test-only visibility into the accept/start bookkeeping used to gate
    /// updates, removal, and shutdown on outstanding interaction-triggered work.
    var pendingActionInvocationCountForTesting: Int { pendingActionInvocations }

    func invokeAction(at index: Int) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, !commandConfig.disabled,
            actions.indices.contains(index)
        else {
            return
        }
        switch actions[index].kind {
        case .refresh:
            refreshNow()
        case .command:
            guard let actionRunner = actionRunners[index] else { return }
            guard pendingActionPermitTasks[index] == nil else {
                recordCoalesced()
                return
            }
            pendingActionInvocations += 1
            pendingActionPermitTasks[index] = Task { @MainActor [self] in
                do {
                    try await scheduler.acquirePermit()
                } catch {
                    pendingActionPermitTasks[index] = nil
                    finishActionInvocation()
                    return
                }
                pendingActionPermitTasks[index] = nil
                await invokeGuarded(
                    runner: actionRunner,
                    testGate: actionInvocationTestGate,
                    currentRunner: { $0.actionRunners[index] }
                )
                await scheduler.releasePermit()
                finishActionInvocation()
            }
        }
    }

    /// Shared "accept now, re-validate immediately before starting" contract for
    /// interaction-triggered declarative command actions. A runner
    /// captured at acceptance time may become stale if a config reload or removal
    /// commits while the caller was waiting for a scheduler permit:
    /// `currentRunner` re-reads the item's live runner (by reference identity) right
    /// before starting, so a call that lost that race silently no-ops instead of
    /// launching a command that belongs to a superseded configuration. Awaits the
    /// full run so the caller can hold its scheduler permit for the whole session.
    private func invokeGuarded(
        runner: CommandRunner,
        testGate: (() async -> Void)?,
        currentRunner: @escaping (ManagedItem) -> CommandRunner?,
        onStart: ((ManagedItem) -> Void)? = nil,
        onCompletion: ((ManagedItem) -> Void)? = nil
    ) async {
        if let testGate {
            await testGate()
        }
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, currentRunner(self) === runner else {
            return
        }
        onStart?(self)
        _ = await runner.runIfIdle()
        onCompletion?(self)
    }

    /// Both left- and right-click reveal the lifecycle menu, matching how
    /// other menu bar items behave. The menu stays
    /// reachable even for a `disabled` item, which remains inspectable.
    @objc private func handleClick() {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        guard let statusItem else { return }
        menuDelegate?.showLifecycleMenu(for: statusItem)
    }

    private func finishRefreshInvocation() {
        pendingRefreshInvocations -= 1
        guard pendingRefreshInvocations == 0, let continuation = refreshInvocationsDrained else { return }
        refreshInvocationsDrained = nil
        continuation.resume()
    }

    private func drainRefreshInvocations() async {
        guard pendingRefreshInvocations > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            refreshInvocationsDrained = continuation
        }
    }

    private func finishActionInvocation() {
        pendingActionInvocations -= 1
        guard pendingActionInvocations == 0, let continuation = actionInvocationsDrained else { return }
        actionInvocationsDrained = nil
        continuation.resume()
    }

    private static func makeActionRunners(
        for actions: [ItemAction],
        config: CommandItemConfig
    ) -> [Int: CommandRunner] {
        var runners: [Int: CommandRunner] = [:]
        for (index, action) in actions.enumerated() {
            guard case .command(let command) = action.kind else { continue }
            runners[index] = CommandRunner(
                command: command,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes,
                shell: config.shell,
                workingDirectory: config.workingDirectory,
                environment: config.environment
            )
        }
        return runners
    }

    private static func makeMenuRowRunners(
        for rows: [MenuRowConfig],
        config: CommandItemConfig
    ) -> [Int: CommandRunner] {
        var runners: [Int: CommandRunner] = [:]
        for (index, row) in rows.enumerated() {
            guard let command = row.action else { continue }
            runners[index] = CommandRunner(
                command: command,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes,
                shell: config.shell,
                workingDirectory: config.workingDirectory,
                environment: config.environment
            )
        }
        return runners
    }

    private func setTitle(_ title: String) {
        renderedTitle = title
        applyDisplayedTitle()
    }

    /// `icon_only` clears the status-bar button's text once an icon has actually
    /// loaded, so a missing/unreadable file or an unavailable SF Symbol quietly
    /// falls back to showing the text title instead of leaving the item blank.
    /// title instead of leaving the item blank. `renderedTitle` itself (already
    /// `max_length`-truncated and marker-suffixed) is unaffected either way; only
    /// the button-facing `renderedButtonTitle` is blanked. The diagnostics
    /// menu reads the untruncated full output separately, not this title.
    private func applyDisplayedTitle() {
        let displayed = (commandConfig.iconOnly && iconIsLoaded) ? "" : renderedTitle
        renderedButtonTitle = displayed
        statusItem?.button?.title = displayed
    }

    private func setVisibility(_ visible: Bool) {
        isVisible = visible
        statusItem?.isVisible = visible && !statusItemSuppressed
    }
}
