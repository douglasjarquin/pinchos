import AppKit
import PinchosCore

/// Diagnostics for the click-command runner, kept independent from the primary
/// item's runtime snapshot so a click failure or in-flight click can never be
/// mistaken for (or overwrite) the primary displayed value. `lastAttemptedAt`
/// and `lastCompletedAt` bracket the most recent invocation that actually
/// reached the runner (races lost to a config reload never touch them) and are
/// reset alongside the runner itself when click execution settings change.
struct ClickDiagnosticsSnapshot {
    let runner: CommandRunnerSnapshot
    let lastAttemptedAt: Date?
    let lastCompletedAt: Date?
}

@MainActor
final class ManagedItem: ManagedItemLifecycle {
    let statusItem: NSStatusItem?
    private(set) var renderedTitle: String
    private(set) var renderedButtonTitle: String = ""
    private(set) var renderedToolTip: String?
    private(set) var isVisible = true
    private(set) var config: ItemConfig
    private var iconIsLoaded = false
    private var runner: CommandRunner
    private var clickRunner: CommandRunner?
    private var actionRunners: [Int: CommandRunner]
    /// The one application-scoped `CommandScheduler` bounding this item's
    /// scheduled refreshes, manual refreshes, clicks, and command actions
    /// alongside every other item's, replacing the per-item
    /// `DispatchQueue`/`DispatchSourceTimer` this class used to own.
    private let scheduler: CommandScheduler
    private var refreshTimerToken: CommandScheduler.ItemToken?
    /// Tracks a refresh/click/action request while it is only queued for a
    /// global permit (not yet running). A second request arriving in that
    /// window coalesces into this one (see `recordCoalesced`) instead of
    /// enqueuing a second waiter, bounding the interactive/scheduled queue
    /// depth this item can contribute to at most one per work kind. Once a
    /// permit is granted the corresponding entry is cleared immediately
    /// (before the runner actually starts), so a request arriving while the
    /// command itself is running still reaches the runner's own no-overlap
    /// check and increments `skippedRefreshes` exactly as before.
    private var pendingRefreshPermitTask: Task<Void, Never>?
    private var pendingClickPermitTask: Task<Void, Never>?
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
    private var pendingClickInvocations = 0
    private var clickInvocationsDrained: CheckedContinuation<Void, Never>?
    private var pendingActionInvocations = 0
    private var actionInvocationsDrained: CheckedContinuation<Void, Never>?
    private var lastSuccessfulOutput: String?
    private var lastAttemptedAt: Date?
    private var lastUpdatedAt: Date?
    private var lastSuccessfulTitle: String?
    private var stalePresentationTask: Task<Void, Never>?
    private var lastClickAttemptedAt: Date?
    private var lastClickCompletedAt: Date?

    /// Test-only seams that pause a queued click/action invocation after it has been
    /// accepted (bookkeeping incremented) but before it re-checks lifecycle state and
    /// touches its captured runner. This lets tests deterministically land a config
    /// reload or removal in the acceptance-to-start window without racing on timing.
    /// Production code always passes `nil`, so these are no-ops outside tests.
    var clickInvocationTestGate: (() async -> Void)?
    var actionInvocationTestGate: (() async -> Void)?

    /// Test-only seam awaited alongside each runner's real cancellation during
    /// `prepareUpdate`/`prepareRemoval`, keyed by role ("primary", "click", or
    /// "action:<index>"). Real runner cancellation is normally too fast to
    /// distinguish concurrent from sequential execution in a test; this lets
    /// tests inject a controllable settle time per role and prove that all
    /// roles for one item are cancelled concurrently -- bounded by the
    /// slowest role, not the sum of all of them. Production code always
    /// leaves this `nil`.
    var cancellationSettlementDelayForTesting: ((String) async -> Void)?

