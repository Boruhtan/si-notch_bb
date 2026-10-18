import Foundation

/// A narrow editor for the user-level Codex notify setting. It never parses or rewrites
/// unrelated TOML, and it declines to edit configurations that already mention notify.
struct CodexConfigSetup {
    struct Preview {
        let configURL: URL
        let proposedLine: String
        let existingNotify: Bool
        let canApply: Bool
        let explanation: String
        fileprivate let original: Data?
    }

    enum SetupError: LocalizedError {
        case invalidHelper
        case unsupportedFile
        case changedSincePreview
        case existingNotify

        var errorDescription: String? {
            switch self {
            case .invalidHelper: return L10n.tr("Не найден исполняемый si-notchctl по указанному пути.")
            case .unsupportedFile: return L10n.tr("config.toml должен быть обычным файлом, а не ссылкой или каталогом.")
            case .changedSincePreview: return L10n.tr("config.toml изменился после предпросмотра. Обновите предпросмотр перед применением.")
            case .existingNotify: return L10n.tr("В config.toml уже есть notify. Автоматическая настройка остановлена, чтобы сохранить действующий вызов.")
            }
        }
    }

    let configURL: URL
    let helperPath: String
    private let files = FileManager.default

    init(helperPath: String, configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")) {
        self.helperPath = helperPath
        self.configURL = configURL
    }

    func preview() throws -> Preview {
        guard helperPath.hasPrefix("/"), files.isExecutableFile(atPath: helperPath),
              !helperPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SetupError.invalidHelper
        }
        let original = try readCurrent()
        if let original {
            guard String(data: original, encoding: .utf8) != nil,
                  !original.starts(with: [0xEF, 0xBB, 0xBF]) else { throw SetupError.unsupportedFile }
        }
        let command = try JSONSerialization.data(withJSONObject: [helperPath, "notify"], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        let line = "notify = " + (String(data: command, encoding: .utf8) ?? "[]")
        let existingNotify = original.flatMap { String(data: $0, encoding: .utf8) }.map(Self.containsNotify) ?? false
        return Preview(
            configURL: configURL,
            proposedLine: line,
            existingNotify: existingNotify,
            canApply: !existingNotify,
            explanation: existingNotify
                ? L10n.tr("Уже настроен notify. Codex поддерживает один массив команды: сохраните текущий вызов и вручную объедините оба получателя через свой wrapper. Приложение не заменит его.")
                : L10n.tr("Будет добавлена только показанная строка в начало пользовательского config.toml. Перед записью существующего файла создаётся резервная копия с датой."),
            original: original
        )
    }

    /// Applies only the exact bytes shown by preview. Returns the backup path, if one was made.
    func apply(_ preview: Preview) throws -> URL? {
        guard preview.configURL == configURL else { throw SetupError.changedSincePreview }
        guard !preview.existingNotify else { throw SetupError.existingNotify }
        guard files.isExecutableFile(atPath: helperPath) else { throw SetupError.invalidHelper }
        guard try readCurrent() == preview.original else { throw SetupError.changedSincePreview }
        let directory = configURL.deletingLastPathComponent()
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let oldMode = try preview.original.map { _ in
            (try files.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        }
        var backupURL: URL?
        if preview.original != nil {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let candidate = directory.appendingPathComponent("config.toml.si-notch-backup-\(stamp)-\(UUID().uuidString)")
            try files.copyItem(at: configURL, to: candidate)
            backupURL = candidate
            guard try Data(contentsOf: candidate) == preview.original,
                  try readCurrent() == preview.original else { throw SetupError.changedSincePreview }
        }
        var next = Data((preview.proposedLine + "\n").utf8)
        if let original = preview.original { next.append(original) }
        do {
            try next.write(to: configURL, options: .atomic)
            try files.setAttributes([.posixPermissions: oldMode ?? 0o600], ofItemAtPath: configURL.path)
        } catch {
            // The timestamped backup remains available if a late write or chmod fails.
            throw error
        }
        return backupURL
    }

    private func readCurrent() throws -> Data? {
        let path = configURL.path
        guard files.fileExists(atPath: path) || (try? files.destinationOfSymbolicLink(atPath: path)) != nil else { return nil }
        let attributes = try files.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw SetupError.unsupportedFile }
        return try Data(contentsOf: configURL)
    }

    private static func containsNotify(_ content: String) -> Bool {
        // Conservative: even a notify key in a table blocks automatic editing. This
        // may decline a harmless config, but can never overwrite an active command.
        let pattern = #"(?m)^[ \t]*(?:notify|"notify"|'notify')[ \t]*="#
        if content.range(of: pattern, options: .regularExpression) != nil { return true }
        // A quoted key can spell notify with Unicode escapes. Decline ambiguous
        // escaped assignments instead of adding a duplicate decoded TOML key.
        let escapedKey = #"(?m)^[ \t]*"[^"\n]*\\[^\n]*"[ \t]*="#
        return content.range(of: escapedKey, options: .regularExpression) != nil
    }
}
