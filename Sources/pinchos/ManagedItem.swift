import AppKit
import PinchosCore

@MainActor
final class ManagedItem: ManagedItemLifecycle {
    let statusItem: NSStatusItem
    private(set) var config: ItemConfig
    private var runner: CommandRunner
    private var clickRunner: CommandRunner?
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.pinchos.item-timer")
    private let timerFactory: (DispatchQueue) -> DispatchSourceTimer
    private weak var menuDelegate: StatusItemMenuDelegate?
    private var isActive = true
    private var configurationGeneration = 0
    private var isPreparingUpdate = false
    private var pendingUpdate: PendingUpdate?
    private var isPreparingRemoval = false
    private var pendingClickInvocations = 0
    private var clickInvocationsDrained: CheckedContinuation<Void, Never>?

    private struct PendingUpdate {
        let config: ItemConfig
        let runner: CommandRunner?
        let clickRunner: CommandRunner?
        let clickRunnerConfigurationChanged: Bool
        let timerNeedsRestart: Bool
    }

    init(
        config: ItemConfig,
        menuDelegate: StatusItemMenuDelegate,
        initiallyVisible: Bool = true,
        timerFactory: @escaping (DispatchQueue) -> DispatchSourceTimer = { queue in
            DispatchSource.makeTimerSource(queue: queue)
        }
    ) {
        self.config = config
        self.menuDelegate = menuDelegate
        self.timerFactory = timerFactory
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
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = config.errorText
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyIcon()
        statusItem.isVisible = initiallyVisible
        if initiallyVisible {
            startTimer()
        }
    }

    func activate() {
        guard isActive else { return }
        statusItem.isVisible = true
        startTimer()
    }

    func owns(statusItem: NSStatusItem) -> Bool {
        self.statusItem === statusItem
    }

    private func applyIcon() {
        guard let path = config.icon, let image = NSImage(contentsOfFile: path) else {
            statusItem.button?.image = nil
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
        if timerNeedsRestart {
            timer?.cancel()
            timer = nil
        }

        var replacementRunner: CommandRunner?
        if runnerConfigurationChanged {
            configurationGeneration &+= 1
            await runner.cancelActive()
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

        pendingUpdate = PendingUpdate(
            config: config,
            runner: replacementRunner,
            clickRunner: replacementClickRunner,
            clickRunnerConfigurationChanged: clickRunnerConfigurationChanged,
            timerNeedsRestart: timerNeedsRestart
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
        applyIcon()
        if pendingUpdate.timerNeedsRestart {
            startTimer(runInitialRefresh: false)
        }
        isPreparingUpdate = false
    }

    func prepareRemoval() async {
        guard isActive, !isPreparingRemoval else { return }
        isPreparingRemoval = true
        configurationGeneration &+= 1
        timer?.cancel()
        timer = nil
        await runner.cancelActive()
        await clickRunner?.cancelActive()
        if pendingClickInvocations > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                clickInvocationsDrained = continuation
            }
        }
    }

    func commitRemoval() {
        guard isActive else { return }
        isActive = false
        isPreparingRemoval = false
        NSStatusBar.system.removeStatusItem(statusItem)
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
                await self.tick()
            }
        }
        timer = newTimer
        newTimer.resume()
    }

    private func tick() async {
        await refresh()
    }

    func refreshNow() {
        requestRefresh()
    }

    private func requestRefresh() {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        let generation = configurationGeneration
        if !(await runner.snapshot().isRunning) {
            statusItem.button?.toolTip = "Refreshing..."
        }
        let outcome = await runner.runIfIdle()
        guard isActive, generation == configurationGeneration else { return }
        let currentConfig = config
        switch outcome {
        case .skipped:
            return
        case .completed(let execution):
            if execution.terminalReason != .exited(code: 0) {
                statusItem.button?.title = currentConfig.errorText
            } else {
                let trimmed = lastTrimmedLine(of: execution.stdout)
                statusItem.button?.title = applyFormat(currentConfig.format, output: trimmed)
            }
        }
        if !(await runner.snapshot().isRunning) {
            statusItem.button?.toolTip = nil
        }
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        await runner.snapshot()
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        processClick(eventType: event.type)
    }

    func processClick(eventType: NSEvent.EventType) {
        guard isActive, !isPreparingUpdate, !isPreparingRemoval else { return }
        if eventType == .rightMouseUp {
            menuDelegate?.showLifecycleMenu(for: statusItem)
        } else if clickRunner != nil {
            guard let clickRunner else { return }
            pendingClickInvocations += 1
            Task { @MainActor [weak self, clickRunner] in
                defer { self?.finishClickInvocation() }
                guard let self, self.isActive else { return }
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
}
