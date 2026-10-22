import Foundation

/// Runs exclusively on the Desktop stream queue. A click starts a fresh snapshot
/// and owner check; mutation is sent once, then both RPC and stream must confirm it.
final class CodexInteractionBridge {
    private struct Entry {
        var state = CodexInteractionState()
        let host: String
        let owner: String
        var firstSeen: [String: TimeInterval] = [:]
        var requests: [CodexInteraction] = []
    }
    private struct Submission {
        enum Stage { case snapshot, owner, response, resolution }
        let request: CodexInteraction
        let host: String
        let owner: String
        let method: String
        let params: [String: Any]
        let deadline: TimeInterval
        let completion: (Bool) -> Void
        var stage: Stage = .snapshot
        var rpcID = UUID().uuidString
        var resolved = false
    }
    private var entries: [String: Entry] = [:]
    private var submissions: [String: Submission] = [:]
    private var sent: Set<String> = []
    private let update: (String, [CodexInteraction]) -> Void
    private let send: ([String: Any]) -> Void
    private let refresh: (String) -> Void
    private var clientID: String?

    init(update: @escaping (String, [CodexInteraction]) -> Void,
         send: @escaping ([String: Any]) -> Void, refresh: @escaping (String) -> Void) {
        self.update = update; self.send = send; self.refresh = refresh
    }
    func connected(clientID: String) { self.clientID = clientID }

    func consume(sessionID: String, host: String, owner: String, change: [String: Any], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard UUID(uuidString: owner) != nil, ["local", "durable"].contains(host) else { return }
        let previous = entries[sessionID]
        if let previous, previous.host != host || previous.owner != owner {
            guard change["type"] as? String == "snapshot" else { return }
            finish(sessionID, success: false)
        }
        var entry = previous?.host == host && previous?.owner == owner ? previous! : Entry(host: host, owner: owner)
        guard entry.state.apply(change) else { remove(sessionID); return }
        let requests = entry.state.requests(sessionID: sessionID)
        for request in requests where entry.firstSeen[request.id] == nil { entry.firstSeen[request.id] = now }
        entry.firstSeen = entry.firstSeen.filter { key, _ in requests.contains { $0.id == key } }
        entry.requests = requests.compactMap { request in
            var request = request
            request.expiresAt = entry.firstSeen[request.id]! + 300
            return now < request.expiresAt ? request : nil
        }
        entries[sessionID] = entry
        if entry.requests != previous?.requests { update(sessionID, entry.requests) }
        guard var submission = submissions[sessionID] else { return }
        let stillPending = entry.requests.contains { $0.id == submission.request.id }
        if submission.stage == .snapshot, change["type"] as? String == "snapshot" {
            guard stillPending, submission.request.expiresAt > now else { finish(sessionID, success: false); return }
            submission.stage = .owner
            submissions[sessionID] = submission
            request(id: submission.rpcID, method: "thread-owner-discovery",
                    params: ["hostId": host, "conversationId": sessionID], owner: owner, host: nil)
        } else if !stillPending {
            if submission.stage == .owner { finish(sessionID, success: false); return }
            if submission.method == "thread-follower-steer-turn", !entry.state.confirmsAsyncAnswer(submission.request) {
                finish(sessionID, success: false); return
            }
            submission.resolved = true
            submissions[sessionID] = submission
            if submission.stage == .resolution { finish(sessionID, success: true) }
        }
    }

    func submit(_ interaction: CodexInteraction, action: String?, answers: [String: String],
                now: TimeInterval = ProcessInfo.processInfo.systemUptime, completion: @escaping (Bool) -> Void) {
        guard clientID != nil, submissions[interaction.sessionID] == nil, sent.count < 4096, !sent.contains(interaction.id),
              interaction.expiresAt > now, let entry = entries[interaction.sessionID],
              entry.requests.contains(interaction), let response = interaction.response(action: action, answers: answers) else { completion(false); return }
        submissions[interaction.sessionID] = Submission(request: interaction, host: entry.host, owner: entry.owner,
            method: response.method, params: response.params, deadline: now + 10, completion: completion)
        refresh(interaction.sessionID)
    }

    func receive(_ frame: [String: Any]) {
        guard frame["type"] as? String == "response", let id = frame["requestId"] as? String,
              let sessionID = submissions.first(where: { $0.value.rpcID == id })?.key,
              var submission = submissions[sessionID] else { return }
        guard frame["resultType"] as? String == "success", frame["handledByClientId"] as? String == submission.owner else {
            finish(sessionID, success: false); return
        }
        if submission.stage == .owner {
            guard frame["method"] as? String == "thread-owner-discovery",
                  ProcessInfo.processInfo.systemUptime < submission.request.expiresAt,
                  entries[sessionID]?.requests.contains(submission.request) == true else { finish(sessionID, success: false); return }
            submission.stage = .response; submission.rpcID = UUID().uuidString
            submissions[sessionID] = submission
            sent.insert(submission.request.id)
            request(id: submission.rpcID, method: submission.method, params: submission.params,
                    owner: submission.owner, host: submission.host == "local" ? nil : submission.host)
        } else if submission.stage == .response {
            guard frame["method"] as? String == submission.method,
                  let result = frame["result"] as? [String: Any] else { finish(sessionID, success: false); return }
            if submission.method == "thread-follower-steer-turn" {
                guard (result["result"] as? [String: Any])?["turnId"] as? String == submission.request.turnID else {
                    finish(sessionID, success: false); return
                }
            } else if result["ok"] as? Bool != true { finish(sessionID, success: false); return }
            // The owner may acknowledge dispatch before the backing request resolves.
            submission.stage = .resolution
            submissions[sessionID] = submission
            if submission.resolved { finish(sessionID, success: true) }
            else { refresh(sessionID) }
        }
    }

    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for (id, submission) in submissions where now >= submission.deadline { finish(id, success: false) }
        for (id, var entry) in entries {
            let active = entry.requests.filter { $0.expiresAt > now }
            if active != entry.requests { entry.requests = active; entries[id] = entry; update(id, active) }
        }
    }
    func remove(_ sessionID: String) {
        finish(sessionID, success: false)
        if entries.removeValue(forKey: sessionID) != nil { update(sessionID, []) }
    }
    func disconnect() {
        clientID = nil
        for id in Array(entries.keys) { remove(id) }
        for id in Array(submissions.keys) { finish(id, success: false) }
        // Retain sent identities across reconnects: never replay an uncertain write.
    }
    private func finish(_ sessionID: String, success: Bool) {
        submissions.removeValue(forKey: sessionID)?.completion(success)
    }
    private func request(id: String, method: String, params: [String: Any], owner: String, host: String?) {
        guard let clientID else { return }
        var frame: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
            "version": host == nil ? 1 : 2, "method": method, "params": params, "targetClientId": owner, "timeoutMs": 5000]
        if let host { frame["hostId"] = host }
        send(frame)
    }
}
