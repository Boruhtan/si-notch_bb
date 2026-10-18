import Foundation
import XCTest
@testable import SINotch
import SINotchCore

final class SessionSoundPolicyTests: XCTestCase {
    private func event(_ kind: AgentEventKind, session: String = "one", provider: String = "codex",
                       turn: String? = nil, request: String? = nil) -> AgentEvent {
        AgentEvent(sessionID: session, provider: provider, kind: kind, approvalID: request, turnID: turn)
    }

    func testOneStartAcrossIdleWorkingHooksAndObserverReplays() {
        var policy = SessionSoundPolicy()
        XCTAssertEqual(policy.consume(event(.sessionStarted), status: .idle), .sessionStart)
        XCTAssertNil(policy.consume(event(.working), status: .working))
        XCTAssertNil(policy.consume(event(.working, turn: "turn-1"), status: .working))
        XCTAssertNil(policy.consume(event(.sessionStarted, turn: "turn-1"), status: .idle))
        XCTAssertNil(policy.consume(event(.toolStarted, turn: "turn-1"), status: .working))
        XCTAssertNil(policy.consume(event(.working, turn: "turn-1"), status: .working))
    }

    func testDirectWorkingStartAndRepeatedCompletionForSameTurn() {
        var policy = SessionSoundPolicy()
        XCTAssertEqual(policy.consume(event(.working, turn: "t1"), status: .working), .sessionStart)
        XCTAssertEqual(policy.consume(event(.completed, turn: "t1"), status: .completed), .completion)
        XCTAssertNil(policy.consume(event(.working, turn: "t1"), status: .working))
        XCTAssertNil(policy.consume(event(.completed, turn: "t1"), status: .completed))
        XCTAssertEqual(policy.consume(event(.working, turn: "t2"), status: .working), .working)
        XCTAssertEqual(policy.consume(event(.completed, turn: "t2"), status: .completed), .completion)
        XCTAssertNil(policy.consume(event(.completed, turn: "t1"), status: .completed))
    }

    func testRestoredHistoryAndReconnectAreSilent() {
        var policy = SessionSoundPolicy()
        XCTAssertNil(policy.consume(event(.working, turn: "t1"), status: .working, restoring: true))
        XCTAssertNil(policy.consume(event(.sessionStarted, turn: "t1"), status: .idle))
        XCTAssertNil(policy.consume(event(.working, turn: "t1"), status: .working))
        XCTAssertNil(policy.consume(event(.completed, turn: "t1"), status: .completed, restoring: true))
        XCTAssertNil(policy.consume(event(.completed, turn: "t1"), status: .completed))
        XCTAssertNil(policy.consume(event(.working, turn: "t1"), status: .working, restoring: true))
        XCTAssertNil(policy.consume(event(.completed, turn: "t1"), status: .completed))
        XCTAssertEqual(policy.consume(event(.working, turn: "t2"), status: .working), .working)
    }

    func testParallelSessionsAndProvidersDoNotShareSoundIdentity() {
        var policy = SessionSoundPolicy()
        for index in 0..<12 {
            XCTAssertEqual(policy.consume(event(.working, session: "s\(index)", turn: "t1"), status: .working), .sessionStart)
        }
        XCTAssertEqual(policy.consume(event(.working, session: "s0", provider: "pi", turn: "t1"), status: .working), .sessionStart)
        let id = UUID().uuidString
        XCTAssertEqual(policy.consume(event(.working, session: id, turn: "t1"), status: .working), .sessionStart)
        XCTAssertNil(policy.consume(event(.working, session: id.lowercased(), turn: "t1"), status: .working))
    }

    func testDistinctPermissionRequestsRemainAudibleWithinOneTurn() {
        var policy = SessionSoundPolicy()
        _ = policy.consume(event(.working, turn: "t1"), status: .working)
        XCTAssertEqual(policy.consume(event(.waiting, turn: "t1"), status: .waiting), .attention)
        XCTAssertNil(policy.consume(event(.approvalRequested, turn: "t1", request: "r1"), status: .approval))
        XCTAssertNil(policy.consume(event(.approvalRequested, turn: "t1", request: "r1"), status: .approval))
        XCTAssertEqual(policy.consume(event(.approvalRequested, turn: "t1", request: "r2"), status: .approval), .attention)
        XCTAssertNil(policy.consume(event(.waiting, turn: "t1"), status: .waiting))
    }

