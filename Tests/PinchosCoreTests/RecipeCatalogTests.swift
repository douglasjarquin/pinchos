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
        XCTAssertGreaterThanOrEqual(recipes.count, 50, "expected at least 50 recipes under \(recipesDirectory.path)")
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
                guard case .command(let item) = entry else { continue }
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
                XCTAssertNil(
                    item.workingDirectory,
                    "\(recipeURL.lastPathComponent): item.\(item.name) sets working_directory, which recipes must avoid"
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

    func testDisplayCountRecipeCountsIndividualDisplays() throws {
        let recipeURL = repoRoot.appendingPathComponent("recipes/display-count.toml")
        let config = try ConfigParser.parse(
            String(contentsOf: recipeURL, encoding: .utf8),
            relativeTo: recipeURL
        )
        let run = try XCTUnwrap(config.items.first(where: { $0.name == "displays" })?.command.run)
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-system-profiler-\(UUID().uuidString).txt")
        let fixture = """
        Graphics/Displays:

            Apple M3 Max:

              Displays:
                Color LCD:
                  Resolution: 3456 x 2234 Retina
                Studio Display:
                  Resolution: 5120 x 2880
        """
        try fixture.write(to: fixtureURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let command = run.replacingOccurrences(
            of: "system_profiler SPDisplaysDataType",
            with: "cat '\(fixtureURL.path)'"
        )
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output, "2")
    }
}
