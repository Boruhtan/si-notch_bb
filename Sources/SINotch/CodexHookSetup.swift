import Foundation

/// Adds si-notch command hooks to hooks.json without replacing other hook groups
/// or touching config.toml/notify. Codex must separately review and trust them.
struct CodexHookSetup {
    struct Preview {
        let hooksURL: URL
        let proposedJSON: String
        let addedEvents: [String]
        let canApply: Bool
        fileprivate let original: Data?
    }

    enum SetupError: LocalizedError {
        case invalidAdapter, invalidHelper, unsupportedFile, changedSincePreview, ambiguousInstallation

        var errorDescription: String? {
            switch self {
            case .invalidAdapter: return "The Codex hook adapter is missing or is not a regular file."
            case .invalidHelper: return "The si-notch helper is missing or is not executable."
            case .unsupportedFile: return "hooks.json must be a regular UTF-8 JSON object with a hooks object."
            case .changedSincePreview: return "hooks.json changed since the preview. Refresh it before applying."
            case .ambiguousInstallation: return "An existing si-notch Codex hook has a different command; review it manually."
            }
        }
    }

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]

    let adapterPath: String
    let helperPath: String
    let hooksURL: URL
    private let files = FileManager.default

    var command: String {
        "/usr/bin/python3 \(Self.shellQuote(adapterPath)) --cli \(Self.shellQuote(helperPath))"
    }

    init(adapterPath: String, helperPath: String,
         hooksURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")) {
        self.adapterPath = adapterPath
        self.helperPath = helperPath
        self.hooksURL = hooksURL
    }

    func preview() throws -> Preview {
        guard Self.isRegularFile(adapterPath) else { throw SetupError.invalidAdapter }
        guard helperPath.hasPrefix("/"), files.isExecutableFile(atPath: helperPath) else { throw SetupError.invalidHelper }
        let original = try readCurrent()
        var root: [String: Any]
        if let original {
            guard original.count <= 1_048_576,
                  let text = String(data: original, encoding: .utf8), !text.hasPrefix("\u{FEFF}"),
                  let value = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SetupError.unsupportedFile
            }
            root = value
        } else {
            root = [:]
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil && !(root["hooks"] is [String: Any]) { throw SetupError.unsupportedFile }
        let command = self.command
        var added: [String] = []
        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if hooks[event] != nil && !(hooks[event] is [[String: Any]]) { throw SetupError.unsupportedFile }
            var alreadyPresent = false
            for group in groups {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw SetupError.unsupportedFile }
                for handler in handlers {
                    guard let existing = handler["command"] as? String else { continue }
                    if existing == command {
                        // A matched or otherwise modified group is not the
                        // unconditional definition we install. Treat it as
                        // ambiguous instead of claiming this event is wired.
                        guard group.count == 1, handlers.count == 1,
                              handler.count == 3,
                              handler["type"] as? String == "command",
                              handler["timeout"] as? Int == 3 else {
                            throw SetupError.ambiguousInstallation
                        }
                        alreadyPresent = true
                    }
                    else if existing.contains("codex-hook.py") { throw SetupError.ambiguousInstallation }
                }
            }
            if alreadyPresent { continue }
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
            hooks[event] = groups
            added.append(event)
        }
        root["hooks"] = hooks
        guard JSONSerialization.isValidJSONObject(root),
              let proposed = try? JSONSerialization.data(withJSONObject: root,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              proposed.count <= 1_048_576,
              let proposedJSON = String(data: proposed, encoding: .utf8) else { throw SetupError.unsupportedFile }
        return Preview(hooksURL: hooksURL, proposedJSON: proposedJSON + "\n",
                       addedEvents: added, canApply: !added.isEmpty, original: original)
    }

    /// Called only after the user reviews the preview. Returns a dated backup.
    func apply(_ preview: Preview) throws -> URL? {
        guard preview.hooksURL == hooksURL,
              preview.canApply, try readCurrent() == preview.original else { throw SetupError.changedSincePreview }
        // Confirm the current adapter/helper and exact proposal still match.
        let current = try self.preview()
        guard current.proposedJSON == preview.proposedJSON,
              current.addedEvents == preview.addedEvents else { throw SetupError.changedSincePreview }
        let directory = hooksURL.deletingLastPathComponent()
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        let oldMode = try preview.original.map { _ in
            (try files.attributesOfItem(atPath: hooksURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        }
        var backup: URL?
        if let original = preview.original {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let candidate = directory.appendingPathComponent("hooks.json.si-notch-backup-\(stamp)-\(UUID().uuidString)")
            try files.copyItem(at: hooksURL, to: candidate)
            backup = candidate
            guard try Data(contentsOf: candidate) == original,
                  try readCurrent() == original else { throw SetupError.changedSincePreview }
        }
        try Data(preview.proposedJSON.utf8).write(to: hooksURL, options: .atomic)
        try files.setAttributes([.posixPermissions: oldMode ?? 0o600], ofItemAtPath: hooksURL.path)
        return backup
    }

    private func readCurrent() throws -> Data? {
        let path = hooksURL.path
        if (try? files.destinationOfSymbolicLink(atPath: path)) != nil { throw SetupError.unsupportedFile }
        guard files.fileExists(atPath: path) else { return nil }
        guard Self.isRegularFile(path) else { throw SetupError.unsupportedFile }
        return try Data(contentsOf: hooksURL)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { return false }
        return true
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
