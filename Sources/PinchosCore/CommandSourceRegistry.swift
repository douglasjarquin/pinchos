import Foundation

public struct CommandSourceIdentity: Hashable, Sendable {
    public let command: String
    public let timeout: TimeInterval
    let maxOutputBytes: Int

    public init(configuration: CommandSourceConfiguration) {
        command = configuration.command
        timeout = configuration.timeout
        maxOutputBytes = configuration.maxOutputBytes
    }
}

public struct CommandSourceLease: Sendable {
    public let source: CommandSource
    fileprivate let identity: CommandSourceIdentity
    fileprivate let token: UUID

    fileprivate init(source: CommandSource, identity: CommandSourceIdentity) {
        self.source = source
        self.identity = identity
        self.token = UUID()
    }
}

public final class CommandSourceRegistry: @unchecked Sendable {
    private struct Entry {
        let source: CommandSource
        var consumers: Set<UUID>
    }

    public static let shared = CommandSourceRegistry()

    private let lock = NSLock()
    private var entries: [CommandSourceIdentity: Entry] = [:]

    public init() {}

    public func acquire(
        configuration: CommandSourceConfiguration,
        scheduler: CommandScheduler,
        clock: any CommandSourceClock = SystemCommandSourceClock(),
        runner: (any CommandSourceRunner)? = nil
    ) -> CommandSourceLease {
        let identity = CommandSourceIdentity(configuration: configuration)
        lock.lock()
        if var entry = entries[identity] {
            let lease = CommandSourceLease(source: entry.source, identity: identity)
            entry.consumers.insert(lease.token)
            entries[identity] = entry
            lock.unlock()
            return lease
        }

        let source = CommandSource(
            configuration: configuration,
            scheduler: scheduler,
            clock: clock,
            runner: runner
        )
        let lease = CommandSourceLease(source: source, identity: identity)
        entries[identity] = Entry(source: source, consumers: [lease.token])
        lock.unlock()
        return lease
    }

    public func release(_ lease: CommandSourceLease) {
        lock.lock()
        guard var entry = entries[lease.identity], entry.consumers.remove(lease.token) != nil else {
            lock.unlock()
            return
        }
        if entry.consumers.isEmpty {
            entries.removeValue(forKey: lease.identity)
            lock.unlock()
            Task { await lease.source.cancel() }
        } else {
            entries[lease.identity] = entry
            lock.unlock()
        }
    }

    public func consumerCount(for identity: CommandSourceIdentity) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries[identity]?.consumers.count ?? 0
    }

    public var sourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
