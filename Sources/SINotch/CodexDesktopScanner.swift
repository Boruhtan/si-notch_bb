import Darwin
import Foundation
import SINotchCore

/// Read-only fallback for Desktop sessions that do not write local rollouts.
/// Only allowlisted lifecycle markers and UUIDs leave the scanner.
struct CodexDesktopScanner {
    struct Signal {
        let sessionID: String
        let turnID: String?
        let date: Date
        let kind: AgentEventKind
    }
    private struct Cursor {
        let inode: UInt64
        var offset: UInt64
        var partial = Data()
        var discardingLine = false
    }
    private struct Activity {
        var signal: Signal
        var emitted = false
        var idle = false
    }
    let logsRoot: URL
    private var cursors: [String: Cursor] = [:]
    private var activities: [String: Activity] = [:]
    private let limit = 2 * 1024 * 1024
    private let freshness: TimeInterval = 180

    init(logsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/com.openai.codex")) {
        self.logsRoot = logsRoot
    }

    mutating func poll(now: Date = Date()) -> [CodexSessionObservation] {
        var result: [CodexSessionObservation] = []
        var changed: [String: (Signal, Bool)] = [:]
        let selected = candidates(now: now)
        let paths = Set(selected.map(\.path))
        cursors = cursors.filter { paths.contains($0.key) }
        for url in selected {
            guard let metadata = SessionFileMetadata(url), metadata.isRegularFile,
                  metadata.owner == getuid() else { continue }
            let inode = metadata.inode, size = metadata.size
            let previous = cursors[url.path]
            let bootstrap = previous == nil || previous?.inode != inode || size < (previous?.offset ?? 0)
            var cursor = bootstrap ? Cursor(inode: inode, offset: size > limit ? size - UInt64(limit) : 0) : previous!
            let skipPartialLine = bootstrap && cursor.offset > 0
            guard size > cursor.offset else { cursors[url.path] = cursor; continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: cursor.offset)) != nil,
                  let bytes = try? handle.read(upToCount: min(limit, Int(size - cursor.offset))) else { continue }
            cursor.offset += UInt64(bytes.count)
            var data = cursor.partial + bytes
            cursor.partial.removeAll()
            if skipPartialLine || cursor.discardingLine {
                if let boundary = data.firstIndex(of: 10) {
                    data.removeSubrange(...boundary)
                    cursor.discardingLine = false
                } else {
                    cursor.discardingLine = true
                    cursors[url.path] = cursor
                    continue
                }
            }
            while let boundary = data.firstIndex(of: 10) {
                let line = Data(data[..<boundary])
                data.removeSubrange(...boundary)
                guard line.count <= 16 * 1024, let text = String(data: line, encoding: .utf8),
                      let signal = Self.parse(text), now.timeIntervalSince(signal.date) >= -60 else { continue }
                let old = changed[signal.sessionID]?.0 ?? activities[signal.sessionID]?.signal
                guard old == nil || signal.date > old!.date else { continue }
                // A late completion for a previous turn must not stop the new turn.
                if signal.kind == .completed, let old, let turn = old.turnID,
                   let finished = signal.turnID, finished != turn { continue }
                if changed.count < 256 || changed[signal.sessionID] != nil {
                    changed[signal.sessionID] = (signal, bootstrap)
                }
            }
            if data.count <= 16 * 1024 { cursor.partial = data }
            else { cursor.discardingLine = true }
            cursors[url.path] = cursor
        }
        for (id, (signal, bootstrap)) in changed {
            let wasVisible = activities[id]?.emitted == true
            let fresh = now.timeIntervalSince(signal.date) <= freshness
            let emit = fresh && (signal.kind != .completed || (!bootstrap && wasVisible))
            activities[id] = Activity(signal: signal, emitted: wasVisible || emit)
            if emit { result.append(observation(signal, bootstrap: bootstrap)) }
        }
        for id in Array(activities.keys) {
            guard var activity = activities[id] else { continue }
            let age = now.timeIntervalSince(activity.signal.date)
            if activity.emitted, activity.signal.kind == .working, !activity.idle, age > freshness {
                activity.idle = true
                activities[id] = activity
                let idle = Signal(sessionID: id, turnID: activity.signal.turnID, date: now, kind: .sessionStarted)
                result.append(observation(idle, bootstrap: false))
            }
            if age > 3600 { activities[id] = nil }
        }
        return result.sorted { $0.event.timestamp < $1.event.timestamp }
    }

    static func parse(_ line: String) -> Signal? {
        guard line.utf8.count <= 16 * 1024,
              let stamp = line.split(separator: " ", maxSplits: 1).first,
              let date = ISO8601DateFormatter.fractional.date(from: String(stamp)) else { return nil }
        let working = line.contains(" info [electron-message-handler] Reasoning summary item completed ")
        let starting = line.contains(" info [AppServerConnection] response_routed ") &&
            line.contains(" method=turn/start ") && line.contains(" errorCode=null ")
        let complete = line.contains(" info [electron-message-handler] [desktop-notifications] received turn-completed")
        guard working || starting || complete,
              let session = field(working ? "threadId" : "conversationId", in: line),
              UUID(uuidString: session) != nil else { return nil }
        let turn = field("turnId", in: line).flatMap { UUID(uuidString: $0) != nil ? $0 : nil }
        return Signal(sessionID: session, turnID: turn, date: date, kind: complete ? .completed : .working)
    }

    private static func field(_ key: String, in line: String) -> String? {
        line.split(separator: " ").first(where: { $0.hasPrefix(key + "=") })
            .map { String($0.dropFirst(key.count + 1)) }
    }

    private func observation(_ signal: Signal, bootstrap: Bool) -> CodexSessionObservation {
        let event = AgentEvent(sessionID: signal.sessionID, provider: "codex", kind: signal.kind,
            timestamp: signal.date, id: "desktop:\(signal.sessionID):\(signal.date.timeIntervalSince1970):\(signal.kind.rawValue)",
            title: "Codex Desktop", targetURL: "codex://threads/\(signal.sessionID)", turnID: signal.turnID)
        return CodexSessionObservation(event: event, isBootstrap: bootstrap)
    }

    private func candidates(now: Date) -> [URL] {
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var found: [(URL, Date)] = []
        for back in 0...1 {
            let date = calendar.date(byAdding: .day, value: -back, to: now)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let folder = logsRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.lastPathComponent.hasPrefix("codex-desktop-") && url.pathExtension == "log" && url.lastPathComponent.contains("-t0-") {
                guard let metadata = SessionFileMetadata(url), metadata.isRegularFile,
                      metadata.owner == getuid(), now.timeIntervalSince(metadata.modified) < 3600 else { continue }
                found.append((url, metadata.modified))
            }
        }
        return found.sorted { $0.1 < $1.1 }.suffix(4).map(\.0)
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
