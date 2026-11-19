import XCTest
import SINotchCore
@testable import SINotch

final class SessionNavigationTests: XCTestCase {
    func testPiOpensOnlyARegularSessionFileWithMatchingHeader() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Pi work's #1.jsonl")
        let link = folder.appendingPathComponent("alias.jsonl")
        let header = #"{"type":"session","id":"pi-1"}"# + "\n"
        try Data(header.utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        var task = AgentSession(id: "pi-1", provider: "pi")
        task.targetURL = PiSessionTarget.route(for: file)
        let target = try XCTUnwrap(PiSessionTarget(task))
        XCTAssertEqual(target.verifiedSessionFile()?.url, file)
        XCTAssertEqual(SessionNavigationAction.open(.pi(target)).titleKey, "session.navigation.openPiSession")
        task.id = "other-session"
        XCTAssertNil(PiSessionTarget(task)?.verifiedSessionFile())
        task.id = "pi-1"
        task.targetURL = PiSessionTarget.route(for: link)
        XCTAssertNil(PiSessionTarget(task)?.verifiedSessionFile())
        task.targetURL = "pi-session://other-host/tmp/session.jsonl"
        XCTAssertNil(PiSessionTarget(task))
        task.targetURL = "pi-session://file/tmp/session.jsonl?command=run"
        XCTAssertNil(PiSessionTarget(task))
    }

    func testPiTerminalMetadataRequiresBothPartsAndSurvivesLaterFileEvents() throws {
        var store = SessionStore()
        let event = try AgentEvent.parse(data: Data("""
        {"session_id":"pi","provider":"pi","event":"agent.waiting","terminal_bundle_id":"com.apple.Terminal",
         "terminal_tty":"/dev/ttys012","terminal_pid":314}
        """.utf8))
        XCTAssertEqual(store.apply(event), .applied)
        XCTAssertEqual(store.apply(AgentEvent(sessionID: "pi", provider: "pi", kind: .working)), .applied)
        var task = try XCTUnwrap(store.sessions["pi"])
        XCTAssertEqual(PiSessionTarget(task)?.terminal, .init(tty: "/dev/ttys012", pid: 314))
        task.terminalTTY = "/dev/ttys012\n"
        XCTAssertNil(PiSessionTarget(task))
        task.terminalTTY = "/dev/ttys012"
        task.terminalBundleID = "com.mitchellh.ghostty"
        XCTAssertNil(PiSessionTarget(task))
    }

    func testPiRexRouteRequiresFullTypedIdentifiers() throws {
        let sid = "session:01a1cac6-9ae2-719a-844e-84c5fdf704e8"
        let block = "block:01a1cad3-558c-70ab-b747-a1beeef2e0b4"
        var store = SessionStore()
        let event = AgentEvent(sessionID: "pi-rex", provider: "pi", kind: .waiting,
                               terminalBundleID: "com.superlogical.rex", rexSessionID: sid, rexBlockID: block)
        XCTAssertEqual(store.apply(try AgentEvent.parse(data: JSONEncoder().encode(event))), .applied)
        var task = try XCTUnwrap(store.sessions[event.sessionID])
        XCTAssertEqual(PiSessionTarget(task)?.rex, RexTerminal.Block(session: sid, block: block))
        task.rexBlockID = "left"
        XCTAssertNil(PiSessionTarget(task))
        task.rexBlockID = block
        task.rexSessionID = block
        XCTAssertNil(PiSessionTarget(task))
    }

