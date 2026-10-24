// Temporary diagnostic runner; removed before packaging the release app.
import Foundation
import SINotchCore

enum LocalAliasVerification {
    @MainActor static func run() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("Local alias contract failed: " + message) }
            checks += 1
        }
        let now = Date(), connector = UUID()
        let task = AgentSession(id: "local-task", provider: "hermes", status: .working)
        let observed = AgentConnection.Observation(provider: "hermes", connectionID: "remote",
            name: "untrusted remote name", lastSeen: now, eventAt: now, eventID: "heartbeat")
        let saved = AgentConnection.Configuration(connectionID: "remote", name: "Don David",
            connectorID: connector, visible: true, transportState: .connected)
        let quiet = AgentConnection.Configuration(connectionID: "customs", name: "customs",
            connectorID: connector, visible: true, transportState: .connected)
        let rows = AgentConnection.project(detected: [], sessions: [task], receipts: ["hermes": now],
            running: ["hermes", "codex"], now: now, connections: [observed.id: observed],
            configurations: [saved, quiet], localDisplayNames: ["hermes": "  Don Digidon  "])
        let local = rows.first { $0.id == "hermes" }!
        check(local.name == "Don Digidon", "local alias")
        check(local.provider == "hermes", "provider identity")
        check(local.state == .online, "local presence")
        check(local.activity == .working, "task activity")
        check(local.activeTaskCount == 1, "task count")
        check(rows.first { $0.id == "codex" }?.name == "Codex", "other provider unchanged")
        check(rows.first { $0.id == observed.id }?.name == "Don David", "remote profile unchanged")
        check(rows.first { $0.id == observed.id }?.connectorID == connector, "SSH grouping unchanged")
        check(rows.first { $0.id == "hermes/customs" }?.name == "customs", "quiet profile unchanged")
        check(rows.count == 4, "no duplicate or hidden provider rows")
        for alias in ["", " \n\t ", "Don\nDigidon", "Don\u{0000}Digidon", String(repeating: "x", count: 129)] {
            let invalid = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
                now: now, localDisplayNames: ["hermes": alias])
            check(invalid.first?.name == "Hermes", "invalid label rejected")
        }
        let boundary = String(repeating: "x", count: 128)
        check(AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
            now: now, localDisplayNames: ["hermes": boundary]).first?.name == boundary, "128-character boundary")
        check(AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
            now: now).first?.name == "Hermes", "no alias preserves original behavior")

        let suite = "si-notch.local-alias-verification." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["hermes": "Don Digidon"], forKey: "localAgentDisplayNames.v1")
        let model = AppModel(defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        for event in [AgentEvent(sessionID: "local", provider: "hermes", kind: .sessionStarted),
                      AgentEvent(sessionID: "presence-remote", provider: "hermes", kind: .agentPresence,
                          connectionID: "remote", connectionName: "Don David")] {
            model.receive(try! JSONEncoder().encode(event)) { _ in }
        }
        check(model.agents.first { $0.id == "hermes" }?.name == "Don Digidon", "AppModel preference wiring")
        check(model.agents.first { $0.id == "hermes/remote" }?.name == "Don David", "AppModel remote name")
        check(!model.agents.contains { $0.name == "Hermes" }, "old generic label replaced")
        defaults.set(["hermes": "Local alias changed"], forKey: "localAgentDisplayNames.v1")
        model.tick()
        check(model.agents.first { $0.id == "hermes" }?.name == "Local alias changed", "tick uses same alias")
        check(model.agents.first { $0.id == "hermes/remote" }?.name == "Don David", "tick preserves remote name")
        print("PASS: \(checks) local alias contract assertions; production AgentConnection and AppModel; isolated defaults")
    }
}
