import AppKit
import PinchosCore

@MainActor
final class ManagedItem {
    let statusItem: NSStatusItem
    private(set) var config: ItemConfig
    private let runner: CommandRunner
    private let clickRunner: CommandRunner?
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.pinchos.item-timer")
    private weak var menuDelegate: StatusItemMenuDelegate?
    private var isActive = true

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

    func tearDown() async {
        guard isActive else { return }
        isActive = false
        timer?.cancel()
        timer = nil
        await runner.cancelActive()
        await clickRunner?.cancelActive()
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
        let currentConfig = config
        let outcome = await runner.runIfIdle()
        guard isActive else { return }
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
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            menuDelegate?.showLifecycleMenu(for: statusItem)
        } else if clickRunner != nil {
            Task { await clickRunner?.runIfIdle() }
        }
    }
}

@MainActor
protocol StatusItemMenuDelegate: AnyObject {
    func showLifecycleMenu(for statusItem: NSStatusItem)
}
