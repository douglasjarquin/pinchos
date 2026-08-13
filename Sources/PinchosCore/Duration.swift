import Foundation

public enum DurationParseError: Error, Equatable {
    case invalidFormat(String)
    case tooSmall(TimeInterval)
}

private let minimumInterval: TimeInterval = 1

public func parseDuration(_ raw: String) throws -> TimeInterval {
    guard let unit = raw.last, let digits = raw.dropLast().wholeNumberValueIfAllDigits else {
        throw DurationParseError.invalidFormat(raw)
    }

    let multiplier: TimeInterval
    switch unit {
    case "s": multiplier = 1
    case "m": multiplier = 60
    case "h": multiplier = 3600
    default:
        throw DurationParseError.invalidFormat(raw)
    }

    let interval = TimeInterval(digits) * multiplier
    guard interval >= minimumInterval else {
        throw DurationParseError.tooSmall(interval)
    }
    return interval
}

private extension Substring {
    var wholeNumberValueIfAllDigits: Int? {
        guard !isEmpty, allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(self)
    }
}