    /// Test-only observer invoked with the identities reported by
    /// `settleConcurrently` whenever a `prepareUpdate`/`prepareRemoval`
    /// cancellation phase misses its shared deadline.
    var lifecycleSettlementTimeoutHandlerForTesting: (([LifecycleSettlementTimeout]) -> Void)?

    private struct PendingUpdate {
        let config: ItemConfig
        let runner: CommandRunner?
        let clickRunner: CommandRunner?
        let clickRunnerConfigurationChanged: Bool
        let actionRunners: [Int: CommandRunner]?
        let actionRunnersConfigurationChanged: Bool
        let timerNeedsRestart: Bool
        let presentationNeedsUpdate: Bool
        let staleAfterChanged: Bool
    }

    init(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool = true,
        scheduler: CommandScheduler = .shared,
        now: @escaping () -> Date = Date.init,
        statusItemFactory: @escaping () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
    ) {
        self.config = config
        self.menuDelegate = menuDelegate
        self.scheduler = scheduler
        self.now = now
        self.renderedTitle = config.errorText
        self.renderedToolTip = nil
        self.runner = CommandRunner(
            command: config.run,
            timeout: config.timeout,
            maxOutputBytes: config.maxOutputBytes,
            shell: config.shell,
            workingDirectory: config.workingDirectory,
            environment: config.environment
        )
        if let click = config.click {
            self.clickRunner = CommandRunner(
                command: click,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes,
                shell: config.shell,
                workingDirectory: config.workingDirectory,
                environment: config.environment
            )
        } else {
            self.clickRunner = nil
        }
        self.actionRunners = Self.makeActionRunners(for: config)
        let statusItem = statusItemFactory()
        self.statusItem = statusItem
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleClick)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyIcon()
        applyDisplayedTitle()
        setVisibility(initiallyVisible)
        if initiallyVisible {
            startTimer()
        }
    }

    func activate() {
        guard isActive else { return }
        setVisibility(true)
        startTimer()
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        guard let ownedStatusItem = self.statusItem else { return false }
        return ownedStatusItem === statusItem
    }

    private func applyIcon() {
        // Loading is intentionally independent of `statusItem` (nil in headless
        // tests) so `iconIsLoaded` reflects whether the configured file actually
        // resolved, not whether there is a real status item to paint it onto.
        guard let path = config.icon, let image = NSImage(contentsOfFile: path) else {
            statusItem?.button?.image = nil
            iconIsLoaded = false
            return
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.imagePosition = .imageLeft
        iconIsLoaded = true
    }

    func prepareUpdate(
        config: ItemConfig,
        deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()
    ) async {
        guard isActive, !isPreparingRemoval, pendingUpdate == nil else { return }

        let previousConfig = self.config
        isPreparingUpdate = true

        let runnerConfigurationChanged = previousConfig.run != config.run
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
            || previousConfig.shell != config.shell
            || previousConfig.workingDirectory != config.workingDirectory
            || previousConfig.environment != config.environment
        let timerNeedsRestart = runnerConfigurationChanged
            || previousConfig.interval != config.interval
            || previousConfig.disabled != config.disabled
        let staleAfterChanged = previousConfig.staleAfter != config.staleAfter || runnerConfigurationChanged
        let presentationNeedsUpdate = previousConfig.format != config.format
            || previousConfig.errorText != config.errorText
            || previousConfig.onError != config.onError
            || previousConfig.staleAfter != config.staleAfter
            || previousConfig.tooltip != config.tooltip
            || previousConfig.maxLength != config.maxLength
            || previousConfig.hideWhenEmpty != config.hideWhenEmpty
            || previousConfig.hideOnError != config.hideOnError
            || previousConfig.iconOnly != config.iconOnly
            || previousConfig.disabled != config.disabled
            || previousConfig.icon != config.icon
        let becameDisabled = !previousConfig.disabled && config.disabled
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
        var replacementRunner: CommandRunner?
        let runnerNeedsCancel = runnerConfigurationChanged || becameDisabled
        if runnerNeedsCancel {
            configurationGeneration &+= 1
            if runnerConfigurationChanged {
                replacementRunner = CommandRunner(
                    command: config.run,
                    timeout: config.timeout,
                    maxOutputBytes: config.maxOutputBytes,
                    shell: config.shell,
                    workingDirectory: config.workingDirectory,
                    environment: config.environment
                )
            }
        }

        let clickRunnerConfigurationChanged = previousConfig.click != config.click
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
            || previousConfig.shell != config.shell
            || previousConfig.workingDirectory != config.workingDirectory
            || previousConfig.environment != config.environment
        let clickNeedsCancel = clickRunnerConfigurationChanged || becameDisabled
        let replacementClickRunner = clickRunnerConfigurationChanged ? config.click.map {
            CommandRunner(
                command: $0,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes,
                shell: config.shell,
                workingDirectory: config.workingDirectory,
                environment: config.environment
            )
        } : nil

        let actionRunnersConfigurationChanged = previousConfig.actions != config.actions
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
            || previousConfig.shell != config.shell
            || previousConfig.workingDirectory != config.workingDirectory
            || previousConfig.environment != config.environment
        let actionsNeedCancel = actionRunnersConfigurationChanged || becameDisabled
        let replacementActionRunners = actionRunnersConfigurationChanged
            ? Self.makeActionRunners(for: config)
            : nil

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
        if clickNeedsCancel {
            pendingClickPermitTask?.cancel()
        }
        if actionsNeedCancel {
            for task in pendingActionPermitTasks.values {
                task.cancel()
            }
        }

        await settleConcurrently(
            cancellationOperations(
                includingPrimary: runnerNeedsCancel,
                includingClick: clickNeedsCancel,
                includingActions: actionsNeedCancel
            ),
            deadline: deadline,
            onTimeout: { [weak self] timeouts in
                self?.handleLifecycleSettlementTimeout(timeouts, phase: "update")
            }
        )

        pendingUpdate = PendingUpdate(
            config: config,
            runner: replacementRunner,
            clickRunner: replacementClickRunner,
            clickRunnerConfigurationChanged: clickRunnerConfigurationChanged,
            actionRunners: replacementActionRunners,
            actionRunnersConfigurationChanged: actionRunnersConfigurationChanged,
            timerNeedsRestart: timerNeedsRestart,
            presentationNeedsUpdate: presentationNeedsUpdate,
            staleAfterChanged: staleAfterChanged
        )
    }

    func commitPreparedUpdate() {
        guard isActive, let pendingUpdate else { return }
        self.pendingUpdate = nil
        config = pendingUpdate.config
        if let runner = pendingUpdate.runner {
            self.runner = runner
        }
        if pendingUpdate.clickRunnerConfigurationChanged {
            clickRunner = pendingUpdate.clickRunner
            lastClickAttemptedAt = nil
            lastClickCompletedAt = nil
        }
        if pendingUpdate.actionRunnersConfigurationChanged {
            actionRunners = pendingUpdate.actionRunners ?? [:]
        }
        applyIcon()
        if pendingUpdate.timerNeedsRestart {
            startTimer(runInitialRefresh: false)
        }
        if pendingUpdate.staleAfterChanged {
            scheduleStalePresentation()
        }
        if pendingUpdate.presentationNeedsUpdate {
            lastSuccessfulTitle = lastSuccessfulOutput.map {
                applyFormat(config.format, output: lastTrimmedLine(of: $0))
            }
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
        pendingClickPermitTask?.cancel()
        for task in pendingActionPermitTasks.values {
            task.cancel()
        }

        // Everything above is synchronous quiescing: no scheduled, manual,
        // click, or action invocation can start against this item past this
        // point. All primary/click/action cancellation, plus draining any
        // click/action invocation already accepted before quiescing, is then
        // fired and awaited concurrently under one shared deadline.
        let name = config.name
        var operations = cancellationOperations(
            includingPrimary: true,
            includingClick: clickRunner != nil,
            includingActions: true
        )
        if pendingClickInvocations > 0 {
            operations.append((identity: "\(name):click-drain", run: { [weak self] in
                await self?.drainClickInvocations()
            }))
        }
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
        includingClick: Bool,
        includingActions: Bool
    ) -> [(identity: String, run: () async -> Void)] {
        var operations: [(identity: String, run: () async -> Void)] = []
        let name = config.name
        if includingPrimary {
            let runner = self.runner
            operations.append((identity: "\(name):primary", run: { [weak self] in
                await runner.cancelActive()
                await self?.drainRefreshInvocations()
                await self?.awaitCancellationSettlementDelayForTesting(role: "primary")
            }))
        }
        if includingClick, let clickRunner {
            operations.append((identity: "\(name):click", run: { [weak self] in
                await clickRunner.cancelActive()
                await self?.awaitCancellationSettlementDelayForTesting(role: "click")
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
        return operations
    }

    private func awaitCancellationSettlementDelayForTesting(role: String) async {
        guard let hook = cancellationSettlementDelayForTesting else { return }
        await hook(role)
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

    private func drainClickInvocations() async {
        guard pendingClickInvocations > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clickInvocationsDrained = continuation
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
        guard !config.disabled else { return }
        guard case .scheduled(let interval) = config.interval else {
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
                Task { @MainActor in
                    self?.tick()
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

    /// Requests a refresh, coalescing with any refresh already queued for a
    /// global permit. Once granted, the permit is held for the whole
    /// primary-runner session (`refresh()`, which itself owns the runner's
    /// no-overlap check) and released exactly once when it settles.
    private func requestRefresh() {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, !config.disabled else { return }
        guard pendingRefreshPermitTask == nil else {
            recordCoalesced()
            return
        }
        pendingRefreshInvocations += 1
        pendingRefreshPermitTask = Task { @MainActor [self] in
            do {
                try await scheduler.acquirePermit()
            } catch {
                pendingRefreshPermitTask = nil
                finishRefreshInvocation()
                return
            }
            pendingRefreshPermitTask = nil
            await refresh()
            await scheduler.releasePermit()
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
        let attemptedAt = now()
        guard await runner.beginIfIdle() else { return }
        lastAttemptedAt = attemptedAt
        let runningRunnerSnapshot = await runner.snapshot()
        guard isActive, generation == configurationGeneration else {
            _ = await runner.finishActiveRun()
            return
        }
        renderPresentation(
            ItemRuntimeSnapshot(
                isRunning: true,
                fullOutput: lastSuccessfulOutput,
                lastAttemptedAt: lastAttemptedAt,
                lastUpdatedAt: lastUpdatedAt,
                lastExecution: runningRunnerSnapshot.lastExecution,
                staleAfter: config.staleAfter,
                skippedRefreshes: runningRunnerSnapshot.skippedRefreshes,
                now: now()
            )
        )
        let preliminaryOutcome = await runner.finishActiveRun()
        guard isActive, generation == configurationGeneration else { return }
        guard case .completed = preliminaryOutcome else { return }

        // The shell may have exited while same-group descendants and output
        // pipes are still settling. Do not commit success, output, or
        // timestamps from that preliminary shell-exit result: wait for the
        // definitive session result so late stdout/stderr and a late
        // timeout/cancellation are reflected instead of a stale `.exited(0)`.
        guard let execution = await runner.awaitSettledExecution() else { return }
        guard isActive, generation == configurationGeneration else { return }
        let currentConfig = config
        if execution.terminalReason == .exited(code: 0) {
            lastSuccessfulOutput = execution.stdout
            lastUpdatedAt = now()
            lastSuccessfulTitle = applyFormat(
                currentConfig.format,
                output: lastTrimmedLine(of: execution.stdout)
            )
            scheduleStalePresentation()
        } else if currentConfig.onError == .replace {
            lastSuccessfulOutput = nil
            lastUpdatedAt = nil
            lastSuccessfulTitle = nil
            stalePresentationTask?.cancel()
            stalePresentationTask = nil
        }
        let runnerSnapshot = await runner.snapshot()
        guard isActive, generation == configurationGeneration else { return }
        renderPresentation(
            ItemRuntimeSnapshot(
                isRunning: runnerSnapshot.isRunning,
                fullOutput: lastSuccessfulOutput,
                lastAttemptedAt: lastAttemptedAt,
                lastUpdatedAt: lastUpdatedAt,
                lastExecution: runnerSnapshot.lastExecution,
                staleAfter: currentConfig.staleAfter,
                skippedRefreshes: runnerSnapshot.skippedRefreshes,
                now: now()
            )
        )
    }

    private func requestPresentationUpdate() {
        Task { @MainActor [weak self] in
            await self?.updatePresentation()
        }
    }

    private func updatePresentation() async {
        let runnerSnapshot = await runner.snapshot()
        guard isActive else { return }
        let snapshot = ItemRuntimeSnapshot(
            isRunning: runnerSnapshot.isRunning,
            fullOutput: lastSuccessfulOutput,
            lastAttemptedAt: lastAttemptedAt,
            lastUpdatedAt: lastUpdatedAt,
            lastExecution: runnerSnapshot.lastExecution,
            staleAfter: config.staleAfter,
            skippedRefreshes: runnerSnapshot.skippedRefreshes,
            now: now()
        )
        renderPresentation(snapshot)
    }

    private func scheduleStalePresentation() {
        stalePresentationTask?.cancel()
        stalePresentationTask = nil
        guard let staleAfter = config.staleAfter, let lastUpdatedAt else { return }
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
            baseTitle = lastSuccessfulTitle ?? config.errorText
        case .error:
            baseTitle = config.onError == .keepLast
                ? (lastSuccessfulTitle ?? config.errorText)
                : config.errorText
        case .running:
            baseTitle = lastSuccessfulTitle ?? renderedTitle
        case .unavailable:
            baseTitle = config.errorText
        }

        let marker: String
        switch snapshot.status {
        case .stale:
            marker = " ⌛︎"
        case .error, .unavailable:
            marker = " ⚠︎"
        case .running, .fresh:
            marker = ""
        }
        setTitle(truncateTitle(baseTitle, maxLength: config.maxLength) + marker)
        setToolTip(renderTooltip(config.tooltip, state: snapshot))
        setVisibility(computeVisibility(lastExecution: snapshot.lastExecution, fullOutput: snapshot.fullOutput))
    }

    /// `hide_when_empty` and `hide_on_error` only take effect after a completed
    /// attempt (`lastExecution` becomes non-nil), so an item never disappears before
    /// its first result lands. `disabled` overrides both policies to keep a disabled
    /// item visible and inspectable via its right-click diagnostics menu.
    private func computeVisibility(lastExecution: CommandExecution?, fullOutput: String?) -> Bool {
        guard !config.disabled else { return true }
        guard let lastExecution else { return true }
        if lastExecution.terminalReason != .exited(code: 0) {
            return !config.hideOnError
        }
        if config.hideWhenEmpty {
            return !lastTrimmedLine(of: fullOutput ?? "").isEmpty
        }
        return true
    }

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        let runnerSnapshot = await runner.snapshot()
        let snapshot = ItemRuntimeSnapshot(
            isRunning: runnerSnapshot.isRunning,
            fullOutput: lastSuccessfulOutput,
            lastAttemptedAt: lastAttemptedAt,
            lastUpdatedAt: lastUpdatedAt,
            lastExecution: runnerSnapshot.lastExecution,
            staleAfter: config.staleAfter,
            skippedRefreshes: runnerSnapshot.skippedRefreshes,
            now: now()
        )
        renderPresentation(snapshot)
        return snapshot
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        await runner.snapshot()
    }

    func actionSnapshot(at index: Int) async -> CommandRunnerSnapshot? {
        guard config.actions.indices.contains(index),
            case .command = config.actions[index].kind,
            let actionRunner = actionRunners[index]
        else {
            return nil
        }
        return await actionRunner.snapshot()
    }

    func clickSnapshot() async -> ClickDiagnosticsSnapshot? {
        guard let clickRunner else { return nil }
        return ClickDiagnosticsSnapshot(
            runner: await clickRunner.snapshot(),
            lastAttemptedAt: lastClickAttemptedAt,
            lastCompletedAt: lastClickCompletedAt
        )
    }

    /// Test-only visibility into the accept/start bookkeeping used to gate
    /// updates, removal, and shutdown on outstanding interaction-triggered work.
    var pendingClickInvocationCountForTesting: Int { pendingClickInvocations }
    var pendingActionInvocationCountForTesting: Int { pendingActionInvocations }

    func invokeAction(at index: Int) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, !config.disabled,
            config.actions.indices.contains(index)
        else {
            return
        }
        switch config.actions[index].kind {
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
    /// interaction-triggered runs (clicks, declarative command actions). A runner
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

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        processClick(eventType: event.type)
    }

    func processClick(eventType: NSEvent.EventType) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        if eventType == .rightMouseUp {
            guard let statusItem else { return }
            menuDelegate?.showLifecycleMenu(for: statusItem)
        } else if config.disabled {
            return
        } else if clickRunner != nil {
            guard let clickRunner else { return }
            guard pendingClickPermitTask == nil else {
                recordCoalesced()
                return
            }
            pendingClickInvocations += 1
            pendingClickPermitTask = Task { @MainActor [self] in
                do {
                    try await scheduler.acquirePermit()
                } catch {
                    pendingClickPermitTask = nil
                    finishClickInvocation()
                    return
                }
                pendingClickPermitTask = nil
                await invokeGuarded(
                    runner: clickRunner,
                    testGate: clickInvocationTestGate,
                    currentRunner: { $0.clickRunner },
                    onStart: { $0.lastClickAttemptedAt = $0.now() },
                    onCompletion: { $0.lastClickCompletedAt = $0.now() }
                )
                await scheduler.releasePermit()
                finishClickInvocation()
            }
        } else if config.refreshOnClick {
            refreshNow()
        }
    }

    private func finishClickInvocation() {
        pendingClickInvocations -= 1
        guard pendingClickInvocations == 0, let continuation = clickInvocationsDrained else { return }
        clickInvocationsDrained = nil
        continuation.resume()
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

    private static func makeActionRunners(for config: ItemConfig) -> [Int: CommandRunner] {
        var runners: [Int: CommandRunner] = [:]
        for (index, action) in config.actions.enumerated() {
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

    private func setTitle(_ title: String) {
        renderedTitle = title
        applyDisplayedTitle()
    }

    /// `icon_only` clears the status-bar button's text once an icon has actually
    /// loaded, so a missing/unreadable icon quietly falls back to showing the text
    /// title instead of leaving the item blank. `renderedTitle` itself (already
    /// `max_length`-truncated and marker-suffixed) is unaffected either way; only
    /// the button-facing `renderedButtonTitle` is blanked. The tooltip and
    /// diagnostics menu read the untruncated full output separately, not this title.
    private func applyDisplayedTitle() {
        let displayed = (config.iconOnly && iconIsLoaded) ? "" : renderedTitle
        renderedButtonTitle = displayed
        statusItem?.button?.title = displayed
    }

    private func setToolTip(_ toolTip: String?) {
        renderedToolTip = toolTip
        statusItem?.button?.toolTip = toolTip
    }

    private func setVisibility(_ visible: Bool) {
        isVisible = visible
        statusItem?.isVisible = visible
    }
}