    @MainActor
    func testHermesRemoteRouteUsesOnlyTheProfileAndHostBoundToItsConnector() throws {
        let model = model()
        defer { model.shutdown() }
        let connector = try XCTUnwrap(model.remoteConnections.add())
        var connection = try XCTUnwrap(model.remoteConnections.connections.first)
        let profile = RemoteHermesProfile(id: "default", home: "/Users/mac/.hermes", displayName: "Don David",
            enabled: true, showSessionText: false, pluginInstalled: true, connectionId: "profile-don-david")
        connection.host = "pupsik"
        connection.profiles = [profile]
        model.remoteConnections.update(connection)
        var task = AgentSession(id: "hermes-b5d24b0c9cee4232d1fa7b9dd527122e", provider: "hermes")
        task.connectionID = profile.connectionId
        task.targetURL = "hermes://open/20261120_013700_95cc48"
        task.connectionName = "untrusted-host"
        let origin = AgentConnection.Observation(provider: "hermes", connectionID: "profile-don-david",
            name: "Don David", lastSeen: Date(), eventAt: Date(), eventID: nil, origin: .remote(connector))
        model.connectionReceipts[origin.id] = origin
        let action = model.navigationAction(for: task)
        XCTAssertEqual(action.titleKey, "session.navigation.openChatSSH")
        guard case .open(.hermesTerminal(let target)) = action else {
            return XCTFail("Expected a managed SSH route")
        }
        let command = try XCTUnwrap(target.command())
        XCTAssertEqual(command.program, "/usr/bin/ssh")
        XCTAssertEqual(command.arguments.first, "-tt")
        XCTAssertEqual(command.arguments.dropLast().last, "pupsik")
        XCTAssertTrue(command.arguments.last?.hasSuffix(" '/Users/mac/.hermes' 'default' '20261120_013700_95cc48'") == true)
        XCTAssertFalse(command.arguments.joined().contains("untrusted-host"))
        task.targetURL = "hermes://open/20261120_013700_abcdef"
        XCTAssertNil(model.navigationAction(for: task).titleKey)
        task.targetURL = "hermes://open/20261120_013700_95cc48"
        connection.profiles[0].enabled = false
        model.remoteConnections.update(connection)
        XCTAssertNil(model.navigationAction(for: task).titleKey)
    }

    @MainActor
    func testRemoteNavigationExplainsLocationWithoutOpeningLocalAppAndExpires() async {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        var task = session(bundle: "com.apple.Terminal")
        task.connectionID = "remote"
        let observed = AgentConnection.Observation(provider: "codex", connectionID: "remote", name: "Remote",
            lastSeen: Date(), eventAt: Date(), eventID: "heartbeat", origin: .remoteUnmanaged)
        model.connectionReceipts[observed.id] = observed
        task.targetURL = "codex://threads/\(thread)"
        let action = model.navigationAction(for: task)
        XCTAssertNil(action.titleKey)
        XCTAssertEqual(action.noticeKey, "session.navigation.exactUnavailable")
        model.jump(task)
        XCTAssertEqual(model.navigationNoticeKey, "session.remote")
        XCTAssertEqual(model.navigationErrorID, task.id)
        XCTAssertTrue(navigator.destinations.isEmpty)
        let cleared = expectation(description: "Remote notice automatically disappears")
        model.onLayout = { if model.navigationErrorID == nil { cleared.fulfill() } }
        await fulfillment(of: [cleared], timeout: 4)
        XCTAssertNil(model.navigationNoticeKey)
    }

    @MainActor
    func testOldNoticeTimerAndNavigationCallbackCannotClearNewNotice() async {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub(); model.sessionNavigator = navigator
        model.jump(session())
        let old = model.navigationNoticeTimer
        XCTAssertEqual(model.navigationNoticeKey, "session.noLocalTarget")
        model.jump(session(bundle: "com.apple.Terminal"))
        model.jump(session())
        navigator.completions[0](false)
        old?.fire()
        await Task.yield()
        XCTAssertEqual(model.navigationNoticeKey, "session.noLocalTarget")
        XCTAssertEqual(model.navigationErrorID, "task")
    }

    private let thread = "11111111-2222-4333-8444-555555555555"

    private func session(url: String? = nil, bundle: String? = nil) -> AgentSession {
        var session = AgentSession(id: "task", provider: "codex", title: "Review changes")
        session.targetURL = url
        session.terminalBundleID = bundle
        return session
    }

    func testCodexThreadOpensInCodexWithPriorityOverTerminal() {
        let url = "codex://threads/\(thread)"
        XCTAssertEqual(SessionDestination.resolve(session(url: url, bundle: "com.apple.Terminal"), hostBundleID: "dev.zed.Zed"),
                       .link(URL(string: url)!, bundleID: "com.openai.codex"))
    }

