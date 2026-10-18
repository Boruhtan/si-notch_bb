import Darwin
import Foundation

/// Registers the bundled observer as a user-level Pi extension. Only
/// settings.extensions changes; credentials and session files are never read.
struct PiSetup {
    struct Preview {
        let settingsURL: URL
        let extensionPath: String
        let existingExtensionCount: Int
        let canApply: Bool
        fileprivate let original: Data?
        fileprivate let proposed: Data
    }

    enum SetupError: Error {
        case invalidAdapter
        case invalidHelper
        case unsupportedFile
        case ambiguousInstallation
        case changedSincePreview
        case busy
        case writeFailed
    }

    let adapterPath: String
    let helperPath: String
    let settingsURL: URL
    private let files = FileManager.default
    private static let maximumSettingsBytes = 1_048_576

    init(adapterPath: String, helperPath: String,
         settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")) {
        self.adapterPath = adapterPath
        self.helperPath = helperPath
        self.settingsURL = settingsURL
    }

    func preview() throws -> Preview {
        guard Self.isRegularFile(adapterPath),
              URL(fileURLWithPath: adapterPath).lastPathComponent == "pi-si-notch.js",
              !adapterPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SetupError.invalidAdapter
        }
        let expectedHelper = URL(fileURLWithPath: adapterPath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/si-notchctl").standardizedFileURL.path
        guard URL(fileURLWithPath: helperPath).standardizedFileURL.path == expectedHelper,
              Self.isRegularFile(helperPath), files.isExecutableFile(atPath: helperPath) else {
            throw SetupError.invalidHelper
        }

        let original = try readCurrent()
        var settings: [String: Any]
        if let original {
            guard original.count <= Self.maximumSettingsBytes,
                  !original.starts(with: [0xEF, 0xBB, 0xBF]),
                  String(data: original, encoding: .utf8) != nil,
                  let object = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw SetupError.unsupportedFile
            }
            settings = object
        } else {
            settings = [:]
        }
        guard settings["extensions"] == nil || settings["extensions"] is [String] else {
            throw SetupError.unsupportedFile
        }
        var extensions = settings["extensions"] as? [String] ?? []
        let target = URL(fileURLWithPath: adapterPath).standardizedFileURL.path
        var installed = false
        for entry in extensions {
            let plain = entry.hasPrefix("+") || entry.hasPrefix("-") ? String(entry.dropFirst()) : entry
            let same = plain == target || (plain.hasPrefix("/") && URL(fileURLWithPath: plain).standardizedFileURL.path == target)
            if same {
                guard !entry.hasPrefix("-") else { throw SetupError.ambiguousInstallation }
                installed = true
            } else if URL(fileURLWithPath: plain).lastPathComponent == "pi-si-notch.js" {
                // An old copy or a relative registration could load another
                // version. Do not silently run both observers.
                throw SetupError.ambiguousInstallation
            }
        }
        if !installed { extensions.append(target) }
        settings["extensions"] = extensions
        guard JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(withJSONObject: settings,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              data.count + 1 <= Self.maximumSettingsBytes else { throw SetupError.unsupportedFile }
        var proposed = data
        proposed.append(0x0A)
        return Preview(settingsURL: settingsURL, extensionPath: target,
                       existingExtensionCount: extensions.count - (installed ? 0 : 1),
                       canApply: !installed, original: original, proposed: proposed)
    }

    /// Rechecks the preview while holding Pi's own settings.json.lock directory.
    /// Returns a backup path when an existing settings.json was replaced.
    func apply(_ preview: Preview) throws -> URL? {
        guard preview.settingsURL == settingsURL, preview.canApply else { throw SetupError.changedSincePreview }
        let directory = settingsURL.deletingLastPathComponent()
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        let lock = URL(fileURLWithPath: settingsURL.path + ".lock")
        do {
            try files.createDirectory(at: lock, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        } catch { throw SetupError.busy }
        defer { try? files.removeItem(at: lock) }

        guard try readCurrent() == preview.original else { throw SetupError.changedSincePreview }
        let fresh = try self.preview()
        guard fresh.canApply, fresh.original == preview.original,
              fresh.proposed == preview.proposed else { throw SetupError.changedSincePreview }
        let oldMode = try preview.original.map { _ in
            (try files.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        } ?? 0o600
        var backup: URL?
        if let original = preview.original {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let candidate = directory.appendingPathComponent("settings.json.si-notch-backup-\(stamp)-\(UUID().uuidString)")
            try files.copyItem(at: settingsURL, to: candidate)
            backup = candidate
            guard try Data(contentsOf: candidate) == original,
                  try readCurrent() == original else { throw SetupError.changedSincePreview }
        }
        try atomicPrivateWrite(preview.proposed, mode: oldMode)
        return backup
    }

    private func atomicPrivateWrite(_ data: Data, mode: Int) throws {
        let temporary = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(".settings.json.si-notch-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw SetupError.writeFailed }
        defer { unlink(temporary.path) }
        defer { close(fd) }
        guard fchmod(fd, mode_t(mode)) == 0 else { throw SetupError.writeFailed }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written, fsync(fd) == 0,
              rename(temporary.path, settingsURL.path) == 0 else { throw SetupError.writeFailed }
    }

    private func readCurrent() throws -> Data? {
        let path = settingsURL.path
        if (try? files.destinationOfSymbolicLink(atPath: path)) != nil { throw SetupError.unsupportedFile }
        guard files.fileExists(atPath: path) else { return nil }
        guard Self.isRegularFile(path),
              let size = (try files.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue,
              size <= Self.maximumSettingsBytes else { throw SetupError.unsupportedFile }
        return try Data(contentsOf: settingsURL)
    }

    private static func isRegularFile(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return true
    }
}
