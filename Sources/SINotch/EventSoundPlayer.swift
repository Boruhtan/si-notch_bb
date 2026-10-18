import AppKit
import Foundation

/// Built-in cues are synthesized here; user-selected audio can override each cue.
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

    init(defaults: UserDefaults = .standard, output: ((Data, Float) -> Bool)? = nil) {
        self.defaults = defaults
        self.output = output
        self.library = SoundLibrary(defaults: defaults)
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
            audio = Self.wavData(for: cue)
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

    struct Note {
        let start: Double
        let duration: Double
        let frequency: Double
        let gain: Double
        var endFrequency: Double? = nil
    }

    private static func notes(for cue: Cue) -> [Note] {
        switch cue {
        case .expand:
            return [Note(start: 0, duration: 0.098, frequency: 440.00, gain: 1, endFrequency: 587.33)]
        case .collapse:
            return [Note(start: 0, duration: 0.085, frequency: 523.25, gain: 1, endFrequency: 392.00)]
        case .sessionStart:
            return [Note(start: 0, duration: 0.075, frequency: 392.00, gain: 0.8),
                    Note(start: 0.060, duration: 0.075, frequency: 523.25, gain: 0.9),
                    Note(start: 0.120, duration: 0.100, frequency: 659.25, gain: 1)]
        case .working:
            return [Note(start: 0, duration: 0.065, frequency: 392.00, gain: 1)]
        case .completion:
            return [Note(start: 0, duration: 0.075, frequency: 523.25, gain: 0.9),
                    Note(start: 0.060, duration: 0.075, frequency: 659.25, gain: 0.95),
                    Note(start: 0.120, duration: 0.120, frequency: 880.00, gain: 1)]
        case .attention:
            return [Note(start: 0, duration: 0.075, frequency: 523.25, gain: 0.9),
                    Note(start: 0.115, duration: 0.090, frequency: 659.25, gain: 0.85)]
        case .failure:
            return [Note(start: 0, duration: 0.085, frequency: 392.00, gain: 0.9),
                    Note(start: 0.065, duration: 0.110, frequency: 329.63, gain: 0.85)]
        }
    }

    private static func peakLevel(for cue: Cue) -> Double {
        switch cue {
        case .expand: return 0.18
        case .collapse: return 0.15
        case .working: return 0.11
        case .sessionStart: return 0.22
        case .completion: return 0.24
        case .attention: return 0.22
        case .failure: return 0.20
        }
    }

    /// Four odd harmonics give a pulse/triangle chiptune voice without the
    /// aliasing and sharp edges of a raw square wave or bit-crushed PCM.
    private static func chipVoice(phase: Double) -> Double {
        let fundamental = sin(phase)
        let third = sin(3 * phase), fifth = sin(5 * phase), seventh = sin(7 * phase)
        let pulse = fundamental + 0.18 * third + 0.06 * fifth + 0.015 * seventh
        let triangle = fundamental - third / 9 + fifth / 25 - seventh / 49
        return 0.28 * pulse + 0.72 * triangle
    }

    /// 22.05 kHz, mono, signed 16-bit PCM in a standard RIFF/WAVE container.
    static func wavData(for cue: Cue) -> Data {
        let rate = 22_050
        let notes = notes(for: cue)
        let duration = (notes.map { $0.start + $0.duration }.max() ?? 0) + 0.012
        let count = Int(ceil(duration * Double(rate)))
        let dataSize = count * 2
        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(rate))
        data.appendLittleEndian(UInt32(rate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataSize))

        var samples = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            for note in notes {
                let local = time - note.start
                guard local >= 0, local < note.duration else { continue }
                // Soft plucks and a small pitch glide keep interface cues unobtrusive.
                let attack = sin(min(1, local / 0.006) * .pi / 2)
                let releaseTime = min(0.045, note.duration * 0.6)
                let release = sin(min(1, (note.duration - local) / releaseTime) * .pi / 2)
                let decay = exp(-1.6 * local / note.duration)
                let glide = (note.endFrequency ?? note.frequency) - note.frequency
                let phase = 2 * Double.pi * (note.frequency * local + glide * local * local / (2 * note.duration))
                samples[index] += note.gain * attack * attack * release * release * decay * chipVoice(phase: phase)
            }
        }
        // A gentle low-pass keeps the upper pulse harmonics from becoming brittle.
        let alpha = 1 - exp(-2 * Double.pi * 2200 / Double(rate))
        var filtered = 0.0
        for index in samples.indices {
            filtered += alpha * (samples[index] - filtered)
            samples[index] = filtered
        }
        // Calibrate cue levels after note overlaps; quiet ticks stay quieter
        // than completion and attention, with headroom at maximum app volume.
        let peak = samples.reduce(0) { max($0, abs($1)) }
        let gain = peak > 0 ? peakLevel(for: cue) / peak : 0
        for sample in samples {
            data.appendLittleEndian(Int16((sample * gain * 32_767).rounded()))
        }
        return data
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

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }
}
