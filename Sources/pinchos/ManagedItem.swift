import AppKit
import PinchosCore

@MainActor
final class ManagedItem {
    let statusItem: NSStatusItem
    private(set) var config: ItemConfig
    private let runner = CommandRunner()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.pinchos.item-timer")
    private weak var menuDelegate: StatusItemMenuDelegate?

    init(config: ItemConfig, menuDelegate: StatusItemMenuDelegate) {
        self.config = config
        self.menuDelegate = menuDelegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = config.errorText
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        startTimer()
    }

    func updateConfig(_ newConfig: ItemConfig) {
        config = newConfig
        startTimer()
    }

    func tearDown() {
        timer?.cancel()
        timer = nil
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
        let currentConfig = config
        guard let result = await runner.runIfIdle(currentConfig.run) else { return }
        switch result {
        case .success(let output):
            let trimmed = lastTrimmedLine(of: output)
            statusItem.button?.title = applyFormat(currentConfig.format, output: trimmed)
        case .failure:
            statusItem.button?.title = currentConfig.errorText
        }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            menuDelegate?.showLifecycleMenu(for: statusItem)
        } else if let click = config.click {
            runFireAndForget(click)
        }
    }
}

@MainActor
protocol StatusItemMenuDelegate: AnyObject {
    func showLifecycleMenu(for statusItem: NSStatusItem)
}