    @MainActor
    func testNavigationLabelsDescribeWhatWillOpen() {
        let model = model()
        defer { model.shutdown() }
        let exact = model.navigationAction(for: session(url: "codex://threads/\(thread)"))
        XCTAssertEqual(exact.titleKey, "session.navigation.openSession")
        XCTAssertNil(exact.noticeKey)
        let file = model.navigationAction(for: session(url: "zed://file/tmp/test.swift"))
        XCTAssertEqual(file.titleKey, "session.navigation.openFile")
        XCTAssertEqual(file.noticeKey, "session.navigation.exactUnavailable")
        let app = model.navigationAction(for: session(bundle: "com.apple.Terminal"))
        XCTAssertEqual(app.titleKey, "session.navigation.openApplication")
        XCTAssertEqual(app.noticeKey, "session.navigation.exactUnavailable")
        let missing = model.navigationAction(for: session(url: "https://example.com"))
        XCTAssertNil(missing.titleKey)
        XCTAssertEqual(missing.noticeKey, "session.navigation.exactUnavailable")
    }

    func testEditorFileLinksAndTerminalActivation() {
        let url = "vscode://file/Users/me/My%20Project/src.swift:10:2"
        XCTAssertEqual(SessionDestination.resolve(session(url: url)),
                       .link(URL(string: url)!, bundleID: "com.microsoft.VSCode"))
        XCTAssertEqual(SessionDestination.resolve(session(bundle: "com.mitchellh.ghostty")),
                       .application("com.mitchellh.ghostty"))
        XCTAssertNil(SessionDestination.resolve(session()))
        XCTAssertNil(SessionDestination.resolve(session(bundle: "bad app;command")))
    }

    func testUntrustedCommandAndMalformedRoutesAreNotOpened() {
        for url in ["https://example.com", "file:///tmp/example", "vscode://publisher.extension/action",
                    "vscode://file/tmp/x?command=run", "cursor://command/run", "zed://file/tmp/x#run",
                    "ghostty://run?command=ls", "codex://threads/not-a-thread", "codex://threads/\(thread)/extra",
                    "codex://user@threads/\(thread)", "codex://threads/\(thread)?prompt=run",
                    "vscode://file/tmp/%0Ax"] {
            XCTAssertNil(SessionDestination.resolve(session(url: url)), url)
            XCTAssertEqual(SessionDestination.resolve(session(url: url, bundle: "com.apple.Terminal")),
                           .application("com.apple.Terminal"), url)
        }
    }

    @MainActor
    private func model() -> AppModel {
        let suite = "si-notch.navigation-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(defaults: defaults)
    }