    func testAnonymousHarnessCanStartAnotherTurnWithoutRepeatingSessionStart() {
        var policy = SessionSoundPolicy()
        XCTAssertEqual(policy.consume(event(.sessionStarted, provider: "pi"), status: .idle), .sessionStart)
        XCTAssertNil(policy.consume(event(.working, provider: "pi"), status: .working))
        XCTAssertEqual(policy.consume(event(.completed, provider: "pi"), status: .completed), .completion)
        XCTAssertEqual(policy.consume(event(.working, provider: "pi"), status: .working), .working)
        XCTAssertNil(policy.consume(event(.toolFinished, provider: "pi"), status: .working))
        XCTAssertEqual(policy.consume(event(.completed, provider: "pi"), status: .completed), .completion)
    }

    func testFirstTerminalOutcomeIsNotAnnouncedAgainByAnotherObserver() {
        var policy = SessionSoundPolicy()
        _ = policy.consume(event(.working, turn: "t1"), status: .working)
        XCTAssertEqual(policy.consume(event(.failed, turn: "t1"), status: .failed), .failure)
        XCTAssertNil(policy.consume(event(.completed, turn: "t1"), status: .completed))
        XCTAssertNil(policy.consume(event(.failed, turn: "t1"), status: .failed))
    }

    func testNewTurnCanBeAudibleWithoutAnIntermediateIdleState() {
        var policy = SessionSoundPolicy()
        XCTAssertEqual(policy.consume(event(.working, turn: "t1"), status: .working), .sessionStart)
        XCTAssertEqual(policy.consume(event(.working, turn: "t2"), status: .working), .working)
        XCTAssertNil(policy.consume(event(.working, turn: "t2"), status: .working))
    }

    @MainActor
    func testAutomaticRevealTimeoutDoesNotPlayAnUnpromptedCollapseCue() async throws {
        let suite = "si-notch.sound-auto-close." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sound")
        defaults.set(true, forKey: "autoExpand")
        defaults.set(true, forKey: "completionReveal")
        defaults.set(false, forKey: "quiet")
        defaults.set(false, forKey: "keepOpen")
        defaults.set(2.0, forKey: "revealDwell")
        var played = 0
        let player = EventSoundPlayer(defaults: defaults, output: { _, _ in played += 1; return true })
        let model = AppModel(defaults: defaults, soundPlayer: player)
        defer { model.shutdown() }
        model.receive(try JSONEncoder().encode(event(.completed, turn: "t1"))) { _ in }
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(played, 1)
        try await Task.sleep(for: .milliseconds(2250))
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(played, 1)
    }

    @MainActor
    func testAppDeliveryUsesOneAudioOutputPerStartAndKeepsParallelSessions() throws {
        let suite = "si-notch.sound-delivery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sound")
        defaults.set(true, forKey: "soundWorking")
        defaults.set(false, forKey: "quiet")
        defaults.set(false, forKey: "autoExpand")
        var played = 0
        let player = EventSoundPlayer(defaults: defaults, output: { data, volume in
            XCTAssertGreaterThan(data.count, 44)
            XCTAssertGreaterThan(volume, 0)
            played += 1
            return true
        })
        let model = AppModel(defaults: defaults, soundPlayer: player)
        defer { model.shutdown() }
        func deliver(_ kind: AgentEventKind, id: String, session: String = "one", restore: Bool = false) throws {
            var value = event(kind, session: session, turn: "t1")
            value.id = id
            model.receive(try JSONEncoder().encode(value), suppressPresentation: restore) { _ in }
        }
        try deliver(.sessionStarted, id: "hook:start")
        try deliver(.working, id: "hook:working")
        try deliver(.working, id: "hook:working")
        try deliver(.sessionStarted, id: "file:start")
        try deliver(.working, id: "desktop:working")
        try deliver(.working, id: "snapshot:working", restore: true)
        XCTAssertEqual(played, 1)
        try deliver(.completed, id: "hook:done")
        try deliver(.working, id: "late:working")
        try deliver(.completed, id: "desktop:done")
        XCTAssertEqual(played, 2)
        for index in 0..<8 { try deliver(.working, id: "start", session: "parallel-\(index)") }
        XCTAssertEqual(played, 10)
    }
}
