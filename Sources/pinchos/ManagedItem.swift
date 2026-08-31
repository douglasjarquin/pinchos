import AppKit
import PinchosCore

@MainActor
final class ManagedItem: ManagedItemLifecycle {
    let statusItem: NSStatusItem?
    private(set) var renderedTitle = "–"
    private(set) var renderedToolTip: String?
    private(set) var iconDiagnosticNote: String?
    private(set) var cachedRuntimeSnapshot = ItemRuntimeSnapshot(
        isRunning: false,
        fullOutput: nil,
        lastAttemptedAt: nil,
        lastUpdatedAt: nil,
        lastExecution: nil,
        skippedRefreshes: 0
    )
    private(set) var config: ItemConfig

    private var runner: CommandRunner
    private let scheduler: CommandScheduler
    private let iconRenderer: StatusItemIconRenderer
    private weak var menuDelegate: StatusItemMenuDelegate?
    private let now: () -> Date

    private var refreshTimerToken: CommandScheduler.ItemToken?
    private var pendingRefreshPermitTask: Task<Void, Never>?
    private var pendingRefreshInvocations = 0
    private var refreshInvocationsDrained: CheckedContinuation<Void, Never>?

    private var isActive = true
    private var configurationGeneration = 0
    private var isPreparingUpdate = false
    private var pendingUpdate: PendingUpdate?
    private var isPreparingRemoval = false

    private var lastSuccessfulOutput: String?
    private var lastSuccessfulTitle: String?
    private var lastAttemptedAt: Date?
    private var lastUpdatedAt: Date?

    /// Test seams for proving cancellation settlement remains concurrent and
    /// deadline-bounded. Production leaves both nil.
    var cancellationSettlementDelayForTesting: ((String) async -> Void)?
    var lifecycleSettlementTimeoutHandlerForTesting: (([LifecycleSettlementTimeout]) -> Void)?

    private struct PendingUpdate {
        let config: ItemConfig
        let replacementRunner: CommandRunner?
        let resetsRuntime: Bool
        let timerNeedsRestart: Bool
        let presentationNeedsUpdate: Bool
    }

