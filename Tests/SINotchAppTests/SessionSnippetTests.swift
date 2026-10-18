import XCTest
@testable import SINotch

final class SessionSnippetTests: XCTestCase {
    func testTextBlocksExcludeReasoningAndToolArguments() {
        let blocks: [[String: Any]] = [
            ["type": "thinking", "text": "PRIVATE_REASONING"],
            ["type": "toolCall", "text": "PRIVATE_COMMAND"],
            ["type": "text", "text": "Checking the layout"],
            ["type": "output_text", "text": "Two tests passed"]
        ]
        XCTAssertEqual(SessionSnippet.message(blocks), "Checking the layout\nTwo tests passed")
    }
    func testCredentialsControlsAndLongTextAreBounded() {
        let value = SessionSnippet.text("token=very-secret-value\nBearer example-token\u{0000}", limit: 200)!
        XCTAssertFalse(value.contains("very-secret-value"))
        XCTAssertFalse(value.contains("example-token"))
        XCTAssertFalse(value.contains("\u{0000}"))
        XCTAssertEqual(SessionSnippet.text(String(repeating: "я", count: 3000))?.count, 1200)
    }
}
