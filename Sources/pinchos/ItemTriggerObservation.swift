import AppKit
import Network
import PinchosCore

enum ItemTriggerSource: Hashable, Sendable {
    case startup
    case wake
    case networkChange
    case file(String)
}

@MainActor
protocol ItemTriggerObserver: AnyObject {
    func start()
    func stop()
}

@MainActor
protocol ItemTriggerObserverFactory: AnyObject {
    func makeObserver(
        for source: ItemTriggerSource,
        onEvent: @escaping @MainActor () -> Void
    ) -> any ItemTriggerObserver
}

@MainActor
final class ItemTriggerCoordinator {
    private let observerFactory: any ItemTriggerObserverFactory
    private let debounce: Duration
    private let onRefresh: @MainActor () -> Void
    private var observers: [ItemTriggerSource: any ItemTriggerObserver] = [:]
    private var debounceTasks: [ItemTriggerSource: Task<Void, Never>] = [:]
    private var isStarted = false
    private var generation = 0

    init(
        config: CommandItemConfig,
        observerFactory: (any ItemTriggerObserverFactory)? = nil,
        debounce: Duration = .milliseconds(250),
        onRefresh: @escaping @MainActor () -> Void
    ) {
        self.observerFactory = observerFactory ?? DefaultItemTriggerObserverFactory()
        self.debounce = debounce
        self.onRefresh = onRefresh
        self.config = config
    }

    private var config: CommandItemConfig

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installObservers(for: sources(for: config))
    }

    func update(config: CommandItemConfig) {
        self.config = config
        guard isStarted else { return }

        let desired = sources(for: config)
        let current = Set(observers.keys)
        for source in current.subtracting(desired) {
            observers.removeValue(forKey: source)?.stop()
            debounceTasks.removeValue(forKey: source)?.cancel()
        }
        installObservers(for: desired.subtracting(current))
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation &+= 1
        for task in debounceTasks.values {
            task.cancel()
        }
        debounceTasks.removeAll()
        for observer in observers.values {
            observer.stop()
        }
        observers.removeAll()
    }

    private func installObservers(for sources: Set<ItemTriggerSource>) {
        for source in sources where observers[source] == nil {
            let observer = observerFactory.makeObserver(for: source) { [weak self] in
                self?.scheduleRefresh(for: source)
            }
            observers[source] = observer
            observer.start()
        }
    }

    private func scheduleRefresh(for source: ItemTriggerSource) {
        guard isStarted else { return }
        if source == .startup {
            onRefresh()
            return
        }
        debounceTasks[source]?.cancel()
        let generation = self.generation
        debounceTasks[source] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.debounce ?? .zero)
            } catch {
                return
            }
            guard let self, self.isStarted, self.generation == generation else { return }
            self.debounceTasks[source] = nil
            self.onRefresh()
        }
    }

    private func sources(for config: CommandItemConfig) -> Set<ItemTriggerSource> {
        var sources = Set(config.triggers.map { trigger -> ItemTriggerSource in
            switch trigger {
            case .startup: return .startup
            case .wake: return .wake
            case .networkChange: return .networkChange
            }
        })
        sources.formUnion(config.watch.map(ItemTriggerSource.file))
        return sources
    }
}

@MainActor
private final class StartupTriggerObserver: ItemTriggerObserver {
    private let onEvent: @MainActor () -> Void

    init(onEvent: @escaping @MainActor () -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        onEvent()
    }

    func stop() {}
}

@MainActor
private final class WakeTriggerObserver: ItemTriggerObserver {
    private let onEvent: @MainActor () -> Void
    private var token: NSObjectProtocol?

    init(onEvent: @escaping @MainActor () -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onEvent() }
        }
    }

    func stop() {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        token = nil
    }
}

@MainActor
private final class NetworkTriggerObserver: ItemTriggerObserver {
    private let onEvent: @MainActor () -> Void
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.pinchos.network-trigger")
    private var isStarted = false

    init(onEvent: @escaping @MainActor () -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.onEvent() }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
    }
}

@MainActor
private final class DefaultItemTriggerObserverFactory: ItemTriggerObserverFactory {
    func makeObserver(
        for source: ItemTriggerSource,
        onEvent: @escaping @MainActor () -> Void
    ) -> any ItemTriggerObserver {
        switch source {
        case .startup:
            return StartupTriggerObserver(onEvent: onEvent)
        case .wake:
            return WakeTriggerObserver(onEvent: onEvent)
        case .networkChange:
            return NetworkTriggerObserver(onEvent: onEvent)
        case .file(let path):
            return FileTriggerObserver(path: path, onEvent: onEvent)
        }
    }
}

@MainActor
private final class FileTriggerObserver: ItemTriggerObserver {
    private let watcher: ConfigWatcher

    init(path: String, onEvent: @escaping @MainActor () -> Void) {
        watcher = ConfigWatcher(path: path) {
            Task { @MainActor in onEvent() }
        }
    }

    func start() {
        watcher.start()
    }

    func stop() {
        watcher.stop()
    }
}
