import Foundation

/// A `launchd` per-user LaunchAgent property list, restricted to the keys
/// Pinchos actually sets. Modeled as `Codable` (rather than hand-built XML)
/// so generation and parsing share one schema and round-trip exactly.
struct LaunchAgentPlistDocument: Codable, Equatable {
    var label: String
    var programArguments: [String]
    var runAtLoad: Bool
    var workingDirectory: String
    var standardOutPath: String
    var standardErrorPath: String
    var environmentVariables: [String: String]

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case programArguments = "ProgramArguments"
        case runAtLoad = "RunAtLoad"
        case workingDirectory = "WorkingDirectory"
        case standardOutPath = "StandardOutPath"
        case standardErrorPath = "StandardErrorPath"
        case environmentVariables = "EnvironmentVariables"
    }

    func encodedPlist() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) -> LaunchAgentPlistDocument? {
        try? PropertyListDecoder().decode(LaunchAgentPlistDocument.self, from: data)
    }
}
