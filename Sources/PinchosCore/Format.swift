import Foundation

public func applyFormat(_ template: String?, output: String) -> String {
    guard let template else { return output }
    return template.replacingOccurrences(of: "{output}", with: output)
}
