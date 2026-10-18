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
    func testCompiledRedactionsPreserveUnicodeAndAllCredentialRules() {
        XCTAssertEqual(SessionSnippet.text("Привет 👋 \u{001B}[31mred\u{001B}[0m"), "Привет 👋 red")
        for token in ["sk-abcdefghijklmnop", "ghp_abcdefghijklmnop", "github_pat_abcdefghijklmnop", "AKIA1234567890ABCDEF"] {
            XCTAssertEqual(SessionSnippet.text("Привет 👋 \(token) end"), "Привет 👋 [redacted] end")
        }
        XCTAssertEqual(SessionSnippet.text("Bearer abc.def==; password=private; api_key=hidden"),
                       "Bearer [redacted]; password=[redacted]; api_key=[redacted]")
        XCTAssertEqual(SessionSnippet.text("key\n-----BEGIN RSA PRIVATE KEY-----\nprivate\nend"), "key\n[redacted]")
    }
}
