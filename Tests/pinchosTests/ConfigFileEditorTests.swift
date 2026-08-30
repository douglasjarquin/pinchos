import XCTest
@testable import PinchosCore
@testable import pinchos

final class ConfigFileEditorTests: XCTestCase {
    private func writeConfig(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinchos-config-editor-\(UUID().uuidString).toml")
        try Data(source.utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testSetsHiddenInAnItemTableAndPreservesTheSurroundingConfig() throws {
        let source = """
        # Keep this comment.
        [item.alpha]
        type = "command"
        run = "echo alpha"
        hidden = false # Keep this note.

        [item.beta]
        type = "command"
        run = "echo beta"
        """
        let url = try writeConfig(source)
        let alpha = ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60))

        try ConfigFileEditor.setHidden(true, for: alpha, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("hidden = true # Keep this note."))
        XCTAssertTrue(updated.contains("[item.beta]\ntype = \"command\"\nrun = \"echo beta\""))
        XCTAssertTrue(try ConfigParser.parse(updated).items[0].hidden)
        XCTAssertFalse(try ConfigParser.parse(updated).items[1].hidden)
    }

    func testInsertsHiddenBeforeNestedItemTables() throws {
        let source = """
        [item."my.clock"]
        type = "command"
        run = "date"

        [item."my.clock".env]
        TZ = "UTC"
        """
        let url = try writeConfig(source)
        let item = ItemConfig(name: "my.clock", run: "date", interval: .scheduled(60))

        try ConfigFileEditor.setHidden(true, for: item, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("[item.\"my.clock\"]\nhidden = true\ntype = \"command\""))
        XCTAssertTrue(try ConfigParser.parse(updated).items[0].hidden)
    }

    func testUpdatesDottedItemDeclaration() throws {
        let source = """
        item."my.clock".type = "command"
        item."my.clock".run = "date"

        [item.other]
        type = "command"
        run = "echo other"
        """
        let url = try writeConfig(source)
        let item = ItemConfig(name: "my.clock", run: "date", interval: .scheduled(60))

        try ConfigFileEditor.setHidden(true, for: item, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("item.\"my.clock\".hidden = true\n\n[item.other]"))
        XCTAssertTrue(try ConfigParser.parse(updated).items[0].hidden)
        XCTAssertFalse(try ConfigParser.parse(updated).items[1].hidden)
    }

    func testUpdatesExistingDottedItemHiddenDeclaration() throws {
        let source = """
        item."my.clock".type = "command"
        item."my.clock".run = "date"
        item."my.clock".hidden = false
        """
        let url = try writeConfig(source)
        let item = ItemConfig(name: "my.clock", run: "date", interval: .scheduled(60))

        try ConfigFileEditor.setHidden(true, for: item, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("item.\"my.clock\".hidden = true"))
        XCTAssertFalse(updated.contains("\nhidden = true"))
        let parsed = try ConfigParser.parse(updated)
        XCTAssertEqual(parsed.items.map(\.name), ["my.clock"])
        XCTAssertTrue(parsed.items[0].hidden)
    }

    func testSetsHiddenOnAGroupTable() throws {
        let source = """
        [item.alpha]
        type = "command"
        run = "echo alpha"

        [group.all]
        title = "All"
        members = ["alpha"]
        """
        let url = try writeConfig(source)
        let group = ItemConfig.group(GroupItemConfig(name: "all", title: "All", members: ["alpha"]))

        try ConfigFileEditor.setHidden(true, for: group, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("[group.all]\nhidden = true\ntitle = \"All\""))
        XCTAssertTrue(try ConfigParser.parse(updated).items[1].hidden)
    }

    func testUpdatesExistingDottedGroupHiddenDeclaration() throws {
        let source = """
        item.alpha.type = "command"
        item.alpha.run = "echo alpha"
        group."all".title = "All"
        group."all".members = ["alpha"]
        group."all".hidden = false
        """
        let url = try writeConfig(source)
        let group = ItemConfig.group(GroupItemConfig(name: "all", title: "All", members: ["alpha"]))

        try ConfigFileEditor.setHidden(true, for: group, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("group.\"all\".hidden = true"))
        XCTAssertFalse(updated.contains("\nhidden = true"))
        let parsed = try ConfigParser.parse(updated)
        XCTAssertEqual(parsed.items.map(\.name), ["alpha", "all"])
        XCTAssertTrue(parsed.items[1].hidden)
    }

    func testMissingItemIsReportedWithoutChangingTheFile() throws {
        let source = """
        [item.alpha]
        type = "command"
        run = "echo alpha"
        """
        let url = try writeConfig(source)
        let missing = ItemConfig(name: "missing", run: "echo missing", interval: .scheduled(60))

        XCTAssertThrowsError(try ConfigFileEditor.setHidden(true, for: missing, at: url)) { error in
            guard case let ConfigFileEditError.itemNotFound(namespace, name) = error else {
                return XCTFail("expected an item-not-found error, got \(error)")
            }
            XCTAssertEqual(namespace, "item")
            XCTAssertEqual(name, "missing")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }

    func testIgnoresMultilineMarkersInComments() throws {
        let source = "# \"\"\"\n\n[item.alpha]\ntype = \"command\"\nrun = \"echo alpha\"\n"
        let url = try writeConfig(source)
        let item = ItemConfig(name: "alpha", run: "echo alpha", interval: .scheduled(60))

        try ConfigFileEditor.setHidden(true, for: item, at: url)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("[item.alpha]\nhidden = true\ntype = \"command\""))
        XCTAssertTrue(try ConfigParser.parse(updated).items[0].hidden)
    }

    func testConditionalReplaceRefusesAChangedSourceWithoutOverwritingIt() throws {
        let original = "[item.alpha]\nhidden = false\n"
        let changed = "[item.alpha]\nhidden = false\nrun = \"echo changed\"\n"
        let url = try writeConfig(changed)

        XCTAssertThrowsError(
            try ConfigFileEditor.replaceIfUnchanged(
                originalData: Data(original.utf8),
                updatedData: Data("[item.alpha]\nhidden = true\n".utf8),
                at: url
            )
        ) { error in
            guard case let ConfigFileEditError.sourceChanged(path) = error else {
                return XCTFail("expected a source-changed error, got \(error)")
            }
            XCTAssertEqual(path, url.path)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
    }
}
