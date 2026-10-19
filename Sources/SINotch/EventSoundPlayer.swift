import AppKit
import Foundation

/// Bundled event recordings can be overridden by user-selected audio.
@MainActor
final class EventSoundPlayer {
    enum Cue: String, CaseIterable, Hashable {
        case expand, collapse, sessionStart, working, completion, attention, failure
        var enabledPreference: String { "soundCue.\(rawValue)" }
    }
    enum PlaybackResult {
        case played, muted, rateLimited, unavailable
    }

    static let shared = EventSoundPlayer()

    private var limiter = SoundBurstLimiter()
    private var activeSounds: [NSSound] = []
    private let defaults: UserDefaults
    private let output: ((Data, Float) -> Bool)?
    private let library: SoundLibrary

    init(defaults: UserDefaults = .standard, library: SoundLibrary? = nil,
         output: ((Data, Float) -> Bool)? = nil) {
        self.defaults = defaults
        self.output = output
        self.library = library ?? SoundLibrary(defaults: defaults)
    }

    @discardableResult
    func play(
        cue: Cue,
        sessionID: String,
        enabled: Bool,
        quiet: Bool,
        volume: Double,
        workingEnabled: Bool = false,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        attempt(cue: cue, sessionID: sessionID, enabled: enabled, quiet: quiet,
                volume: volume, workingEnabled: workingEnabled, now: now) == .played
    }

    private func attempt(
        cue: Cue, sessionID: String, enabled: Bool, quiet: Bool,
        volume: Double, workingEnabled: Bool, now: TimeInterval, preview: Bool = false
    ) -> PlaybackResult {
        guard enabled, !quiet, defaults.object(forKey: cue.enabledPreference) as? Bool != false,
              volume.isFinite, volume > 0,
              cue != .working || workingEnabled else { return .muted }
        let admitted: Bool
        switch cue {
        case .expand, .collapse:
            admitted = limiter.admitInterface(now: now)
        default:
            // Live events have already been deduplicated by session/turn. A
            // time budget here would discard distinct turns or permission requests.
            admitted = !preview || limiter.admit(cue: cue, sessionID: sessionID, now: now)
        }
        guard admitted else { return .rateLimited }
        let audio: Data
        if library.hasCustomSound(for: cue) {
            guard let imported = library.customData(for: cue) else { return .unavailable }
            audio = imported
        } else {
            guard let bundled = Self.wavData(for: cue) else { return .unavailable }
            audio = bundled
        }
        let level = Float(min(max(volume, 0), 1))
        if let output { return output(audio, level) ? .played : .unavailable }
        guard let sound = NSSound(data: audio) else { return .unavailable }
        sound.volume = level
        activeSounds.removeAll { !$0.isPlaying }
        // NSSound must stay alive until asynchronous playback finishes.
        activeSounds.append(sound)
        return sound.play() ? .played : .unavailable
    }

    @discardableResult
    func preview(cue: Cue, enabled: Bool, quiet: Bool, volume: Double) -> PlaybackResult {
        attempt(cue: cue, sessionID: "__sound-preview__", enabled: enabled,
                quiet: quiet, volume: volume, workingEnabled: true,
                now: ProcessInfo.processInfo.systemUptime, preview: true)
    }

    /// Load once from the relocated app bundle or the SwiftPM test/build bundle.
    private static let builtInWAVs: [Cue: Data] = {
        let resources = Bundle.main.url(forResource: "si-notch_SINotch", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        return Dictionary(uniqueKeysWithValues: Cue.allCases.compactMap { cue -> (Cue, Data)? in
            guard let url = resources.url(forResource: "event-\(cue.rawValue)", withExtension: "wav"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (cue, data)
        })
    }()

    /// The exact approved 44.1 kHz mono PCM recordings, including their cue levels.
    static func wavData(for cue: Cue) -> Data? {
        builtInWAVs[cue]
    }
}

/// Protects one session from immediate repeats without muting other sessions.
struct SoundBurstLimiter {
    private struct Key: Hashable {
        let cue: EventSoundPlayer.Cue
        let sessionID: String
    }
    private var lastByKey: [Key: TimeInterval] = [:]
    private var lastInterfaceAt: TimeInterval?

    /// Rate-limit interface feedback independently of session lifecycle events.
    mutating func admitInterface(now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        guard lastInterfaceAt.map({ $0 > now || now - $0 >= 0.22 }) ?? true else { return false }
        lastInterfaceAt = now
        return true
    }

    mutating func admit(cue: EventSoundPlayer.Cue, sessionID: String, now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        // Monotonic time may restart between app launches, but the limiter is process-local.
        lastByKey = lastByKey.filter { $0.value <= now && now - $0.value < 5 }
        let key = Key(cue: cue, sessionID: sessionID)
        guard lastByKey[key].map({ now - $0 >= 2 }) ?? true else { return false }
        lastByKey[key] = now
        return true
    }
}
