import XCTest
import AppKit
import CryptoKit
@testable import SINotch

final class EventSoundTests: XCTestCase {
    @MainActor
    func testEveryCueIsAValidShortNonclippingWAV() throws {
        var distinct = Set<Data>()
        for cue in EventSoundPlayer.Cue.allCases {
            let wav = try XCTUnwrap(EventSoundPlayer.wavData(for: cue))
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
            XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
            XCTAssertEqual(Int(read32(wav, 4)) + 8, wav.count)
            XCTAssertEqual(Int(read32(wav, 40)) + 44, wav.count)
            XCTAssertEqual(read16(wav, 20), 1) // PCM
            XCTAssertEqual(read16(wav, 22), 1) // mono
            XCTAssertEqual(read32(wav, 24), 44_100)
            XCTAssertEqual(read16(wav, 34), 16)
            XCTAssertGreaterThan(wav.count, 44 + 2_000)
            XCTAssertLessThan(wav.count, 44 + Int(Double(44_100 * 2) * 0.4))
            XCTAssertNotNil(NSSound(data: wav), cue.rawValue)
            let samples = stride(from: 44, to: wav.count, by: 2).map {
                Int16(bitPattern: read16(wav, $0))
            }
            XCTAssertTrue(samples.contains { $0 != 0 })
            XCTAssertLessThan(samples.map { abs(Int($0)) }.max() ?? 0, 24_000)
            distinct.insert(wav)
        }
        XCTAssertEqual(distinct.count, EventSoundPlayer.Cue.allCases.count)
    }

    @MainActor
    func testBundledCuesHaveQuietEndpointsAndHeadroom() throws {
        for cue in EventSoundPlayer.Cue.allCases {
            let wav = try XCTUnwrap(EventSoundPlayer.wavData(for: cue))
            let samples = stride(from: 44, to: wav.count, by: 2).map { Double(Int16(bitPattern: read16(wav, $0))) / 32767 }
            let peak = samples.map(abs).max() ?? 0
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
            XCTAssertLessThanOrEqual(peak, 0.252, cue.rawValue)
            XCTAssertGreaterThan(rms, 0.02, cue.rawValue)
            XCTAssertLessThan(rms, 0.15, cue.rawValue)
            XCTAssertLessThan(Double(samples.count) / Double(read32(wav, 24)), 0.4)
        }
    }

