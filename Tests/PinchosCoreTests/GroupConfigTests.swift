import XCTest
@testable import PinchosCore

final class GroupConfigTests: XCTestCase {
    func testGroupTablesAreRejectedByTheCanonicalSchema() {
        let text = """
        [group.all]
        title = "All"
        members = ["clock"]
        """

        XCTAssertThrowsError(try ConfigParser.parse(text)) { error in
            let parseError = error as? ConfigParseError
            XCTAssertTrue(parseError?.message.contains("unsupported root key or table 'group'") == true)
            XCTAssertEqual(parseError?.line, 1)
        }
    }
}
