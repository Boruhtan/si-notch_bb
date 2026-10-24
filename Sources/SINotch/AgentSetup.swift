import Darwin
import Foundation
import CryptoKit
import SINotchCore

/// Installs only bundled observers. It never installs or launches a harness.
struct AgentSetup {
    struct LocalHermesProfile: Identifiable, Equatable {
        let name: String
        let home: URL
        var id: String { home.path }
    }
    struct FileChange: Equatable {
        let url: URL
        let original: Data?
        let proposed: Data
        var changed: Bool { original != proposed }
    }
    struct Preview {
        let files: [FileChange]
        var canApply: Bool { files.contains(where: \.changed) }
    }
    enum SetupError: Error {
        case invalidHelper, unsupportedFile, conflictingAdapter, hooksDisabled, changedSincePreview, busy, writeFailed
    }

    let provider: HarnessKind
    let helperURL: URL
    let home: URL
    let environment: [String: String]
    private let manager = FileManager.default

    init(provider: HarnessKind, helperPath: String,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.provider = provider
        self.helperURL = URL(fileURLWithPath: helperPath)
        self.home = home
        self.environment = environment
    }

    /// Only the selected local Hermes root and its immediate named profiles.
    /// Configuration contents, histories and credentials are never read here.
    func localHermesProfiles() -> [LocalHermesProfile] {
        let root = configRoot("HERMES_HOME", fallback: ".hermes")
        let directory = root.appendingPathComponent("profiles", isDirectory: true)
        let children = (try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let named = children.filter {
            guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  !$0.lastPathComponent.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            return manager.fileExists(atPath: $0.appendingPathComponent("config.yaml").path)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return [LocalHermesProfile(name: "default", home: root)] + named.map { .init(name: $0.lastPathComponent, home: $0) }
    }

    var hermesEnableCommand: String {
        "HERMES_HOME=" + quote(configRoot("HERMES_HOME", fallback: ".hermes").path) + " hermes plugins enable si-notch"
    }

    func preview() throws -> Preview {
        guard helperURL.path.hasPrefix("/"), helperURL.lastPathComponent == "si-notchctl",
              !helperURL.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (try? manager.attributesOfItem(atPath: helperURL.path)[.type]) as? FileAttributeType == .typeRegular,
              (try? manager.destinationOfSymbolicLink(atPath: helperURL.path)) == nil,
              manager.isExecutableFile(atPath: helperURL.path) else {
            throw SetupError.invalidHelper
        }
        if provider == .opencode || provider == .hermes { return try pluginPreview() }
        let url = try settingsURL()
        let original = try read(url)
        var settings = try object(original)
        if settings["disableAllHooks"] as? Bool == true || settings["allowManagedHooksOnly"] as? Bool == true {
            throw SetupError.hooksDisabled
        }
        if [.cursor, .copilot].contains(provider) {
            if let version = settings["version"], (version as? Int) != 1 { throw SetupError.unsupportedFile }
            settings["version"] = 1
        }
        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else { throw SetupError.unsupportedFile }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = original == nil
        for (name, entry) in try hookEntries() {
            guard hooks[name] == nil || hooks[name] is [[String: Any]] else { throw SetupError.unsupportedFile }
            var existing = hooks[name] as? [[String: Any]] ?? []
            if !existing.contains(where: { NSDictionary(dictionary: $0).isEqual(to: entry) }) {
                // Preserve all user hooks, including independently configured
                // permission bridges. Detect ambiguous old observer copies.
                let encoded = try JSONSerialization.data(withJSONObject: existing)
                let text = String(decoding: encoded, as: UTF8.self)
                if text.contains("si-notchctl") && (text.contains("hook --agent " + provider.rawValue) || text.contains("harness-hook")) {
                    throw SetupError.conflictingAdapter
                }
                existing.append(entry)
                hooks[name] = existing
                changed = true
            }
        }
        settings["hooks"] = hooks
        return Preview(files: [FileChange(url: url, original: original,
            proposed: changed ? try encode(settings) : original!)])
    }

    func apply(_ preview: Preview) throws -> [URL] {
        guard preview.canApply else { return [] }
        let fresh = try self.preview()
        guard fresh.files == preview.files else { throw SetupError.changedSincePreview }
        let changes = preview.files.filter(\.changed)
        guard let directory = changes.first?.url.deletingLastPathComponent() else { return [] }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = directory.appendingPathComponent(".si-notch-setup.lock")
        do { try manager.createDirectory(at: lock, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw SetupError.busy }
        defer { try? manager.removeItem(at: lock) }
        guard try self.preview().files == preview.files else { throw SetupError.changedSincePreview }
        var backups: [URL] = []
        var written: [FileChange] = []
        do {
            for change in changes {
                guard try read(change.url) == change.original else { throw SetupError.changedSincePreview }
                if let original = change.original {
                    let backup = change.url.deletingLastPathComponent().appendingPathComponent(change.url.lastPathComponent + ".si-notch-backup-" + UUID().uuidString)
                    try replace(original, at: backup)
                    backups.append(backup)
                }
                guard try read(change.url) == change.original else { throw SetupError.changedSincePreview }
                try replace(change.proposed, at: change.url)
                written.append(change)
            }
        } catch {
            for change in written.reversed() where (try? read(change.url)) == change.proposed {
                if let original = change.original { try? replace(original, at: change.url) }
                else { try? manager.removeItem(at: change.url) }
            }
            throw error
        }
        return backups
    }

    func settingsURL() throws -> URL {
        switch provider {
        case .claude: return configRoot("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("settings.json")
        case .gemini: return home.appendingPathComponent(".gemini/settings.json")
        case .copilot: return configRoot("COPILOT_HOME", fallback: ".copilot").appendingPathComponent("hooks/si-notch.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        default: throw SetupError.unsupportedFile
        }
    }

    func hookEntries() throws -> [String: [String: Any]] {
        if provider == .claude {
            let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                          "PermissionRequest", "Notification", "SubagentStart", "SubagentStop", "PreCompact",
                          "PostCompact", "Stop", "StopFailure", "SessionEnd"]
            let hook: [String: Any] = ["type": "command", "command": quote(helperURL.path) + " hook --agent claude", "timeout": 2]
            return Dictionary(uniqueKeysWithValues: events.map { ($0, ["hooks": [hook]]) })
        }
        guard let events = HarnessHook.events[provider.rawValue] else { throw SetupError.unsupportedFile }
        return Dictionary(uniqueKeysWithValues: events.keys.map { name in
            let command = quote(helperURL.path) + " harness-hook --agent " + provider.rawValue + " --event " + name
            let entry: [String: Any]
            switch provider {
            case .gemini:
                entry = ["hooks": [["type": "command", "name": "si-notch", "command": command, "timeout": 1500] as [String: Any]]]
            case .copilot:
                entry = ["type": "command", "exec": helperURL.path,
                         "args": ["harness-hook", "--agent", "copilot", "--event", name], "timeoutSec": 1.5]
            default: entry = ["command": command, "timeout": 1.5]
            }
            return (name, entry)
        })
    }

    private func pluginPreview() throws -> Preview {
        let adapters = helperURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/adapters")
        let destination: URL
        let names: [(String, String, String)]
        if provider == .opencode {
            destination = configRoot("XDG_CONFIG_HOME", fallback: ".config").appendingPathComponent("opencode/plugins")
            names = [("opencode-si-notch.js", "si-notch.js", "SINotchPlugin")]
        } else {
            destination = configRoot("HERMES_HOME", fallback: ".hermes").appendingPathComponent("plugins/si-notch")
            names = [("hermes-si-notch/__init__.py", "__init__.py", "Hermes Agent observer plugin for si-notch"),
                     ("hermes-si-notch/plugin.yaml", "plugin.yaml", "name: si-notch")]
        }
        var changes: [FileChange] = []
        for (source, name, marker) in names {
            guard let proposed = try read(adapters.appendingPathComponent(source)), !proposed.isEmpty else { throw SetupError.unsupportedFile }
            let url = destination.appendingPathComponent(name)
            let original = try read(url)
            if let original, !String(decoding: original, as: UTF8.self).contains(marker) { throw SetupError.conflictingAdapter }
            changes.append(FileChange(url: url, original: original, proposed: proposed))
        }
        let configURL = destination.appendingPathComponent("si-notch.json")
        let original = try read(configURL)
        var config = try object(original)
        config["helperPath"] = helperURL.path
        if provider == .hermes {
            if config["displayName"] == nil {
                let profile = configRoot("HERMES_HOME", fallback: ".hermes").lastPathComponent
                config["displayName"] = profile == ".hermes" ? "Hermes" : String(profile.prefix(128))
            }
            let instance = config["instanceId"] as? String
            if !(instance.map { !$0.isEmpty && $0.count <= 4096 } ?? false) {
                // Stable during preview/apply; independent for every local
                // profile directory. Existing identities survive all upgrades.
                let identity = ProcessInfo.processInfo.hostName + ":" + destination.standardizedFileURL.path
                config["instanceId"] = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
        changes.append(FileChange(url: configURL, original: original, proposed: try encode(config)))
        return Preview(files: changes)
    }

    private func configRoot(_ key: String, fallback: String) -> URL {
        if let path = environment[key], path.hasPrefix("/"), path.utf8.count <= 4096,
           !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func object(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SetupError.unsupportedFile }
        return object
    }
    private func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        guard data.count <= 1_048_576 else { throw SetupError.unsupportedFile }
        return data
    }
    private func read(_ url: URL) throws -> Data? {
        if (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil { throw SetupError.unsupportedFile }
        guard manager.fileExists(atPath: url.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else { throw SetupError.unsupportedFile }
        return try Data(contentsOf: url)
    }
    private func replace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".si-notch-" + UUID().uuidString)
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw SetupError.writeFailed }
        defer { close(fd); unlink(temporary.path) }
        let ok = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard ok, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw SetupError.writeFailed }
    }
}