    @MainActor
    func testSuccessfulJumpKeepsPanelOpenAndSessionAvailable() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        let task = session(bundle: "com.mitchellh.ghostty")
        model.store.apply(AgentEvent(sessionID: task.id, provider: "codex", kind: .working))
        model.setExpanded(true)
        model.activateSession(task)
        XCTAssertEqual(navigator.destinations, [.application("com.mitchellh.ghostty")])
        XCTAssertTrue(model.expanded)
        navigator.completions[0](true)
        XCTAssertTrue(model.expanded)
        XCTAssertNotNil(model.store.sessions[task.id])
        XCTAssertNil(model.navigationErrorID)
    }

    @MainActor
    func testOpeningApplicationFallbackKeepsUnreadRequestReminder() throws {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.inject(["event": "agent.waiting", "provider": "pi", "session_id": "waiting",
                      "terminal_bundle_id": "com.apple.Terminal", "attention_request_id": "question"])
        let task = try XCTUnwrap(model.store.sessions["waiting"])
        XCTAssertNotNil(model.attentionIdentity(task.id))
        model.reminders.update(id: task.id, status: .waiting, now: 1, delay: 1, includeCompleted: false)
        model.jump(task)
        XCTAssertEqual(navigator.destinations, [.application("com.apple.Terminal")])
        navigator.completions.first?(true)
        XCTAssertEqual(model.reminders.due(now: 2, states: [task.id: .waiting]), [task.id])
    }

    @MainActor
    func testJumpLeavesCollapseToPointerExit() async throws {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.defaults.set(false, forKey: "keepOpen")
        model.pointerInside = true
        model.setExpanded(true)
        model.jump(session(bundle: "com.apple.Terminal"))
        navigator.completions[0](true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.expanded, "Opening another app must not collapse the hovered island")
        let closed = expectation(description: "Pointer exit collapses the island")
        model.onLayout = { if !model.expanded { closed.fulfill() } }
        let leavingAt = Date()
        model.hover(false)
        XCTAssertEqual(try XCTUnwrap(model.expansionTimer).fireDate.timeIntervalSince(leavingAt),
                       IslandTiming.hoverExit, accuracy: 0.05)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(model.expanded, "Pointer exit should still collapse the island")
    }

    @MainActor
    func testFailedOrMissingTargetKeepsPanelOpenWithInlineError() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.setExpanded(true)
        model.jump(session())
        XCTAssertEqual(model.navigationErrorID, "task")
        XCTAssertTrue(navigator.destinations.isEmpty)
        model.jump(session(bundle: "com.apple.Terminal"))
        XCTAssertNil(model.navigationErrorID)
        navigator.completions[0](false)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.navigationErrorID, "task")
    }

    @MainActor
    func testDisabledJumpTogglesDetailsAndNeverOpensApplication() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.defaults.set(true, forKey: "disableClickJump")
        let action = model.navigationAction(for: session(bundle: "com.apple.Terminal"))
        XCTAssertNil(action.titleKey)
        XCTAssertNil(action.noticeKey)
        model.activateSession(session(bundle: "com.apple.Terminal"))
        XCTAssertEqual(model.selectedID, "task")
        model.activateSession(session(bundle: "com.apple.Terminal"))
        XCTAssertNil(model.selectedID)
        model.jump(session(bundle: "com.apple.Terminal"))
        XCTAssertTrue(navigator.destinations.isEmpty)
    }

    @MainActor
    func testPanelTaskShortcutsIgnoreAgentsAndHistory() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.store.apply(AgentEvent(sessionID: "task", provider: "codex", kind: .working,
                                     terminalBundleID: "com.apple.Terminal"))
        model.setExpanded(true)
        model.selectedID = "task"
        for history in [false, true] {
            model.showAgents = !history
            model.activeFilter = history ? "history.title" : "Все"
            for key in [125, 126, 36, 76, 18] as [UInt16] {
                XCTAssertFalse(model.handlePanelKey(key, characters: key == 18 ? "1" : nil))
            }
            model.selectedID = nil
            model.moveSelection(1)
            XCTAssertNil(model.selectedID)
            model.selectedID = "task"
        }
        XCTAssertTrue(navigator.destinations.isEmpty)
        XCTAssertTrue(model.handlePanelKey(53, characters: nil), "Escape still closes either tab")
        XCTAssertFalse(model.expanded)
    }

    @MainActor
    func testPanelReturnNeverOpensSelectionHiddenByFilterOrSearch() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.store.apply(AgentEvent(sessionID: "task", provider: "codex", kind: .working,
                                     title: "Visible task", terminalBundleID: "com.apple.Terminal"))
        model.setExpanded(true)
        model.selectedID = "task"
        model.activeFilter = "Готово"
        XCTAssertFalse(model.handlePanelKey(36, characters: nil))
        model.activeFilter = "Все"
        model.search = "no matching task"
        XCTAssertFalse(model.handlePanelKey(36, characters: nil))
        XCTAssertTrue(navigator.destinations.isEmpty)
        model.search = ""
        XCTAssertTrue(model.handlePanelKey(36, characters: nil))
        XCTAssertEqual(navigator.destinations, [.application("com.apple.Terminal")])
        model.selectedID = nil
        XCTAssertTrue(model.handlePanelKey(18, characters: "1"))
        XCTAssertEqual(model.selectedID, "task")
    }

    @MainActor
    func testStaleCompletionCannotClosePanelAfterAnotherJumpFails() {
        let model = model()
        defer { model.shutdown() }
        let navigator = NavigatorStub()
        model.sessionNavigator = navigator
        model.setExpanded(true)
        model.jump(session(bundle: "com.apple.Terminal"))
        model.jump(session())
        navigator.completions[0](true)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.navigationErrorID, "task")
    }
}

@MainActor
private final class NavigatorStub: SessionNavigating {
    var destinations: [SessionDestination] = []
    var completions: [@MainActor @Sendable (Bool) -> Void] = []
    func open(_ destination: SessionDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        destinations.append(destination)
        completions.append(completion)
    }
}
