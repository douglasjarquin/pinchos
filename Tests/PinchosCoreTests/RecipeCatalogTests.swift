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

    func testEveryRecipeParsesWithConfigParser() throws {
        for recipeURL in try recipeFiles() {
            let text = try String(contentsOf: recipeURL, encoding: .utf8)
            let config: PinchosConfig
            do {
                config = try ConfigParser.parse(text, relativeTo: recipeURL)
            } catch {
                XCTFail("\(recipeURL.lastPathComponent) failed to parse: \(error)")
                continue
            }
            XCTAssertFalse(
                config.items.isEmpty,
                "\(recipeURL.lastPathComponent) declares no [item.<name>] tables"
            )
        }
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
    }

}
