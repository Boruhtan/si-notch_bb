import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class SessionCardContentTests: XCTestCase {
    func testActualTaskTitleWinsAndProjectIsRetained() {
        let session = AgentSession(id: "codex-12345678", provider: "codex", title: "Fix sidebar spacing", projectPath: "/Users/me/Projects/si-notch", status: .working)
        let content = SessionCardContent(session: session)
        XCTAssertEqual(content.primaryTitle, "Fix sidebar spacing")
        XCTAssertEqual(content.projectName, "si-notch")
        XCTAssertEqual(content.providerName, "Codex")
        XCTAssertEqual(content.shortID, "12345678")
        XCTAssertFalse(content.projectIsTitle)
    }

    func testGenericProviderTitleUsesRealPromptThenProjectThenID() {
        var session = AgentSession(id: "pi-12345678", provider: "pi", title: "Pi", projectPath: "/tmp/backend/")
        session.firstPrompt = "Inspect failing integration tests"
        XCTAssertEqual(SessionCardContent(session: session).primaryTitle, "Inspect failing integration tests")
        session.firstPrompt = nil
        let project = SessionCardContent(session: session)
        XCTAssertEqual(project.primaryTitle, "backend")
        XCTAssertTrue(project.projectIsTitle)
        session.projectPath = nil
        XCTAssertEqual(SessionCardContent(session: session).primaryTitle, "Pi")
        XCTAssertNil(SessionCardContent(session: session).summary)
    }

    func testGenericTitlesUseAvailableTaskWithoutInventingContent() {
        var session = AgentSession(id: "s1", provider: "claude", title: "Claude Code")
        session.tasks = [AgentTask(id: "t1", title: "Repair parser", status: .working)]
        XCTAssertEqual(SessionCardContent(session: session).primaryTitle, "Repair parser")
        session.tasks = []
        XCTAssertEqual(SessionCardContent(session: session).primaryTitle, "Claude Code")
        XCTAssertNil(SessionCardContent(session: session).projectName)
        XCTAssertNil(SessionCardContent(session: session).message)
    }

    func testLastResultIsAvailableBeforeSelectionAndFullTextIsRetained() {
        var session = AgentSession(id: "s", provider: "codex", title: "Fix tests", status: .completed)
        session.lastMessage = "Parser now accepts the new event.\nAll tests pass."
        let content = SessionCardContent(session: session)
        XCTAssertEqual(content.summary, "Parser now accepts the new event. All tests pass.")
        XCTAssertEqual(content.message, session.lastMessage)
        XCTAssertGreaterThan(content.estimatedCollapsedHeight(), 108)
        XCTAssertEqual(content.estimatedCollapsedHeight(showActivity: false), 108)
    }

    func testDuplicatePromptTitleAndStateDoNotBecomeFakeUpdates() {
        var session = AgentSession(id: "s", provider: "pi", title: "Pi")
        session.firstPrompt = "Review changes"
        session.lastMessage = "Review changes"
        XCTAssertNil(SessionCardContent(session: session).summary)
        session.lastMessage = "Working"
        XCTAssertNil(SessionCardContent(session: session, statusLabel: "Working").summary)
        session.lastMessage = "Pi"
        XCTAssertNil(SessionCardContent(session: session).summary)
    }

    func testToolSymbolsAndBoundedCleanText() {
        var session = AgentSession(id: "s", provider: "codex", title: "\u{001B}[31mFix\u{001B}[0m\n  tests\0")
        session.currentTool = "functions.exec_command"
        session.lastMessage = String(repeating: "Result ", count: 1000)
        let content = SessionCardContent(session: session)
        XCTAssertEqual(content.primaryTitle, "Fix tests")
        XCTAssertEqual(content.toolSymbol, "terminal")
        XCTAssertEqual(content.summary?.count, 240)
        XCTAssertLessThanOrEqual(content.message!.count, 4096)
        session.currentTool = "apply_patch"
        XCTAssertEqual(SessionCardContent(session: session).toolSymbol, "square.and.pencil")
        session.currentTool = "web_search"
        XCTAssertEqual(SessionCardContent(session: session).toolSymbol, "magnifyingglass")
    }

    func testLongOriginalTaskRemainsAvailableInDetails() {
        var session = AgentSession(id: "s", provider: "pi", title: "Pi")
        session.firstPrompt = String(repeating: "Inspect this module. ", count: 30)
        let content = SessionCardContent(session: session)
        XCTAssertEqual(content.primaryTitle.count, 160)
        XCTAssertNotNil(content.taskPrompt)
        XCTAssertGreaterThan(content.taskPrompt!.count, content.primaryTitle.count)
    }
}
