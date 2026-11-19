import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class ApplicationAgentGroupTests: XCTestCase {
    @MainActor func testHostGroupingReusesCanonicalIdentitiesAndNestsLinkedChildren() throws {
        let suite = "test.host-groups." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        func receive(_ event: AgentEvent, origin: AgentConnection.Origin = .local) throws {
            model.receive(try JSONEncoder().encode(event), origin: origin) { _ in }
        }
        try receive(.init(sessionID: "parent", provider: "codex", kind: .working, terminalBundleID: "dev.zed.Zed"))
        try receive(.init(sessionID: "child", provider: "codex", kind: .working, terminalBundleID: "dev.zed.Zed"))
        try receive(.init(sessionID: "parent", provider: "codex", kind: .subagentStarted,
                          subagent: .init(id: "child", name: "Worker", sessionID: "child"), terminalBundleID: "dev.zed.Zed"))
        try receive(.init(sessionID: "terminal", provider: "codex", kind: .working, terminalBundleID: "com.superlogical.rex"))
        try receive(.init(sessionID: "unverified", provider: "codex", kind: .working, terminalBundleID: "dev.zed.Zed"), origin: .unknown)
        XCTAssertEqual(model.agents.filter { $0.provider == "codex" }.count, 1)
        XCTAssertEqual(model.applicationAgentGroups.first { $0.host == .zed }?.sessions.map(\.id), ["parent"])
        XCTAssertEqual(model.applicationAgentGroups.first { $0.host == .rex }?.sessions.map(\.id), ["terminal"])
        XCTAssertEqual(model.store.sessions["parent"]?.subagents.first?.sessionID, "child")
        let untrusted = model.applicationSessionHosts["unverified"]
        XCTAssertNil(untrusted)
        model.setApplicationGroupExpanded(.rex, false)
        let restored = AppModel(defaults: defaults)
        defer { restored.shutdown() }
        XCTAssertFalse(restored.applicationGroupExpanded(.rex))
        XCTAssertTrue(restored.applicationGroupExpanded(.zed))
    }

    func testRexMetadataDoesNotTurnRemoteShellIntoLocalHost() {
        let env = ["REX_SESSION": "session:sample", "REX_BLOCK": "block:sample", "TERM_PROGRAM": "ghostty"]
        XCTAssertEqual(SessionOrigin.bundleID(environment: env), "com.superlogical.rex")
        var remote = env
        remote["SSH_TTY"] = "/dev/ttys001"
        XCTAssertNil(SessionOrigin.bundleID(environment: remote))
        XCTAssertEqual(SessionOrigin.bundleID(environment: ["TERM_PROGRAM": "zed"]), "dev.zed.Zed")
    }

    func testAncestorFallbackIsLimitedToKnownLocalHosts() {
        let rex = "/User/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
        XCTAssertEqual(SessionOrigin.ancestorHost(executables: ["/bin/sh", rex], home: "/User"), "com.superlogical.rex")
        XCTAssertNil(SessionOrigin.ancestorHost(executables: ["/usr/bin/ssh", rex], home: "/User"))
        XCTAssertNil(SessionOrigin.ancestorHost(executables: ["/tmp/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"], home: "/User"))
        let remote = SessionOrigin.enriching(["event": "agent.working"], environment: ["SSH_TTY": "/dev/ttys001"],
                                             ancestor: "com.superlogical.rex")
        XCTAssertNil(remote["terminal_bundle_id"])
    }
}