    @MainActor
    func testBuiltInCuesMatchApprovedRecordings() throws {
        let approved: [EventSoundPlayer.Cue: String] = [
            .expand: "2416a078db26e72d031681cf831abbcb05cc7a9305498583f2c6e9b22c73e7d5",
            .collapse: "6879fab4d5dc16d9b4ebe5bc49de3fee8dd7ab8f06b6b2784e52584d2c1c2d8c",
            .sessionStart: "0cb3b2468daac058e0150f8652048fd2d5772ca1b7ffb3a95950d7c1c093a96e",
            .working: "eadd9832f8749f2fbb64e7ae9cd0147f20866c5149d850617bdc5614bd11c40f",
            .completion: "fa2d0439d2cc543ed167e0e9f0b79576c1169620ad307d8c2422f7d944cf4452",
            .attention: "6824ee02f0380f0d814580688a886da9fc17bf84adcbbfde01f3d5b83d0b2842",
            .failure: "5779dfc00632206939c7c526b44de5bc0667b57181621c22e13e3f1fce0f5928"
        ]
        XCTAssertEqual(approved.count, EventSoundPlayer.Cue.allCases.count)
        for cue in EventSoundPlayer.Cue.allCases {
            let wav = try XCTUnwrap(EventSoundPlayer.wavData(for: cue))
            let digest = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, approved[cue], cue.rawValue)
        }
    }

    @MainActor
    func testBuiltInPlaybackUsesRecordingAndRequestedVolume() throws {
        let suite = "si-notch.sound-playback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var delivered: Data?
        var level: Float?
        let player = EventSoundPlayer(defaults: defaults, output: { data, volume in
            delivered = data
            level = volume
            return true
        })
        XCTAssertTrue(player.play(cue: .sessionStart, sessionID: "fixture", enabled: true,
                                  quiet: false, volume: 0.35))
        XCTAssertEqual(delivered, try XCTUnwrap(EventSoundPlayer.wavData(for: .sessionStart)))
        XCTAssertEqual(level, 0.35)
    }

    @MainActor
    func testImportedSoundOverridesBuiltInAndRestoreReturnsToDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "si-notch.sound-override.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SoundLibrary(defaults: defaults, directory: root.appendingPathComponent("stored"))
        let chosen = try XCTUnwrap(EventSoundPlayer.wavData(for: .completion))
        let source = root.appendingPathComponent("custom.wav")
        try chosen.write(to: source)
        try library.importAudio(from: source, for: .attention)
        var delivered: [Data] = []
        let player = EventSoundPlayer(defaults: defaults, library: library, output: { data, _ in
            delivered.append(data)
            return true
        })
        XCTAssertEqual(player.preview(cue: .attention, enabled: true, quiet: false, volume: 0.3), .played)
        XCTAssertEqual(delivered, [chosen])
        library.restoreBuiltIn(for: .attention)
        XCTAssertTrue(player.play(cue: .attention, sessionID: "fixture", enabled: true,
                                  quiet: false, volume: 0.3))
        XCTAssertEqual(delivered.last, try XCTUnwrap(EventSoundPlayer.wavData(for: .attention)))
        XCTAssertEqual(try Data(contentsOf: source), chosen)
    }

    @MainActor
    func testLimiterRejectsRepeatedAndBurstEventsThenRecovers() {
        var limiter = SoundBurstLimiter()
        XCTAssertTrue(limiter.admit(cue: .attention, sessionID: "one", now: 10))
        XCTAssertFalse(limiter.admit(cue: .attention, sessionID: "one", now: 10.1))
        XCTAssertTrue(limiter.admit(cue: .completion, sessionID: "one", now: 10.2))
        XCTAssertTrue(limiter.admit(cue: .failure, sessionID: "two", now: 10.3))
        XCTAssertTrue(limiter.admit(cue: .sessionStart, sessionID: "three", now: 10.4))
        XCTAssertTrue(limiter.admit(cue: .sessionStart, sessionID: "three", now: 15))
        XCTAssertFalse(limiter.admit(cue: .working, sessionID: "four", now: .infinity))
    }

    @MainActor
    func testRevealCuesAreVeryShortAndSeparateFromAgentBurstLimit() throws {
        for cue in [EventSoundPlayer.Cue.expand, .collapse] {
            let wav = try XCTUnwrap(EventSoundPlayer.wavData(for: cue))
            XCTAssertLessThan(Double(read32(wav, 40)) / Double(read32(wav, 24) * 2), 0.06)
        }
        var limiter = SoundBurstLimiter()
        XCTAssertTrue(limiter.admit(cue: .sessionStart, sessionID: "a", now: 10))
        XCTAssertTrue(limiter.admit(cue: .completion, sessionID: "b", now: 10.01))
        XCTAssertTrue(limiter.admit(cue: .attention, sessionID: "c", now: 10.02))
        XCTAssertTrue(limiter.admitInterface(now: 10.03))
        XCTAssertFalse(limiter.admitInterface(now: 10.20))
        XCTAssertTrue(limiter.admitInterface(now: 10.26))
        XCTAssertTrue(limiter.admit(cue: .failure, sessionID: "d", now: 10.27))
    }

    @MainActor
    func testMutedAndDisabledCuesNeverPlay() {
        let player = EventSoundPlayer()
        XCTAssertFalse(player.play(cue: .attention, sessionID: "one", enabled: false,
                                   quiet: false, volume: 0.3))
        XCTAssertFalse(player.play(cue: .attention, sessionID: "one", enabled: true,
                                   quiet: true, volume: 0.3))
        XCTAssertFalse(player.play(cue: .attention, sessionID: "one", enabled: true,
                                   quiet: false, volume: 0))
        XCTAssertFalse(player.play(cue: .working, sessionID: "one", enabled: true,
                                   quiet: false, volume: 0.3))
    }

    @MainActor
    func testDisabledIndividualCueStaysSilentWhenMasterIsEnabled() {
        let suite = "si-notch.sound-cue.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = EventSoundPlayer(defaults: defaults)
        for cue in EventSoundPlayer.Cue.allCases {
            defaults.set(false, forKey: cue.enabledPreference)
            XCTAssertFalse(player.play(cue: cue, sessionID: "fixture", enabled: true,
                                       quiet: false, volume: 0.3, workingEnabled: true))
        }
    }

    @MainActor
    func testSelectedAudioIsCopiedPersistedAndRestoredPerCue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("my-completion.wav")
        let wav = try XCTUnwrap(EventSoundPlayer.wavData(for: .completion))
        try wav.write(to: original)
        let suite = "si-notch.sound-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SoundLibrary(defaults: defaults, directory: root.appendingPathComponent("stored"))

        XCTAssertEqual(try library.importAudio(from: original, for: .attention), "my-completion.wav")
        XCTAssertTrue(library.hasCustomSound(for: .attention))
        XCTAssertFalse(library.hasCustomSound(for: .completion))
        XCTAssertEqual(library.customData(for: .attention), wav)
        let reloaded = SoundLibrary(defaults: defaults, directory: root.appendingPathComponent("stored"))
        XCTAssertEqual(reloaded.selectedName(for: .attention), "my-completion.wav")
        XCTAssertEqual(reloaded.customData(for: .attention), wav)
        reloaded.restoreBuiltIn(for: .attention)
        XCTAssertFalse(reloaded.hasCustomSound(for: .attention))
        XCTAssertNil(reloaded.customData(for: .attention))
        XCTAssertEqual(try Data(contentsOf: original), wav) // Never modifies the chosen source.
    }

    @MainActor
    func testImportRejectsSymlinkOversizeAndInvalidAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "si-notch.sound-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SoundLibrary(defaults: defaults, directory: root.appendingPathComponent("stored"))

        let audio = root.appendingPathComponent("short.wav")
        try XCTUnwrap(EventSoundPlayer.wavData(for: .attention)).write(to: audio)
        let link = root.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
        XCTAssertThrowsError(try library.importAudio(from: link, for: .attention)) {
            XCTAssertEqual($0 as? SoundLibrary.ImportError, .notRegular)
        }

        let large = root.appendingPathComponent("large.wav")
        try Data(repeating: 0, count: SoundLibrary.maxBytes + 1).write(to: large)
        XCTAssertThrowsError(try library.importAudio(from: large, for: .attention)) {
            XCTAssertEqual($0 as? SoundLibrary.ImportError, .tooLarge)
        }

        let invalid = root.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: invalid)
        XCTAssertThrowsError(try library.importAudio(from: invalid, for: .attention)) {
            XCTAssertEqual($0 as? SoundLibrary.ImportError, .invalidAudio)
        }
        XCTAssertFalse(library.hasCustomSound(for: .attention))
    }

    @MainActor
    func testImportRejectsAudioLongerThanTenSeconds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "si-notch.sound-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SoundLibrary(defaults: defaults, directory: root.appendingPathComponent("stored"))

        var wav = try XCTUnwrap(EventSoundPlayer.wavData(for: .working))
        let samples = 11 * Int(read32(wav, 24))
        wav = Data(wav.prefix(44)) + Data(repeating: 0, count: samples * 2)
        let riffSize = UInt32(wav.count - 8)
        set32(&wav, 4, riffSize)
        set32(&wav, 40, UInt32(samples * 2))
        let long = root.appendingPathComponent("long.wav")
        try wav.write(to: long)
        XCTAssertThrowsError(try library.importAudio(from: long, for: .completion)) {
            XCTAssertEqual($0 as? SoundLibrary.ImportError, .tooLong)
        }
    }

    private func read16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(read16(data, offset)) | UInt32(read16(data, offset + 2)) << 16
    }

    private func set32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }
}
