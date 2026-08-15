import Foundation

public enum ByteCountParseError: Error, Equatable {
    case invalidFormat(String)
    case tooSmall(Int)
    case overflow(String)
}

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
    return bytes
}
