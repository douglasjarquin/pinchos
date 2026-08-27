import XCTest
@testable import PinchosCore

final class StructuredOutputTests: XCTestCase {
    func testParsesV1PresentationFieldsAndDeclarativeActions() throws {
        let output = try StructuredOutputParser.parse(#"""
        {
          "version": 1,
          "text": "81%",
          "tooltip": "Weekly quota resets Monday",
          "state": "warning",
          "hidden": false,
          "symbol": "chart.bar.fill",
          "actions": [
            { "title": "Open usage", "run": "open https://example.com/usage" },
            { "title": "Refresh", "refresh": true }
          ]
        }
        """#)

        XCTAssertEqual(output.text, "81%")
        XCTAssertEqual(output.tooltip, "Weekly quota resets Monday")
        XCTAssertEqual(output.state, .warning)
        XCTAssertEqual(output.hidden, false)
        XCTAssertEqual(output.iconSource, .symbol("chart.bar.fill"))
        XCTAssertEqual(output.actions, [
            ItemAction(title: "Open usage", kind: .command("open https://example.com/usage")),
            ItemAction(title: "Refresh", kind: .refresh)
        ])
    }

    func testV1IgnoresUnknownFieldsForAdditiveSchemaEvolution() throws {
        let output = try StructuredOutputParser.parse(#"""
        {
          "version": 1,
          "text": "ok",
          "future_field": { "not": "part of v1" }
        }
        """#)

        XCTAssertEqual(output.text, "ok")
        XCTAssertNil(output.tooltip)
    }

    func testRequiresVersionOne() {
        assertParseError(#"{"text":"missing"}"#, .missingVersion)
        assertParseError(#"{"version":2,"text":"future"}"#, .unsupportedVersion(2))
    }

    func testRejectsMalformedFieldsAndActionsWithUsefulErrors() {
        assertParseError(#"{"version":1,"state":"warning-ish"}"#, .invalidField("state", "'normal', 'warning', or 'error'"))
        assertParseError(#"{"version":1,"icon":"a","symbol":"b"}"#, .conflictingIconSources)
        assertParseError(#"{"version":1,"actions":[{"title":"Bad"}]}"#, .invalidAction(index: 0, reason: "specify 'run' or 'refresh': true"))
        assertParseError(#"{"version":1,"actions":[{"title":"Bad","run":"x","refresh":true}]}"#, .invalidAction(index: 0, reason: "specify either 'run' or 'refresh', not both"))
    }

    func testMalformedJSONFailsAsStructuredOutputError() {
        assertParseError("not json", .invalidJSON)
    }

    private func assertParseError(
        _ text: String,
        _ expected: StructuredOutputParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try StructuredOutputParser.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? StructuredOutputParseError, expected, file: file, line: line)
            XCTAssertFalse((error as? StructuredOutputParseError)?.description.isEmpty ?? true, file: file, line: line)
        }
    }
}
