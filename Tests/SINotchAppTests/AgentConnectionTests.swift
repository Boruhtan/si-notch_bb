import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class AgentConnectionTests: XCTestCase {
    func testCodexIdentitySurvivesRenamedBundleWithoutMatchingOrdinaryChatGPT() {
        XCTAssertEqual(AgentConnection.runningProviders(detected: [],
            applicationPaths: ["/Applications/ChatGPT.app"], bundleIdentifiers: ["com.openai.codex"]), ["codex"])
        XCTAssertTrue(AgentConnection.runningProviders(detected: [],
            applicationPaths: ["/Applications/ChatGPT.app"], bundleIdentifiers: ["com.openai.chat"]).isEmpty)
    }

    func testCodexLifecyclePlaceholderWaitsForTaskContext() {
        var session = AgentSession(id: "thread", provider: "codex", title: "Codex Desktop", status: .working)
        session.lastEventID = "desktop:thread:1:working"
        XCTAssertFalse(AgentConnection.isTask(session))
        session.firstPrompt = "Fix the parser"
        XCTAssertTrue(AgentConnection.isTask(session))
        session.firstPrompt = nil
        session.title = "Fix the parser"
        XCTAssertTrue(AgentConnection.isTask(session))
        session.status = .completed
        XCTAssertTrue(AgentConnection.isTask(session))
    }
    @MainActor func testIdleHarnessDoesNotCountAsTaskAndPromotesOnWork() throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "si-notch.agent-tests." + UUID().uuidString)!)
        func receive(_ kind: AgentEventKind) throws {
            model.receive(try JSONEncoder().encode(AgentEvent(sessionID: "pi-1", provider: "pi", kind: kind))) { _ in }
        }
        try receive(.sessionStarted)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.agents.map(\.id), ["pi"])
        XCTAssertEqual(model.agents.first?.state, .online)
        try receive(.working)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.workingCount, 1)
        try receive(.completed)
        model.activeFilter = "Готово"
        XCTAssertEqual(model.filtered.count, 1)
        try receive(.sessionEnded)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.agents.first?.state, .offline)
    }

    func testFreshnessDoesNotInventOnlineFromInstalledOrHistoricalData() {
        let now = Date(timeIntervalSince1970: 1000)
        let detection = HarnessDetection(kind: .pi, locations: [HarnessLocation(kind: .executable,
            url: URL(fileURLWithPath: "/fixture/pi"), resolvedURL: URL(fileURLWithPath: "/fixture/pi"))])
        let idle = AgentSession(id: "p", provider: "pi", createdAt: now)
        func state(_ sessions: [AgentSession] = [], _ receipts: [String: Date] = [:], _ running: Set<String> = []) -> AgentConnection.State? {
            AgentConnection.project(detected: [detection], sessions: sessions, receipts: receipts,
                running: running, now: now).first?.state
        }
        XCTAssertEqual(state(), .installed)
        XCTAssertEqual(state([idle]), .lastSeen)
        XCTAssertEqual(state([idle], ["pi": now]), .online)
        XCTAssertEqual(state([idle], ["pi": now.addingTimeInterval(-121)]), .lastSeen)
        XCTAssertEqual(state([], [:], ["pi"]), .online)
    }

    func testMultipleSessionsProduceOneAgentAndEndingOneKeepsOtherOnline() {
        let now = Date()
        let sessions = [AgentSession(id: "a", provider: "codex", status: .ended),
                        AgentSession(id: "b", provider: "codex", status: .working)]
        let agents = AgentConnection.project(detected: [], sessions: sessions,
            receipts: ["codex": now], running: [], now: now)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.state, .online)
    }
}
