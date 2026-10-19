import Foundation
import XCTest
@testable import SINotch
import SINotchCore

final class PresentationModelTests: XCTestCase {
    @MainActor
    func testFiltersResizeImmediatelyWithAlreadyMeasuredCards() {
        let model = makeModel()
        defer { model.shutdown() }
        model.store.apply(AgentEvent(sessionID: "working", provider: "codex", kind: .working, title: "Build"))
        model.store.apply(AgentEvent(sessionID: "done", provider: "pi", kind: .completed, title: "Review"))
        model.measuredSessionHeights = ["working": 120, "done": 140]
        model.activeFilter = "В работе"
        model.setExpanded(true)
        let small = model.panelHeight(limitedTo: 560)
        var sizes: [CGFloat] = []
        model.onLayout = { sizes.append(model.panelHeight(limitedTo: 560)) }
        model.activeFilter = "Все"
        XCTAssertEqual(sizes.count, 1)
        XCTAssertGreaterThan(sizes[0], small)
        XCTAssertEqual(sizes[0], model.desiredPanelHeight)
        model.activeFilter = "Готово"
        XCTAssertEqual(sizes.count, 2)
        XCTAssertLessThan(sizes[1], sizes[0])
        XCTAssertEqual(sizes[1], model.desiredPanelHeight)
        model.activeFilter = "Внимание"
        XCTAssertEqual(sizes.count, 3)
        XCTAssertEqual(sizes[2], model.desiredPanelHeight)
        XCTAssertTrue(model.expanded)
    }

    @MainActor
    func testSearchResizesWithoutWaitingForAgentEvents() {
        let model = makeModel()
        defer { model.shutdown() }
        model.store.apply(AgentEvent(sessionID: "first", provider: "codex", kind: .working, title: "Build"))
        model.store.apply(AgentEvent(sessionID: "second", provider: "pi", kind: .completed, title: "Review"))
        model.measuredSessionHeights = ["first": 120, "second": 140]
        model.setExpanded(true)
        let all = model.panelHeight(limitedTo: 560)
        var height: CGFloat = 0
        model.onLayout = { height = model.panelHeight(limitedTo: 560) }
        model.search = "Build"
        XCTAssertLessThan(height, all)
        XCTAssertEqual(height, model.desiredPanelHeight)
        model.search = ""
        XCTAssertEqual(height, all)
    }

    @MainActor
    func testSwitchingTabsAdaptsHeightAndStillClosesOnLeave() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.store.apply(AgentEvent(sessionID: "task", provider: "codex", kind: .working, title: "Review"))
        model.measuredSessionHeights["task"] = 300
        model.setExpanded(true)
        model.hover(true)
        let sessionsHeight = model.panelHeight(limitedTo: 560)
        model.selectAgents(true)
        XCTAssertLessThan(model.desiredPanelHeight, sessionsHeight)
        XCTAssertEqual(model.panelHeight(limitedTo: 560), model.desiredPanelHeight)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(model.expanded)
        model.selectAgents(false)
        XCTAssertEqual(model.panelHeight(limitedTo: 560), sessionsHeight)
        model.selectAgents(true)
        model.hover(false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(model.expanded)
        model.setExpanded(true)
        XCTAssertEqual(model.panelHeight(limitedTo: 560), model.desiredPanelHeight)
    }

    @MainActor
    func testExpandedHeightRespectsDisplayLimitAndShrinksWhenTasksDisappear() {
        let model = makeModel()
        defer { model.shutdown() }
        model.store.apply(AgentEvent(sessionID: "task", provider: "codex", kind: .working))
        model.measuredSessionHeights["task"] = 600
        model.setExpanded(true)
        XCTAssertEqual(model.panelHeight(limitedTo: 560), 560)
        model.store.removeSession(id: "task")
        XCTAssertEqual(model.panelHeight(limitedTo: 560), model.desiredPanelHeight)
        XCTAssertEqual(model.panelHeight(limitedTo: 345), min(345, model.desiredPanelHeight))
        model.setExpanded(false)
        XCTAssertEqual(model.panelHeight(limitedTo: 560), model.desiredPanelHeight)
    }

