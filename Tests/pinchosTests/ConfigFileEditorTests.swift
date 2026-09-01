import XCTest
@testable import PinchosCore
@testable import pinchos

final class ConfigFileEditorTests: XCTestCase {
    func testLegacyHiddenMutationIsRejectedByTheCanonicalParser() throws {
        let source = "[item.alpha]\nrun = \"echo alpha\"\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-config-editor-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(source.utf8).write(to: url)

        try ConfigFileEditor.setHidden(
            true,
            for: ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60)),
            at: url
        )

        XCTAssertThrowsError(try ConfigParser.parse(String(contentsOf: url))) { error in
            XCTAssertTrue((error as? ConfigParseError)?.message.contains("unknown key") == true)
        }
    }
}
