import Foundation

public enum ByteCountParseError: Error, Equatable {
    case invalidFormat(String)
    case tooSmall(Int)
    case overflow(String)
    case tooLarge(Int)
}

/// The largest `max_output` a single stdout/stderr stream may be
/// configured to retain. Chosen so a single pathological item cannot alone
/// reserve more than half of the aggregate `OutputMemoryBudget.shared` (8
/// MiB) with just one of its two streams - a misconfigured `max_output`
/// still can't reserve unbounded memory on its own, and `OutputMemoryBudget`
/// separately bounds many-item/many-action configurations beneath the sum
/// of their individually-valid per-stream limits. The per-stream default
/// (`CommandItemConfig.defaultMaxOutputBytes`, 64 KiB) is far below this ceiling
/// and is unaffected.
public let maxAllowedOutputBytes = 4 * 1024 * 1024

public func parseByteCount(_ raw: String) throws -> Int {
    let units: [(suffix: String, multiplier: Int)] = [
        ("MiB", 1024 * 1024),
        ("KiB", 1024),
        ("B", 1)
    ]
    guard let unit = units.first(where: { raw.hasSuffix($0.suffix) }) else {
        throw ByteCountParseError.invalidFormat(raw)
    }

    let digits = raw.dropLast(unit.suffix.count)
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw ByteCountParseError.invalidFormat(raw)
    }
    guard let value = Int(digits) else {
        throw ByteCountParseError.overflow(raw)
    }
    guard value > 0 else {
        throw ByteCountParseError.tooSmall(value)
    }
    let (bytes, overflow) = value.multipliedReportingOverflow(by: unit.multiplier)
    guard !overflow else {
        throw ByteCountParseError.overflow(raw)
    }
    guard bytes <= maxAllowedOutputBytes else {
        throw ByteCountParseError.tooLarge(bytes)
    }
    return bytes
}