    @MainActor
    func testHoverOpensAndClosesWithoutLongDwell() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        let opened = expectation(description: "hover opens promptly")
        model.onLayout = { if model.expanded { opened.fulfill() } }
        model.hover(true)
        XCTAssertEqual(try XCTUnwrap(model.expansionTimer).timeInterval, HoverIntent.sampleInterval)
        await fulfillment(of: [opened], timeout: 2)
        let closed = expectation(description: "pointer leave closes promptly")
        model.onLayout = { if !model.expanded { closed.fulfill() } }
        let leavingAt = Date()
        model.hover(false)
        // Verify the requested delay separately from CI's run-loop scheduling.
        XCTAssertEqual(try XCTUnwrap(model.expansionTimer).fireDate.timeIntervalSince(leavingAt),
                       IslandTiming.hoverExit, accuracy: 0.05)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(model.expanded)
    }

    @MainActor
    func testMovingPointerWithinPillUsesConfiguredDwell() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        var position = CGPoint.zero
        model.hoverRegion = CGRect(x: -10, y: -10, width: 200, height: 40)
        model.hoverLocation = { position }
        model.hover(true)
        for _ in 0..<8 {
            position.x += 12
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(model.expanded)
        XCTAssertNil(model.expansionTimer)
    }

    @MainActor
    func testDisablingHoverStopsIntentSampling() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.hover(true)
        model.defaults.set(false, forKey: "hoverExpand")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.expanded)
        XCTAssertNil(model.expansionTimer)
        model.defaults.set(true, forKey: "hoverExpand")
        model.hover(false)
        model.hover(true)
        model.setExpanded(true)
        XCTAssertNil(model.expansionTimer, "Click and keyboard expansion bypass hover intent")
    }

    @MainActor
    func testBriefHoverAndQuickReentryCancelStaleTimers() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.hover(true)
        model.hover(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.expanded)
        model.setExpanded(true)
        model.hover(true)
        model.hover(false)
        model.hover(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(model.expanded)
    }

    @MainActor
    func testFastHoverDismissalStillRespectsKeepOpen() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.defaults.set(true, forKey: "keepOpen")
        model.setExpanded(true)
        model.hover(true)
        model.hover(false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(model.expanded)
    }

    @MainActor
    func testReceiptStatusIsReadOnlyAndExcludesContent() throws {
        let model = makeModel()
        model.receive(try payload(["event": "agent.working", "session_id": "receipt", "provider": "codex", "message": "PRIVATE", "cwd": "/private/project"])) { _ in }
        XCTAssertNotNil(model.providerReceipts["codex"])
        var reply: Data?
        model.paused = true
        model.receive(try payload(["command": "status", "protocol_version": 1])) { reply = $0 }
        let data = try XCTUnwrap(reply)
        let result = try response(data)
        XCTAssertEqual(result["received_count"] as? Int, 1)
        XCTAssertEqual(result["session_count"] as? Int, 1)
        XCTAssertEqual(result["paused"] as? Bool, true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/private/project"))
        XCTAssertEqual(model.receivedCount, 1)
    }

    @MainActor
    func testHistoricalBootstrapDoesNotClaimLiveReceipt() throws {
        let model = makeModel()
        model.receive(try payload(["event": "agent.working", "session_id": "historical", "provider": "codex"]), suppressPresentation: true) { _ in }
        XCTAssertNil(model.providerReceipts["codex"])
    }

    @MainActor
    func testPassiveWaitingCompletionAndFailureDoNotRevealByDefault() throws {
        let model = makeModel()
        defer { model.shutdown() }
        for event in ["agent.working", "agent.waiting", "approval.request", "agent.completed", "agent.failed"] {
            model.receive(try payload(["event": event, "session_id": "passive", "provider": "codex"])) { _ in }
            XCTAssertFalse(model.expanded, event)
        }
        model.defaults.set(1, forKey: "followupMinutes")
        model.receive(try payload(["event": "agent.waiting", "session_id": "passive", "provider": "codex"])) { _ in }
        model.tick(at: ProcessInfo.processInfo.systemUptime + 70)
        XCTAssertFalse(model.expanded, "A reminder must not promote a passive wait")
    }

    @MainActor
    func testConcreteRequestIdentityRevealsNewQuestionAtSameStatusButNotReplay() throws {
        let model = makeModel()
        defer { model.shutdown() }
        func send(_ request: String?, restoring: Bool = false) throws {
            var event: [String: Any] = ["event": "agent.waiting", "session_id": "native", "provider": "codex",
                                      "event_id": UUID().uuidString, "id": "desktop-stream:\(UUID().uuidString)"]
            if let request { event["attention_request_id"] = request }
            model.receive(try payload(event), suppressPresentation: restoring) { _ in }
        }
        try send("old", restoring: true)
        XCTAssertFalse(model.expanded)
        try send("old")
        XCTAssertFalse(model.expanded)
        try send("question-a")
        XCTAssertTrue(model.expanded)
        model.setExpanded(false)
        try send("question-a")
        XCTAssertFalse(model.expanded)
        try send("question-b")
        XCTAssertTrue(model.expanded)
        model.setExpanded(false)
        model.tick(at: ProcessInfo.processInfo.systemUptime + 46)
        try send("question-b")
        XCTAssertFalse(model.expanded, "A delayed heartbeat must not replay the same question")
        try send(nil)
        model.defaults.set(1, forKey: "followupMinutes")
        model.tick(at: ProcessInfo.processInfo.systemUptime + 70)
        XCTAssertFalse(model.expanded)
        XCTAssertNil(model.attentionIdentity("native"))
    }

    @MainActor
    func testAwaitedRequestOpensAndExpiredRequestCannotRemind() throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.defaults.set(1, forKey: "followupMinutes")
        model.receive(try payload(["event": "approval.request", "session_id": "answer", "provider": "custom",
                                  "request_id": "concrete", "await_response": true, "response_timeout": 1])) { _ in }
        XCTAssertTrue(model.expanded)
        model.setExpanded(false)
        model.tick(at: ProcessInfo.processInfo.systemUptime + 70)
        XCTAssertFalse(model.expanded)
        XCTAssertNil(model.pending["answer"])
    }

    @MainActor
    func testAnswerResumesAutomaticDismissWithoutTakingManualOwnership() throws {
        let model = makeModel()
        defer { model.shutdown() }
        func request(_ id: String) throws {
            model.receive(try payload(["event": "approval.request", "session_id": id, "provider": "custom",
                "request_id": id, "await_response": true, "response_timeout": 60])) { _ in }
        }
        try request("automatic")
        XCTAssertTrue(model.expanded)
        XCTAssertNil(model.revealTimer)
        model.respond("automatic", expectedToken: try XCTUnwrap(model.pending["automatic"]?.token), decision: "deny")
        XCTAssertNotNil(model.revealTimer)
        model.setExpanded(false)
        model.setExpanded(true)
        try request("manual")
        XCTAssertNil(model.revealTimer)
        model.respond("manual", expectedToken: try XCTUnwrap(model.pending["manual"]?.token), decision: "deny")
        XCTAssertNil(model.revealTimer, "An answer must not start dismissing a manually opened panel")
    }

    @MainActor
    func testHoverTimerRevalidatesPointerWithoutAnExitEvent() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.hoverRegion = CGRect(x: 0, y: 0, width: 100, height: 40)
        var location = CGPoint(x: 50, y: 20)
        model.hoverLocation = { location }
        model.hover(true)
        location = CGPoint(x: 50, y: -100)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(model.expanded)
        XCTAssertFalse(model.pointerInside)
        XCTAssertNil(model.expansionTimer)
    }

    @MainActor
    func testCollapseOverPillBlocksHoverUntilCooldownAndNewEntry() async throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.compactHoverRegion = CGRect(x: -10, y: -10, width: 100, height: 40)
        model.setExpanded(true)
        model.hover(true)
        model.setExpanded(false)
        model.hover(false)
        model.hover(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.expanded)
        XCTAssertNil(model.expansionTimer)
        model.hover(false)
        try await Task.sleep(for: .milliseconds(450))
        model.hover(true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(model.expanded)
    }
    @MainActor
    private func makeModel() -> AppModel {
        let model = AppModel(defaults: UserDefaults(suiteName: "si-notch.presentation-tests." + UUID().uuidString)!)
        model.hoverLocation = { .zero }
        return model
    }

    private func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func response(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testFilteredObservationIsAcknowledgedWithoutCreatingSession() async throws {
        let model = makeModel()
        model.defaults.set("/private/project", forKey: "blockedDirectories")
        var reply: Data?
        model.receive(try payload(["event": "agent.working", "session_id": "hidden", "provider": "custom",
                                    "cwd": "/PRIVATE/PROJECT/src"])) { reply = $0 }
        let ack = try response(XCTUnwrap(reply))
        XCTAssertEqual(ack["ok"] as? Bool, true)
        XCTAssertEqual(ack["disposition"] as? String, "filtered")
        XCTAssertNil(model.store.sessions["hidden"])
        XCTAssertNil(model.pending["hidden"])
    }

    @MainActor
    func testFirstPromptFilterRejectsNewAwaitedRequestImmediately() async throws {
        let model = makeModel()
        model.defaults.set(" Secret task ", forKey: "blockedPromptPrefixes")
        var reply: Data?
        model.receive(try payload(["event": "approval.request", "session_id": "hidden-prompt", "provider": "custom",
                                    "first_prompt": "SECRET TASK details", "request_id": "prompt-request",
                                    "approval_id": "prompt-request", "await_response": true,
                                    "response_timeout": 60])) { reply = $0 }
        let ack = try response(XCTUnwrap(reply))
        XCTAssertEqual(ack["ok"] as? Bool, false)
        XCTAssertEqual(ack["decision"] as? String, "filtered")
        XCTAssertEqual(ack["request_id"] as? String, "prompt-request")
        XCTAssertNil(model.store.sessions["hidden-prompt"])
        XCTAssertNil(model.pending["hidden-prompt"])
    }

    @MainActor
    func testFilteredAwaitedRequestCancelsOldReplyAndLeavesNoOrphan() async throws {
        let model = makeModel()
        var oldReply: Data?
        model.receive(try payload(["event": "approval.request", "session_id": "session", "provider": "custom",
                                    "cwd": "/blocked/project", "request_id": "old", "approval_id": "old",
                                    "await_response": true, "response_timeout": 60])) { oldReply = $0 }
        XCTAssertNotNil(model.pending["session"])
        XCTAssertNil(oldReply)

        model.defaults.set("/blocked", forKey: "blockedDirectories")
        var filteredReply: Data?
        model.receive(try payload(["event": "approval.request", "session_id": "session", "provider": "custom",
                                    "request_id": "new", "approval_id": "new",
                                    "await_response": true, "response_timeout": 60])) { filteredReply = $0 }
        let old = try response(XCTUnwrap(oldReply))
        let filtered = try response(XCTUnwrap(filteredReply))
        XCTAssertEqual(old["decision"] as? String, "cancelled")
        XCTAssertEqual(old["request_id"] as? String, "old")
        XCTAssertEqual(filtered["ok"] as? Bool, false)
        XCTAssertEqual(filtered["decision"] as? String, "filtered")
        XCTAssertEqual(filtered["request_id"] as? String, "new")
        XCTAssertNil(model.pending["session"])
        XCTAssertTrue(model.sessions.isEmpty)
    }

    @MainActor
    func testOnlyAppliedFilteredEventCancelsExistingDecision() throws {
        let model = makeModel()
        var originalReply: Data?
        model.receive(try payload(["event": "approval.request", "session_id": "active", "provider": "custom",
                                    "sequence": 10, "cwd": "/allowed/project", "request_id": "original",
                                    "approval_id": "original", "await_response": true,
                                    "response_timeout": 60])) { originalReply = $0 }
        let token = try XCTUnwrap(model.pending["active"]?.token)
        XCTAssertNil(originalReply)

        model.defaults.set("/blocked", forKey: "blockedDirectories")
        var staleReply: Data?
        model.receive(try payload(["event": "agent.working", "session_id": "active", "provider": "custom",
                                    "sequence": 9, "cwd": "/blocked/stale"])) { staleReply = $0 }
        XCTAssertEqual(try response(XCTUnwrap(staleReply))["disposition"] as? String, "outOfOrder")
        XCTAssertEqual(model.pending["active"]?.token, token)
        XCTAssertNil(originalReply)
        XCTAssertEqual(model.store.sessions["active"]?.projectPath, "/allowed/project")

        var conflictReply: Data?
        model.receive(try payload(["event": "agent.working", "session_id": "active", "provider": "other",
                                    "sequence": 11, "cwd": "/blocked/conflict"])) { conflictReply = $0 }
        XCTAssertEqual(try response(XCTUnwrap(conflictReply))["error"] as? String, "session_provider_conflict")
        XCTAssertEqual(model.pending["active"]?.token, token)
        XCTAssertNil(originalReply)
        XCTAssertEqual(model.store.sessions["active"]?.projectPath, "/allowed/project")

        var filteredReply: Data?
        model.receive(try payload(["event": "agent.working", "session_id": "active", "provider": "custom",
                                    "sequence": 11, "cwd": "/blocked/current"])) { filteredReply = $0 }
        XCTAssertEqual(try response(XCTUnwrap(filteredReply))["disposition"] as? String, "filtered")
        XCTAssertEqual(try response(XCTUnwrap(originalReply))["decision"] as? String, "cancelled")
        XCTAssertNil(model.pending["active"])
        XCTAssertNil(model.store.sessions["active"])
    }

    @MainActor
    func testFilterPreferenceChangeReconcilesExistingPendingDecision() throws {
        let model = makeModel()
        var originalReply: Data?
        model.receive(try payload(["event": "approval.request", "session_id": "active", "provider": "custom",
                                    "cwd": "/later/blocked", "request_id": "original",
                                    "approval_id": "original", "await_response": true,
                                    "response_timeout": 60])) { originalReply = $0 }
        XCTAssertNotNil(model.pending["active"])
        XCTAssertNil(originalReply)

        model.defaults.set("/later", forKey: "blockedDirectories")
        model.reconcileFilters()
        let cancelled = try response(XCTUnwrap(originalReply))
        XCTAssertEqual(cancelled["decision"] as? String, "cancelled")
        XCTAssertEqual(cancelled["request_id"] as? String, "original")
        XCTAssertNil(model.pending["active"])
        XCTAssertNil(model.store.sessions["active"])
    }

    @MainActor
    func testSelectingSessionCancelsItsFollowUpReminder() async throws {
        let model = makeModel()
        model.defaults.set(1.0, forKey: "followupMinutes")
        model.defaults.set(false, forKey: "autoExpand")
        model.receive(try payload(["event": "agent.waiting", "session_id": "waiting", "provider": "custom"])) { _ in }
        XCTAssertEqual(model.store.sessions["waiting"]?.status, .waiting)

        let future = ProcessInfo.processInfo.systemUptime + 120
        var beforeSelection = model.reminders
        XCTAssertEqual(beforeSelection.due(now: future, states: ["waiting": .waiting]), ["waiting"])
        model.selectSession("waiting")
        XCTAssertEqual(model.selectedID, "waiting")
        XCTAssertEqual(model.reminders.due(now: future, states: ["waiting": .waiting]), [])
    }

    @MainActor
    func testWaitingReminderHonorsSettingsChangedAfterScheduling() throws {
        for disabledSetting in ["autoExpand", "followupMinutes", "attentionReveal"] {
            let model = makeModel()
            model.defaults.set(false, forKey: "quiet")
            model.defaults.set(false, forKey: "autoExpand")
            model.defaults.set(1.0, forKey: "followupMinutes")
            model.defaults.set(true, forKey: "attentionReveal")
            model.receive(try payload(["event": "agent.waiting", "session_id": "waiting", "provider": "custom"])) { _ in }
            model.setExpanded(false)
            model.reminders.update(id: "waiting", status: .waiting, now: 0, delay: 60, includeCompleted: false)
            var scheduled = model.reminders
            XCTAssertEqual(scheduled.due(now: 61, states: ["waiting": .waiting]), ["waiting"])

            model.defaults.set(true, forKey: "autoExpand")
            model.defaults.set(disabledSetting == "followupMinutes" ? 0.0 : 1.0, forKey: "followupMinutes")
            model.defaults.set(disabledSetting != "attentionReveal", forKey: "attentionReveal")
            if disabledSetting == "autoExpand" { model.defaults.set(false, forKey: "autoExpand") }
            model.tick(at: 61)
            XCTAssertFalse(model.expanded, "\(disabledSetting) changed after scheduling")
        }
    }

    @MainActor
    func testCompletedReminderHonorsOptOutChangedAfterScheduling() throws {
        for disabledSetting in ["followupCompleted", "completionReveal"] {
            let model = makeModel()
            model.defaults.set(false, forKey: "quiet")
            model.defaults.set(false, forKey: "autoExpand")
            model.defaults.set(1.0, forKey: "followupMinutes")
            model.defaults.set(true, forKey: "followupCompleted")
            model.defaults.set(true, forKey: "completionReveal")
            model.receive(try payload(["event": "agent.completed", "session_id": "completed", "provider": "custom"])) { _ in }
            model.setExpanded(false)
            model.reminders.update(id: "completed", status: .completed, now: 0, delay: 60, includeCompleted: true)
            var scheduled = model.reminders
            XCTAssertEqual(scheduled.due(now: 61, states: ["completed": .completed]), ["completed"])

            model.defaults.set(false, forKey: disabledSetting)
            model.defaults.set(true, forKey: "autoExpand")
            model.tick(at: 61)
            XCTAssertFalse(model.expanded, "\(disabledSetting) changed after scheduling")
        }
    }

    @MainActor
    func testEligibleFollowUpReminderReveals() throws {
        for (statusEvent, status, includeCompleted) in [("agent.waiting", AgentStatus.waiting, false),
                                                         ("agent.completed", AgentStatus.completed, true)] {
            let model = makeModel()
            model.defaults.set(false, forKey: "quiet")
            model.defaults.set(false, forKey: "autoExpand")
            model.defaults.set(1.0, forKey: "followupMinutes")
            model.defaults.set(true, forKey: "attentionReveal")
            model.defaults.set(true, forKey: "completionReveal")
            model.defaults.set(true, forKey: "followupCompleted")
            var event: [String: Any] = ["event": statusEvent, "session_id": "due", "provider": "custom"]
            if status == .waiting {
                event["await_response"] = true
                event["request_id"] = "live-question"
                event["response_timeout"] = 110
            }
            model.receive(try payload(event)) { _ in }
            model.setExpanded(false)
            let now = ProcessInfo.processInfo.systemUptime
            model.reminders.update(id: "due", status: status, now: now, delay: 60, includeCompleted: includeCompleted)

            model.defaults.set(true, forKey: "autoExpand")
            model.tick(at: now + 61)
            XCTAssertTrue(model.expanded, "\(statusEvent) should reveal when enabled")
            model.setExpanded(false)
        }
    }
    @MainActor func testMeasuredCardsAvoidFixedEmptyExpansionAndIgnoreNoise() {
        let defaults = UserDefaults(suiteName: "si-notch.height-test.\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        model.store.apply(AgentEvent(sessionID: "measured", provider: "custom", kind: .working, title: "Review"))
        model.selectedID = "measured"
        var layouts = 0
        model.onLayout = { layouts += 1 }
        model.measureSessionCards(["measured": 150])
        XCTAssertEqual(model.desiredPanelHeight, model.headerHeight + 244)
        XCTAssertEqual(layouts, 1)
        model.measureSessionCards(["measured": 150.2, "missing": 300])
        model.measureSessionCards(["measured": .nan])
        XCTAssertEqual(layouts, 1)
        model.measureSessionCards(["measured": 240])
        XCTAssertEqual(layouts, 2)
        XCTAssertEqual(model.desiredPanelHeight, model.headerHeight + 334)
    }

}
