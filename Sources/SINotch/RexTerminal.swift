import AppKit
import Darwin
import Foundation

/// Uses Rex's installed CLI and the local Unix socket for tab creation and focus.
struct RexTerminal: Sendable {
    static let bundleID = "com.superlogical.rex"

    struct Block: Hashable, Sendable {
        let session: String
        let block: String

        init?(session: String, block: String) {
            guard RexTerminal.validID(session, kind: "session"), RexTerminal.validID(block, kind: "block") else { return nil }
            self.session = session
            self.block = block
        }
    }

    func attention() -> [RexAttentionItem] {
        guard FileManager.default.fileExists(atPath: endpoint),
              let session = selectedSession(),
              let host = read(["whoami"])?["host_id"] as? String,
              let blocks = read(["block", "ls", "-s", session])?["blocks"] as? [[String: Any]] else { return [] }
        return blocks.lazy.filter {
            $0["host_id"] as? String == host && $0["flavor"] as? String == "com.superlogical.terminal.shell"
        }.prefix(48).flatMap { item -> [RexAttentionItem] in
            guard let id = item["block_id"] as? String, let block = Block(session: session, block: id),
                  let data = call(["block", "call", "-s", session, "-b", id, "program_status"]),
                  let snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            return RexAttentionItem.items(from: snapshot, block: block)
        }
    }

    private let executable: URL
    private let application: URL
    private let endpoint: String

    @MainActor
    static func installed() -> Self? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let candidates = [
            library.appendingPathComponent("com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"),
            app.appendingPathComponent("Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"),
        ]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
        return Self(executable: cli, application: app,
                    endpoint: library.appendingPathComponent("rex/server.sock").path)
    }

    @MainActor
    func focus(_ target: Block, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        perform({
            guard let response = self.read(["block", "inspect", "-s", target.session, target.block]),
                  let block = response["block"] as? [String: Any],
                  block["block_id"] as? String == target.block,
                  self.selectedSession() == target.session else { return false }
            return self.call(["focus", "-s", target.session, target.block]) != nil
        }, completion: completion)
    }

    @MainActor
    func launch(_ command: SessionTerminal.Command, label: String,
                completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        perform({
            guard let session = self.selectedSession() else { return false }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let path = home + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            var arguments = ["run", "-s", session, "--shell=none", "--keep-open", "--label", label]
            if let cwd = command.workingDirectory { arguments += ["-c", cwd] }
            arguments += ["--", "/usr/bin/env", "PATH=" + path, command.program] + command.arguments
            guard let created = self.read(arguments),
                  let blocks = created["block_ids"] as? [String],
                  blocks.count == 1, Self.validID(blocks[0], kind: "block") else { return false }
            return true
        }, completion: completion)
    }

    @MainActor
    private func perform(_ work: @escaping @Sendable () -> Bool,
                         completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        Task { @MainActor in
            guard await Task.detached(priority: .userInitiated, operation: work).value else { completion(false); return }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first {
                _ = running.activate(options: [])
            } else {
                guard (try? await NSWorkspace.shared.openApplication(
                    at: application, configuration: NSWorkspace.OpenConfiguration())) != nil else {
                    completion(false)
                    return
                }
            }
            completion(true)
        }
    }

    private func selectedSession() -> String? {
        guard let clients = read(["client", "ls"])?["clients"] as? [[String: Any]] else { return nil }
        let local = clients.filter { item in
            let principal = item["principal"] as? [String: Any]
            let info = item["info"] as? [String: Any]
            return principal?["transport"] as? String == "unix" && principal?["uid"] as? Int == Int(getuid()) &&
                info?["kind"] as? String == "app" && info?["platform"] as? String == "macos" &&
                item["connection_state"] as? String == "connected"
        }
        let attached = Set(local.flatMap { $0["session_ids"] as? [String] ?? [] })
        if attached.count == 1, let id = attached.first, Self.validID(id, kind: "session") { return id }
        guard attached.isEmpty, let list = read(["ls"])?["sessions"] as? [[String: Any]],
              list.count == 1, let id = list.first?["session_id"] as? String,
              Self.validID(id, kind: "session") else { return nil }
        return id
    }

    private func read(_ arguments: [String]) -> [String: Any]? {
        let index = arguments.firstIndex(of: "--") ?? arguments.endIndex
        var jsonArguments = arguments
        jsonArguments.insert("--json", at: index)
        guard let data = call(jsonArguments) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func call(_ arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--autostart=false", "--timeout=3s", "--server", endpoint] + arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("REX_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func validID(_ id: String, kind: String) -> Bool {
        let prefix = kind + ":"
        guard id.hasPrefix(prefix), id.utf8.count == prefix.utf8.count + 36 else { return false }
        return UUID(uuidString: String(id.dropFirst(prefix.count))) != nil
    }
}
