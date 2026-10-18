import Foundation

/// Uses the same hooks/list -> config/batchWrite exact-hash flow as Codex CLI's
/// /hooks browser. This never disables hook trust or approves another command.
struct CodexHookAuthorization {
    struct Hook: Equatable {
        let eventName: String
        let key: String
        let currentHash: String
        let trustStatus: String
    }

    struct ReviewPlan: Equatable {
        let command: String
        let sourcePath: String
        let hooks: [Hook]

        var pendingCount: Int { hooks.filter { $0.trustStatus != "trusted" }.count }
    }

    enum AuthorizationError: Error {
        case invalidBinary, launchFailed, timedOut, protocolError, serverError
        case incompleteHooks, changedSinceReview, notTrustedAfterWrite
    }

    let command: String
    let sourcePath: String
    let cwd: String

    init(command: String, sourcePath: String, cwd: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.command = command
        self.sourcePath = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        self.cwd = cwd
    }

    /// Read-only exact-definition plan for a review panel or an explicitly
    /// user-initiated Connect action for this packaged adapter.
    func prepare(binary: URL) async throws -> ReviewPlan {
        try await perform(binary: binary) { transport in
            try self.plan(from: transport.request("hooks/list", params: ["cwds": [self.cwd]]))
        }
    }

    /// Re-lists hooks in a fresh app-server process, rejects any changed
    /// definition, then writes only the reviewed keys/hashes through Codex's
    /// supported configuration API and verifies that Codex now reports trust.
    func authorize(binary: URL, reviewed: ReviewPlan) async throws {
        try await perform(binary: binary) { transport in
            try self.authorize(reviewed: reviewed) { method, params in
                try transport.request(method, params: params)
            }
        }
    }

    /// Internal exchange form permits full lifecycle tests without touching
    /// user configuration or starting a model session.
    func authorize(reviewed: ReviewPlan,
                   exchange: (_ method: String, _ params: [String: Any]) throws -> [String: Any]) throws {
        guard reviewed.command == command, reviewed.sourcePath == sourcePath else {
            throw AuthorizationError.changedSinceReview
        }
        let fresh = try plan(from: exchange("hooks/list", ["cwds": [cwd]]))
        guard fresh == reviewed else { throw AuthorizationError.changedSinceReview }
        if fresh.pendingCount > 0 {
            let response = try exchange("config/batchWrite", Self.writeParams(for: fresh))
            guard let status = response["status"] as? String,
                  status == "ok" || status == "okOverridden" else {
                throw AuthorizationError.protocolError
            }
        }
        let after = try plan(from: exchange("hooks/list", ["cwds": [cwd]]))
        guard after.command == reviewed.command,
              after.sourcePath == reviewed.sourcePath,
              after.hooks.count == reviewed.hooks.count,
              zip(after.hooks, reviewed.hooks).allSatisfy({ actual, expected in
                  actual.eventName == expected.eventName && actual.key == expected.key &&
                  actual.currentHash == expected.currentHash && actual.trustStatus == "trusted"
              }) else { throw AuthorizationError.notTrustedAfterWrite }
    }

    func plan(from result: [String: Any]) throws -> ReviewPlan {
        guard let entries = result["data"] as? [[String: Any]],
              let entry = entries.first(where: { $0["cwd"] as? String == cwd }),
              entries.filter({ $0["cwd"] as? String == cwd }).count == 1,
              let warnings = entry["warnings"] as? [Any], warnings.isEmpty,
              let errors = entry["errors"] as? [Any], errors.isEmpty,
              let listed = entry["hooks"] as? [[String: Any]] else {
            throw AuthorizationError.protocolError
        }
        let expected = Set(CodexHookSetup.events.map(Self.eventWireName))
        var found: [String: Hook] = [:]
        for value in listed {
            guard value["command"] as? String == command else { continue }
            guard value["source"] as? String == "user",
                  value["isManaged"] as? Bool == false,
                  value["enabled"] as? Bool == true,
                  let path = value["sourcePath"] as? String,
                  URL(fileURLWithPath: path).standardizedFileURL.path == sourcePath,
                  let event = value["eventName"] as? String, expected.contains(event),
                  let key = value["key"] as? String, !key.isEmpty, key.count <= 4096,
                  let hash = value["currentHash"] as? String, !hash.isEmpty, hash.count <= 256,
                  let status = value["trustStatus"] as? String,
                  ["untrusted", "modified", "trusted"].contains(status),
                  found[event] == nil else { throw AuthorizationError.incompleteHooks }
            found[event] = Hook(eventName: event, key: key, currentHash: hash, trustStatus: status)
        }
        guard found.count == expected.count,
              Set(found.values.map(\.key)).count == expected.count else {
            throw AuthorizationError.incompleteHooks
        }
        return ReviewPlan(command: command, sourcePath: sourcePath,
                          hooks: found.values.sorted { $0.eventName < $1.eventName })
    }

    static func writeParams(for plan: ReviewPlan) -> [String: Any] {
        let values = Dictionary(uniqueKeysWithValues: plan.hooks
            .filter { $0.trustStatus != "trusted" }
            .map { ($0.key, ["trusted_hash": $0.currentHash]) })
        return ["edits": [["keyPath": "hooks.state", "mergeStrategy": "upsert", "value": values]],
                "reloadUserConfig": true]
    }

    private static func eventWireName(_ event: String) -> String {
        event.prefix(1).lowercased() + event.dropFirst()
    }

    private func perform<T>(binary: URL, body: @escaping (HookAuthorizationTransport) throws -> T) async throws -> T {
        guard binary.isFileURL, binary.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw AuthorizationError.invalidBinary
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transport = try HookAuthorizationTransport(binary: binary)
                    defer { transport.close() }
                    continuation.resume(returning: try body(transport))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class HookAuthorizationTransport {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data(), count = 0, nextID = 2
    private let started = Date()
    private let deadline: DispatchWorkItem

    init(binary: URL) throws {
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CodexHookAuthorization.AuthorizationError.launchFailed }
        let process = self.process
        deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        do {
            _ = try request("initialize", params: ["clientInfo":
                ["name": "si_notch_hooks", "title": "si-notch", "version": "0.3.0"]], id: 1)
            try write(["method": "initialized", "params": [:] as [String: String]])
        } catch {
            close()
            throw error
        }
    }

    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try request(method, params: params, id: id)
    }

    private func request(_ method: String, params: [String: Any], id: Int) throws -> [String: Any] {
        try write(["id": id, "method": method, "params": params])
        while true {
            if Date().timeIntervalSince(started) > 8 {
                throw CodexHookAuthorization.AuthorizationError.timedOut
            }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                count += 1
                guard count <= 1000, line.count <= 1_048_576,
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexHookAuthorization.AuthorizationError.protocolError
                }
                guard object["id"] as? Int == id else { continue }
                if object["error"] != nil { throw CodexHookAuthorization.AuthorizationError.serverError }
                guard let result = object["result"] as? [String: Any] else {
                    throw CodexHookAuthorization.AuthorizationError.protocolError
                }
                return result
            }
            guard buffer.count < 1_048_576 else { throw CodexHookAuthorization.AuthorizationError.protocolError }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw CodexHookAuthorization.AuthorizationError.protocolError }
            buffer.append(chunk)
        }
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func close() {
        deadline.cancel()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
