import Foundation

/// Process-wide cap on the aggregate bytes every `TailByteBuffer` may
/// collectively reserve for storage, regardless of how many buffers exist
/// or how large any individual buffer's configured `capacity` is.
///
/// A `TailByteBuffer` only reserves storage as it actually needs to grow
/// (never eagerly for its full configured `capacity`) and releases its
/// reservation back once deallocated. `OutputMemoryBudget` exists so many
/// independently-bounded per-stream limits (primary/click/action runners,
/// each with an independent stdout and stderr collector) cannot together
/// retain an unbounded multiple of any single configured limit: once the
/// shared budget is exhausted, a buffer silently retains less than its
/// nominal capacity instead of growing further.
public final class OutputMemoryBudget: @unchecked Sendable {
    /// The default aggregate budget shared by every command runner in the
    /// process. Sized well above the default three-item workload (2
    /// streams x `ItemConfig.defaultMaxOutputBytes` = 128KiB per item, or
    /// ~384KiB total) while still bounding a pathological many-item or
    /// many-action configuration far below what summing every configured
    /// `max_output` would otherwise allow. See README "Output memory
    /// budget".
    public static let shared = OutputMemoryBudget(totalBytes: 8 * 1024 * 1024)

    public let totalBytes: Int
    private let lock = NSLock()
    private var reservedBytes = 0

    public init(totalBytes: Int) {
        precondition(totalBytes >= 0, "OutputMemoryBudget totalBytes must not be negative")
        self.totalBytes = totalBytes
    }

    /// Requests up to `amount` additional bytes of aggregate capacity.
    /// Returns the amount actually granted, which may be less than
    /// requested - including zero - once the aggregate budget is
    /// exhausted by every buffer sharing it.
    func reserve(upTo amount: Int) -> Int {
        guard amount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let available = max(0, totalBytes - reservedBytes)
        let granted = min(amount, available)
        reservedBytes += granted
        return granted
    }

    func release(_ amount: Int) {
        guard amount > 0 else { return }
        lock.lock()
        reservedBytes = max(0, reservedBytes - amount)
        lock.unlock()
    }

    /// Bytes currently reserved across every buffer sharing this budget.
    /// For diagnostics only - capacity decisions always go through
    /// `reserve`/`release`, which stay internally consistent under
    /// concurrent access even though this snapshot can be stale by the
    /// time a caller observes it.
    public var reservedBytesSnapshot: Int {
        lock.lock()
        defer { lock.unlock() }
        return reservedBytes
    }
}

/// A fixed-maximum-capacity byte buffer that retains only the most recent
/// `capacity` bytes ever appended ("tail" semantics), backed by a single
/// contiguous circular array instead of a `Data` value that gets fully
/// recopied on every overflowing append.
///
/// `append` costs O(new bytes) amortized, not O(capacity): bytes are
/// written directly into (and evicted directly from) ring-buffer slots
/// rather than triggering a fresh `Data(retained.suffix(capacity))` copy of
/// the entire retained tail on every chunk once the buffer is full. The
/// buffer only reallocates when it needs to grow its actual storage, which
/// happens by doubling (like `Array`) and therefore at most
/// O(log(capacity)) times over the buffer's lifetime. `snapshot()` is the
/// only O(capacity) operation, and only runs when a caller actually wants
/// the retained bytes materialized - never from the hot append path.
///
/// Storage is never eagerly allocated at the full configured `capacity`;
/// it grows only as data actually arrives, and each growth step is gated
/// by an optional `OutputMemoryBudget` shared across every buffer in the
/// process.
///
/// ## UTF-8 at a truncated boundary
///
/// Retained bytes are decoded with `String(decoding:as: UTF8.self)`
/// wherever this buffer's snapshot becomes a `CommandExecution.stdout`/
/// `stderr`. When the retained tail begins inside a multi-byte UTF-8
/// scalar (a lone continuation byte with no preceding lead byte), that
/// decoder deterministically substitutes U+FFFD (the replacement
/// character) for the orphaned byte(s) rather than throwing or merging
/// them with unrelated neighboring bytes. This is standard library
/// behavior, not something this type special-cases, and it is exercised in
/// `TailByteBufferTests`.
struct TailByteBuffer {
    let capacity: Int
    private let budget: OutputMemoryBudget?
    private var storage: [UInt8] = []
    private var head = 0
    private(set) var count = 0
    private(set) var reservedCapacity = 0
    /// Set once any byte is ever dropped, whether because `capacity` was
    /// reached or because the shared budget capped this buffer's storage
    /// below `capacity`. Never cleared.
    private(set) var didEvict = false

