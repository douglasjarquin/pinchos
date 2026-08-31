import Foundation
import XCTest
@testable import PinchosCore

final class RecipeCatalogTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func recipeFiles() throws -> [URL] {
        let directory = repoRoot.appendingPathComponent("recipes")
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return entries
            .filter { $0.pathExtension == "toml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testCatalogIsIntentionallySmallAndEveryRecipeUsesThePublicSchema() throws {
        let files = try recipeFiles()
        XCTAssertEqual(files.count, 8, "0.1.0 should carry a small canonical recipe set")

        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let config = try ConfigParser.parse(source, relativeTo: url)
            XCTAssertFalse(config.items.isEmpty, "\(url.lastPathComponent) declares no items")

            for item in config.items {
                XCTAssertFalse(item.run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(source.contains("type ="))
                XCTAssertFalse(source.contains("on_error"))
                XCTAssertFalse(source.contains("stale_after"))
                XCTAssertFalse(source.contains("working_directory"))
            }
        }
    }

    func testEveryRecipeIsLinkedFromTheCatalogIndex() throws {
        let readme = try String(
            contentsOf: repoRoot.appendingPathComponent("recipes/README.md"),
            encoding: .utf8
        )
        for url in try recipeFiles() {
            XCTAssertTrue(readme.contains(url.lastPathComponent))
        }
    }

    func testCanonicalExampleFileExactlyMatchesRuntimeExample() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("example/pinchos.toml"),
            encoding: .utf8
        )
        XCTAssertEqual(source, ExampleConfig.text)
        XCTAssertNoThrow(try ConfigParser.parse(source))
    }
}