    init(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool = true,
        scheduler: CommandScheduler = .shared,
        iconRenderer: StatusItemIconRenderer = .system,
        now: @escaping () -> Date = Date.init,
        statusItemFactory: @escaping () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
    ) {
        self.config = config
        self.menuDelegate = menuDelegate
        self.scheduler = scheduler
        self.iconRenderer = iconRenderer
        self.now = now
        self.runner = Self.makeRunner(for: config)

        let statusItem = statusItemFactory()
        self.statusItem = statusItem
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleClick)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyIcon()
        setTitle("–")
        statusItem?.isVisible = initiallyVisible
        if initiallyVisible {
            startTimer()
        }
    }

    func activate() {
        guard isActive else { return }
        statusItem?.isVisible = true
        startTimer()
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        guard let owned = self.statusItem else { return false }
        return owned === statusItem
    }

    func prepareUpdate(
        config: ItemConfig,
        deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()
    ) async {
        guard isActive, !isPreparingRemoval, pendingUpdate == nil else { return }
        isPreparingUpdate = true

        let runnerChanged = self.config.run != config.run || self.config.timeout != config.timeout
        let timerNeedsRestart = runnerChanged || self.config.interval != config.interval
        let presentationNeedsUpdate = self.config.format != config.format
            || self.config.iconSource != config.iconSource

        if timerNeedsRestart {
            cancelRefreshTimer()
        }

        var replacementRunner: CommandRunner?
        if runnerChanged {
            configurationGeneration &+= 1
            pendingRefreshPermitTask?.cancel()
            replacementRunner = Self.makeRunner(for: config)
            let currentRunner = runner
            let itemName = self.config.name
            await settleConcurrently(
                [(
                    identity: "\(itemName):primary",
                    run: { [weak self] in
                        await currentRunner.cancelActive()
                        await self?.drainRefreshInvocations()
                        if let delay = self?.cancellationSettlementDelayForTesting {
                            await delay("primary")
                        }
                    }
                )],
                deadline: deadline,
                onTimeout: { [weak self] timeouts in
                    self?.handleLifecycleSettlementTimeout(timeouts, phase: "update")
                }
            )
        }

        pendingUpdate = PendingUpdate(
            config: config,
            replacementRunner: replacementRunner,
            resetsRuntime: runnerChanged,
            timerNeedsRestart: timerNeedsRestart,
            presentationNeedsUpdate: presentationNeedsUpdate
        )
    }

    func commitPreparedUpdate() {
        guard isActive, let pendingUpdate else { return }
        self.pendingUpdate = nil
        config = pendingUpdate.config
        if let replacementRunner = pendingUpdate.replacementRunner {
            runner = replacementRunner
        }
        if pendingUpdate.resetsRuntime {
            lastSuccessfulOutput = nil
            lastSuccessfulTitle = nil
            lastAttemptedAt = nil
            lastUpdatedAt = nil
            setTitle("–")
            setToolTip(nil)
        } else if pendingUpdate.presentationNeedsUpdate {
            lastSuccessfulTitle = lastSuccessfulOutput.map { output in
                displayTitle(for: output, format: config.format)
            }
            requestPresentationUpdate()
        }
        applyIcon()
        isPreparingUpdate = false
        if pendingUpdate.timerNeedsRestart {
            startTimer()
        }
    }

    func prepareRemoval(
        deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()
    ) async {
        guard isActive, !isPreparingRemoval else { return }
        isPreparingRemoval = true
        configurationGeneration &+= 1
        cancelRefreshTimer()
        pendingRefreshPermitTask?.cancel()

        let currentRunner = runner
        let itemName = config.name
        await settleConcurrently(
            [(
                identity: "\(itemName):primary",
                run: { [weak self] in
                    await currentRunner.cancelActive()
                    await self?.drainRefreshInvocations()
                    if let delay = self?.cancellationSettlementDelayForTesting {
                        await delay("primary")
                    }
                }
            )],
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

    func tearDown(
        deadline: ContinuousClock.Instant = LifecycleDeadline.makeInstant()
    ) async {
        await prepareRemoval(deadline: deadline)
        commitRemoval()
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

    private func startTimer(runInitialRefresh: Bool = true) {
        cancelRefreshTimer()
        switch config.interval {
        case .manual:
            if runInitialRefresh { requestRefresh() }
        case .scheduled(let interval):
            let token = CommandScheduler.ItemToken()
            refreshTimerToken = token
            let scheduler = self.scheduler
            let initialDelay = runInitialRefresh ? 0 : interval
            Task { [weak self] in
                await scheduler.registerRecurring(
                    token: token,
                    interval: interval,
                    initialDelay: initialDelay
                ) { [weak self] in
                    let item = self
                    Task { @MainActor in item?.requestRefresh() }
                }
                let isCurrent = await MainActor.run { self?.refreshTimerToken == token }
                guard isCurrent else {
                    await scheduler.cancelTimer(token)
                    return
                }
            }
        }
    }

    private func cancelRefreshTimer() {
        guard let token = refreshTimerToken else { return }
        refreshTimerToken = nil
        let scheduler = self.scheduler
        Task { await scheduler.cancelTimer(token) }
    }

    func refreshNow() {
        requestRefresh()
    }

    private func requestRefresh() {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        guard pendingRefreshPermitTask == nil else {
            let scheduler = self.scheduler
            Task { await scheduler.recordCoalesced() }
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

    private func refresh() async {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        let generation = configurationGeneration
        guard await runner.beginIfIdle() else { return }

        lastAttemptedAt = now()
        let runningSnapshot = await runner.snapshot()
        guard isActive, generation == configurationGeneration else {
            _ = await runner.finishActiveRun()
            return
        }
        renderPresentation(makeRuntimeSnapshot(runningSnapshot, isRunning: true))

        let preliminary = await runner.finishActiveRun()
        guard isActive, generation == configurationGeneration else { return }
        guard case .completed = preliminary else { return }

        // The shell can exit before same-process-group descendants and their
        // output pipes settle. Commit only the definitive session result.
        guard let execution = await runner.awaitSettledExecution() else { return }
        guard isActive, generation == configurationGeneration else { return }

        if execution.terminalReason == .exited(code: 0) {
            lastSuccessfulOutput = execution.stdout
            lastUpdatedAt = now()
            lastSuccessfulTitle = displayTitle(for: execution.stdout, format: config.format)
        }

        let snapshot = await runner.snapshot()
        guard isActive, generation == configurationGeneration else { return }
        renderPresentation(makeRuntimeSnapshot(snapshot))
    }

    private func makeRuntimeSnapshot(
        _ runnerSnapshot: CommandRunnerSnapshot,
        isRunning: Bool? = nil
    ) -> ItemRuntimeSnapshot {
        ItemRuntimeSnapshot(
            isRunning: isRunning ?? runnerSnapshot.isRunning,
            fullOutput: lastSuccessfulOutput,
            lastAttemptedAt: lastAttemptedAt,
            lastUpdatedAt: lastUpdatedAt,
            lastExecution: runnerSnapshot.lastExecution,
            skippedRefreshes: runnerSnapshot.skippedRefreshes
        )
    }

    private func renderPresentation(_ snapshot: ItemRuntimeSnapshot) {
        cachedRuntimeSnapshot = snapshot
        let baseTitle = lastSuccessfulTitle ?? "–"
        switch snapshot.status {
        case .running:
            setTitle(baseTitle)
            setToolTip("Refreshing…")
        case .fresh:
            setTitle(baseTitle)
            setToolTip(nil)
        case .error:
            setTitle(baseTitle + " ⚠︎")
            setToolTip(snapshot.errorSummary ?? "Last refresh failed")
        case .unavailable:
            setTitle("–")
            setToolTip(nil)
        }
    }

    private func displayTitle(for fullOutput: String, format: String?) -> String {
        let output = lastTrimmedLine(of: fullOutput)
        let title = applyFormat(format, output: output)
        return title.isEmpty ? "–" : title
    }

    private func requestPresentationUpdate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.runner.snapshot()
            guard self.isActive else { return }
            self.renderPresentation(self.makeRuntimeSnapshot(snapshot))
        }
    }

    func runtimeSnapshot() async -> ItemRuntimeSnapshot {
        let snapshot = makeRuntimeSnapshot(await runner.snapshot())
        renderPresentation(snapshot)
        return snapshot
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        await runner.snapshot()
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

    var pendingRefreshInvocationCountForTesting: Int { pendingRefreshInvocations }

    @objc private func handleClick() {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval, let statusItem else { return }
        menuDelegate?.showLifecycleMenu(for: statusItem)
    }

    private func applyIcon() {
        let rendered = iconRenderer.render(config.iconSource)
        iconDiagnosticNote = rendered.diagnosticNote
        iconRenderer.apply(rendered, to: statusItem?.button)
    }

    private func setTitle(_ title: String) {
        renderedTitle = title
        statusItem?.button?.title = title
    }

    private func setToolTip(_ toolTip: String?) {
        renderedToolTip = toolTip
        statusItem?.button?.toolTip = toolTip
    }

    private static func makeRunner(for config: ItemConfig) -> CommandRunner {
        CommandRunner(
            command: config.run,
            timeout: config.timeout,
            maxOutputBytes: ItemConfig.defaultMaxOutputBytes,
            shell: ItemConfig.defaultShell,
            workingDirectory: ItemConfig.defaultWorkingDirectory,
            environment: ItemConfig.defaultEnvironment
        )
    }
}
