import AppKit
import PinchosCore

@MainActor
final class ManagedItem: ManagedItemLifecycle {
    let statusItem: NSStatusItem?
    private(set) var renderedTitle: String
    private(set) var renderedToolTip: String?
    private(set) var config: ItemConfig
    private var runner: CommandRunner
    private var clickRunner: CommandRunner?
    private var actionRunners: [Int: CommandRunner]
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.pinchos.item-timer")
    private let timerFactory: (DispatchQueue) -> DispatchSourceTimer
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
        timerFactory: @escaping (DispatchQueue) -> DispatchSourceTimer = { queue in
            DispatchSource.makeTimerSource(queue: queue)
        },
        now: @escaping () -> Date = Date.init,
        statusItemFactory: @escaping () -> NSStatusItem? = {
            NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
    ) {
        self.config = config
        self.menuDelegate = menuDelegate
        self.timerFactory = timerFactory
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
        statusItem?.button?.title = config.errorText
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleClick)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyIcon()
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
        guard let ownedStatusItem = self.statusItem else { return false }
        return ownedStatusItem === statusItem
    }

    private func applyIcon() {
        guard let statusItem, let path = config.icon, let image = NSImage(contentsOfFile: path) else {
            statusItem?.button?.image = nil
            return
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeft
    }

    func prepareUpdate(config: ItemConfig) async {
        guard isActive, !isPreparingRemoval, pendingUpdate == nil else { return }

        let previousConfig = self.config
        isPreparingUpdate = true

        let runnerConfigurationChanged = previousConfig.run != config.run
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
            || previousConfig.shell != config.shell
            || previousConfig.workingDirectory != config.workingDirectory
            || previousConfig.environment != config.environment
        let timerNeedsRestart = runnerConfigurationChanged || previousConfig.interval != config.interval
        let staleAfterChanged = previousConfig.staleAfter != config.staleAfter || runnerConfigurationChanged
        let presentationNeedsUpdate = previousConfig.format != config.format
            || previousConfig.errorText != config.errorText
            || previousConfig.onError != config.onError
            || previousConfig.staleAfter != config.staleAfter
            || previousConfig.tooltip != config.tooltip
        if timerNeedsRestart {
            timer?.cancel()
            timer = nil
        }

        var replacementRunner: CommandRunner?
        if runnerConfigurationChanged {
            configurationGeneration &+= 1
            await runner.cancelActive()
            await drainRefreshInvocations()
            replacementRunner = CommandRunner(
                command: config.run,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes,
                shell: config.shell,
                workingDirectory: config.workingDirectory,
                environment: config.environment
            )
        }

        let clickRunnerConfigurationChanged = previousConfig.click != config.click
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
            || previousConfig.shell != config.shell
            || previousConfig.workingDirectory != config.workingDirectory
            || previousConfig.environment != config.environment
        if clickRunnerConfigurationChanged {
            await clickRunner?.cancelActive()
        }
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
        if actionRunnersConfigurationChanged {
            for actionRunner in actionRunners.values {
                await actionRunner.cancelActive()
            }
        }
        let replacementActionRunners = actionRunnersConfigurationChanged
            ? Self.makeActionRunners(for: config)
            : nil

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

    func prepareRemoval() async {
        guard isActive, !isPreparingRemoval else { return }
        isPreparingRemoval = true
        configurationGeneration &+= 1
        stalePresentationTask?.cancel()
        stalePresentationTask = nil
        timer?.cancel()
        timer = nil
        await runner.cancelActive()
        await drainRefreshInvocations()
        await clickRunner?.cancelActive()
        for actionRunner in actionRunners.values {
            await actionRunner.cancelActive()
        }
        if pendingClickInvocations > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                clickInvocationsDrained = continuation
            }
        }
        if pendingActionInvocations > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                actionInvocationsDrained = continuation
            }
        }
    }

    func commitRemoval() {
        guard isActive else { return }
        isActive = false
        isPreparingRemoval = false
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func tearDown() async {
        await prepareRemoval()
        commitRemoval()
    }

    private func startTimer(runInitialRefresh: Bool = true) {
        timer?.cancel()
        timer = nil
        guard case .scheduled(let interval) = config.interval else {
            if runInitialRefresh {
                requestRefresh()
            }
            return
        }
        let newTimer = timerFactory(timerQueue)
        newTimer.schedule(deadline: .now(), repeating: interval)
        newTimer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.tick()
            }
        }
        timer = newTimer
        newTimer.resume()
    }

    private func tick() {
        requestRefresh()
    }

    func refreshNow() {
        requestRefresh()
    }

    private func requestRefresh() {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        pendingRefreshInvocations += 1
        Task { @MainActor [self] in
            defer { finishRefreshInvocation() }
            await refresh()
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
        setTitle(baseTitle + marker)
        setToolTip(renderTooltip(config.tooltip, state: snapshot))
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

    func invokeAction(at index: Int) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval,
            config.actions.indices.contains(index)
        else {
            return
        }
        switch config.actions[index].kind {
        case .refresh:
            refreshNow()
        case .command:
            guard let actionRunner = actionRunners[index] else { return }
            pendingActionInvocations += 1
            Task { @MainActor [weak self, actionRunner] in
                defer { self?.finishActionInvocation() }
                guard let self,
                    self.isActive,
                    !self.isPreparingUpdate,
                    !self.isPreparingRemoval,
                    self.actionRunners[index] === actionRunner
                else {
                    return
                }
                _ = await actionRunner.runIfIdle()
            }
        }
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
        } else if clickRunner != nil {
            guard let clickRunner else { return }
            pendingClickInvocations += 1
            Task { @MainActor [weak self, clickRunner] in
                defer { self?.finishClickInvocation() }
                guard let self,
                    self.isActive,
                    !self.isPreparingUpdate,
                    !self.isPreparingRemoval,
                    self.clickRunner === clickRunner
                else {
                    return
                }
                _ = await clickRunner.runIfIdle()
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
        statusItem?.button?.title = title
    }

    private func setToolTip(_ toolTip: String?) {
        renderedToolTip = toolTip
        statusItem?.button?.toolTip = toolTip
    }
}
