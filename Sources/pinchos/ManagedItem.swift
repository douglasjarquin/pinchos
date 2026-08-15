import AppKit
import PinchosCore

@MainActor
final class ManagedItem {
    let statusItem: NSStatusItem
    private(set) var config: ItemConfig
    private var runner: CommandRunner
    private var clickRunner: CommandRunner?
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.pinchos.item-timer")
    private weak var menuDelegate: StatusItemMenuDelegate?
    private var isActive = true
    private var configurationGeneration = 0
    private var pendingClickInvocations = 0
    private var clickInvocationsDrained: CheckedContinuation<Void, Never>?

    init(config: ItemConfig, menuDelegate: StatusItemMenuDelegate) {
        self.config = config
        self.menuDelegate = menuDelegate
        self.runner = CommandRunner(
            command: config.run,
            timeout: config.timeout,
            maxOutputBytes: config.maxOutputBytes
        )
        if let click = config.click {
            self.clickRunner = CommandRunner(
                command: click,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes
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
        startTimer()
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

    func update(config: ItemConfig) async {
        guard isActive else { return }

        let previousConfig = self.config
        configurationGeneration &+= 1

        let runnerConfigurationChanged = previousConfig.run != config.run
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
        await runner.cancelActive()
        if runnerConfigurationChanged {
            runner = CommandRunner(
                command: config.run,
                timeout: config.timeout,
                maxOutputBytes: config.maxOutputBytes
            )
        }

        let clickRunnerConfigurationChanged = previousConfig.click != config.click
            || previousConfig.timeout != config.timeout
            || previousConfig.maxOutputBytes != config.maxOutputBytes
        if clickRunnerConfigurationChanged {
            await clickRunner?.cancelActive()
            clickRunner = config.click.map {
                CommandRunner(
                    command: $0,
                    timeout: config.timeout,
                    maxOutputBytes: config.maxOutputBytes
                )
            }
        }

        self.config = config
        applyIcon()
        startTimer()
    }

    func tearDown() async {
        guard isActive else { return }
        isActive = false
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
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func startTimer() {
        timer?.cancel()
        let newTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        newTimer.schedule(deadline: .now(), repeating: config.interval)
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
        guard isActive else { return }
        let generation = configurationGeneration
        let currentConfig = config
        let outcome = await runner.runIfIdle()
        guard isActive, generation == configurationGeneration else { return }
        switch outcome {
        case .skipped:
            return
        case .completed(let execution):
            guard execution.terminalReason == .exited(code: 0) else {
                statusItem.button?.title = currentConfig.errorText
                return
            }
            let trimmed = lastTrimmedLine(of: execution.stdout)
            statusItem.button?.title = applyFormat(currentConfig.format, output: trimmed)
        }
    }

    func runnerSnapshot() async -> CommandRunnerSnapshot {
        await runner.snapshot()
    }

    @objc private func handleClick() {
        guard isActive else { return }
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            menuDelegate?.showLifecycleMenu(for: statusItem)
        } else if clickRunner != nil {
            guard let clickRunner else { return }
            pendingClickInvocations += 1
            Task { @MainActor [weak self, clickRunner] in
                defer { self?.finishClickInvocation() }
                guard let self, self.isActive else { return }
                _ = await clickRunner.runIfIdle()
            }
        }
    }

    private func finishClickInvocation() {
        pendingClickInvocations -= 1
        guard pendingClickInvocations == 0, let continuation = clickInvocationsDrained else { return }
        clickInvocationsDrained = nil
        continuation.resume()
    }
}

@MainActor
protocol StatusItemMenuDelegate: AnyObject {
    func showLifecycleMenu(for statusItem: NSStatusItem)
}
