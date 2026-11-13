import Foundation
import XCTest
@testable import PinchosCore

final class RecipeCatalogTests: XCTestCase {
    private var repoRoot: URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func recipeFiles() throws -> [URL] {
        let recipesDirectory = repoRoot.appendingPathComponent("recipes")
        let entries = try FileManager.default.contentsOfDirectory(
            at: recipesDirectory,
            includingPropertiesForKeys: nil
        )
        let recipes = entries.filter { $0.pathExtension == "toml" }.sorted { $0.path < $1.path }
        XCTAssertFalse(recipes.isEmpty, "expected at least one recipe under \(recipesDirectory.path)")
        XCTAssertEqual(recipes.count, 9, "expected the maintained recipes under \(recipesDirectory.path)")
        return recipes
    }

    private func exampleFiles() -> [URL] {
        [repoRoot.appendingPathComponent("example/pinchos.toml")]
    }

    func testEveryRecipeAndExampleParsesWithConfigParser() throws {
        let catalog = try recipeFiles() + exampleFiles()
        XCTAssertEqual(catalog.count, 10, "expected nine recipes plus the canonical example")
        for fileURL in catalog {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let config: PinchosConfig
            do {
                config = try ConfigParser.parse(text, relativeTo: fileURL)
            } catch {
                XCTFail("\(fileURL.lastPathComponent) failed to parse: \(error)")
                continue
            }
            XCTAssertFalse(
                config.items.isEmpty,
                "\(fileURL.lastPathComponent) declares no [item.<name>] tables"
            )
        }
        XCTAssertNoThrow(try ConfigParser.parse(ExampleConfig.text))
    }

    func testEveryRecipeItemHasANonEmptyRunCommand() throws {
        for recipeURL in try recipeFiles() {
            let text = try String(contentsOf: recipeURL, encoding: .utf8)
            let config = try ConfigParser.parse(text, relativeTo: recipeURL)
            for entry in config.items {
                let item = entry
                XCTAssertFalse(
                    item.run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(recipeURL.lastPathComponent): item.\(item.name) has an empty run command"
                )
                XCTAssertNil(
                    item.icon,
                    "\(recipeURL.lastPathComponent): item.\(item.name) sets an icon, which recipes must avoid"
                )
                XCTAssertNil(
                    item.symbol,
                    "\(recipeURL.lastPathComponent): item.\(item.name) sets a symbol, which recipes must avoid"
                )
            }
        }
    }

    func testEveryRecipeFileIsLinkedFromTheCatalogIndex() throws {
        let readmeURL = repoRoot.appendingPathComponent("recipes/README.md")
        let readmeText = try String(contentsOf: readmeURL, encoding: .utf8)

        for recipeURL in try recipeFiles() {
            let filename = recipeURL.lastPathComponent
            XCTAssertTrue(
                readmeText.contains(filename),
                "recipes/README.md does not mention \(filename)"
            )
        }
        XCTAssertTrue(
            readmeText.contains("config_root=\"$(mktemp -d)\""),
            "recipes/README.md should create one named temporary config root"
        )
        XCTAssertTrue(
            readmeText.contains("cp recipes/clock.toml \"$config_root/pinchos/pinchos.toml\""),
            "recipes/README.md should place the recipe at the named path before validate"
        )
        XCTAssertTrue(
            readmeText.contains("XDG_CONFIG_HOME=\"$config_root\" .build/release/pinchos validate"),
            "recipes/README.md should validate with the same named path"
        )
    }

}