    init(capacity: Int, budget: OutputMemoryBudget? = nil) {
        precondition(capacity > 0, "TailByteBuffer capacity must be positive")
        self.capacity = capacity
        self.budget = budget
    }

    var isEmpty: Bool { count == 0 }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }

        ensureReservedCapacity(atLeast: min(capacity, count + bytes.count))

        guard reservedCapacity > 0 else {
            // The shared budget granted nothing at all; every incoming byte
            // is dropped, but that is still eviction, not silent loss.
            didEvict = true
            return
        }

        var incoming = bytes
        if incoming.count >= reservedCapacity {
            // This single chunk fills (or exceeds) all reserved capacity on
            // its own, so anything previously retained is evicted, along
            // with everything but the tail of this chunk.
            didEvict = didEvict || count > 0 || incoming.count > reservedCapacity
            incoming = UnsafeRawBufferPointer(rebasing: incoming[(incoming.count - reservedCapacity)...])
            head = 0
            count = 0
            write(incoming, startingAt: 0)
            count = incoming.count
            return
        }

        let overflow = max(0, count + incoming.count - reservedCapacity)
        if overflow > 0 {
            didEvict = true
            head = (head + overflow) % reservedCapacity
            count -= overflow
        }
        let writePosition = (head + count) % reservedCapacity
        write(incoming, startingAt: writePosition)
        count += incoming.count
    }

    /// Materializes the retained tail in order, oldest byte first. The only
    /// O(capacity) operation on this type; call it only when a caller
    /// actually needs the bytes (e.g. an execution snapshot), never from
    /// the hot append/drain loop.
    func snapshot() -> Data {
        guard count > 0 else { return Data() }
        var result = [UInt8](repeating: 0, count: count)
        result.withUnsafeMutableBytes { destination in
            copyOut(into: destination)
        }
        return Data(result)
    }

    private func copyOut(into destination: UnsafeMutableRawBufferPointer) {
        guard count > 0, let destinationBase = destination.baseAddress else { return }
        storage.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            let firstRun = min(count, storage.count - head)
            destinationBase.copyMemory(from: sourceBase + head, byteCount: firstRun)
            if firstRun < count {
                destinationBase.advanced(by: firstRun).copyMemory(from: sourceBase, byteCount: count - firstRun)
            }
        }
    }

    private mutating func write(_ source: UnsafeRawBufferPointer, startingAt writePosition: Int) {
        guard reservedCapacity > 0, !source.isEmpty, let sourceBase = source.baseAddress else { return }
        storage.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            var position = writePosition
            var remaining = source.count
            var offset = 0
            while remaining > 0 {
                let chunk = min(remaining, reservedCapacity - position)
                destinationBase.advanced(by: position).copyMemory(from: sourceBase.advanced(by: offset), byteCount: chunk)
                position = (position + chunk) % reservedCapacity
                offset += chunk
                remaining -= chunk
            }
        }
    }

    /// Grows `reservedCapacity` towards `wanted` (capped at `capacity`) by
    /// doubling, requesting only the incremental bytes needed from
    /// `budget`. Doubling keeps the amortized cost of many small appends
    /// (e.g. repeated one-byte appends) O(1) even though each individual
    /// growth step copies the buffer's current contents.
    private mutating func ensureReservedCapacity(atLeast wanted: Int) {
        let target = min(wanted, capacity)
        guard target > reservedCapacity else { return }

        var candidate = max(reservedCapacity, 1)
        while candidate < target {
            candidate = candidate >= capacity / 2 ? capacity : candidate * 2
        }
        let increment = candidate - reservedCapacity
        guard increment > 0 else { return }
        let granted = budget?.reserve(upTo: increment) ?? increment
        guard granted > 0 else { return }
        growStorage(by: granted)
    }

    private mutating func growStorage(by additional: Int) {
        let newCapacity = reservedCapacity + additional
        var newStorage = [UInt8](repeating: 0, count: newCapacity)
        if count > 0 {
            newStorage.withUnsafeMutableBytes { destination in
                copyOut(into: UnsafeMutableRawBufferPointer(rebasing: destination[0..<count]))
            }
        }
        storage = newStorage
        head = 0
        reservedCapacity = newCapacity
    }
}
