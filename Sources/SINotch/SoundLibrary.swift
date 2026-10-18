import AppKit
import AVFoundation
import Foundation

/// Stores only audio explicitly chosen by the user, as private copies in Application Support.
@MainActor
final class SoundLibrary {
    enum ImportError: Error, Equatable {
        case notRegular, tooLarge, tooLong, invalidAudio, storage
    }

    static let shared = SoundLibrary()
    static let maxBytes = 10 * 1024 * 1024
    static let maxDuration = 10.0

    private let defaults: UserDefaults
    private let directory: URL

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
        self.directory = directory ?? support.appendingPathComponent("si-notch/Sounds", isDirectory: true)
    }

    func hasCustomSound(for cue: EventSoundPlayer.Cue) -> Bool {
        storedFilename(for: cue) != nil
    }

    func selectedName(for cue: EventSoundPlayer.Cue) -> String? {
        guard hasCustomSound(for: cue) else { return nil }
        return defaults.string(forKey: nameKey(for: cue))
    }

    func customData(for cue: EventSoundPlayer.Cue) -> Data? {
        guard let filename = storedFilename(for: cue) else { return nil }
        let file = directory.appendingPathComponent(filename, isDirectory: false)
        guard (try? Self.validateRegularSize(file)) != nil,
              (try? Self.validateDuration(file)) != nil else { return nil }
        return try? Data(contentsOf: file)
    }

    /// The open panel grants access to this source; no directories or external paths are saved.
    @discardableResult
    func importAudio(from source: URL, for cue: EventSoundPlayer.Cue) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }

        try Self.validateRegularSize(source)
        try Self.validateDuration(source)
        let ext = source.pathExtension.lowercased()
        guard (1...8).contains(ext.count), ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw ImportError.invalidAudio
        }
        let filename = UUID().uuidString.lowercased() + "." + ext
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.storage
        }
        do {
            try Self.validateRegularSize(destination)
            try Self.validateDuration(destination)
            guard let copiedData = try? Data(contentsOf: destination), NSSound(data: copiedData) != nil else {
                throw ImportError.invalidAudio
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        let oldFilename = storedFilename(for: cue)
        defaults.set(filename, forKey: fileKey(for: cue))
        defaults.set(source.lastPathComponent, forKey: nameKey(for: cue))
        if let oldFilename, oldFilename != filename {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldFilename))
        }
        return source.lastPathComponent
    }

    func restoreBuiltIn(for cue: EventSoundPlayer.Cue) {
        let oldFilename = storedFilename(for: cue)
        defaults.removeObject(forKey: fileKey(for: cue))
        defaults.removeObject(forKey: nameKey(for: cue))
        if let oldFilename {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldFilename))
        }
    }

    private func storedFilename(for cue: EventSoundPlayer.Cue) -> String? {
        guard let filename = defaults.string(forKey: fileKey(for: cue)) else { return nil }
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              (1...8).contains(parts[1].count),
              parts[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return filename
    }

    private func fileKey(for cue: EventSoundPlayer.Cue) -> String { "soundCustom.file.\(cue.rawValue)" }
    private func nameKey(for cue: EventSoundPlayer.Cue) -> String { "soundCustom.name.\(cue.rawValue)" }

    private static func validateRegularSize(_ url: URL) throws {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) }
        catch { throw ImportError.notRegular }
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              let bytes = values.fileSize, bytes > 0 else { throw ImportError.notRegular }
        guard bytes <= maxBytes else { throw ImportError.tooLarge }
    }

    private static func validateDuration(_ url: URL) throws {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw ImportError.invalidAudio }
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate
        guard sampleRate.isFinite, sampleRate > 0, duration.isFinite, duration > 0 else {
            throw ImportError.invalidAudio
        }
        guard duration <= maxDuration else { throw ImportError.tooLong }
    }
}
