import XCTest
@testable import SINotch

final class EventSoundTests: XCTestCase {
    @MainActor
    func testEveryCueIsAValidShortNonclippingWAV() {
        var distinct = Set<Data>()
        for cue in EventSoundPlayer.Cue.allCases {
            let wav = EventSoundPlayer.wavData(for: cue)
            XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
            XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
            XCTAssertEqual(Int(read32(wav, 4)) + 8, wav.count)
            XCTAssertEqual(Int(read32(wav, 40)) + 44, wav.count)
            XCTAssertEqual(read16(wav, 20), 1) // PCM
            XCTAssertEqual(read16(wav, 22), 1) // mono
            XCTAssertEqual(read32(wav, 24), 22_050)
            XCTAssertEqual(read16(wav, 34), 16)
            XCTAssertGreaterThan(wav.count, 44 + 2_000)
            XCTAssertLessThan(wav.count, 44 + Int(Double(22_050 * 2) * 0.7))
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
    func testChipCuesHaveQuietEndpointsHeadroomAndNoDCOffset() {
        for cue in EventSoundPlayer.Cue.allCases {
            let wav = EventSoundPlayer.wavData(for: cue)
            let samples = stride(from: 44, to: wav.count, by: 2).map { Double(Int16(bitPattern: read16(wav, $0))) / 32767 }
            let peak = samples.map(abs).max() ?? 0
            let mean = samples.reduce(0, +) / Double(samples.count)
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
            XCTAssertEqual(samples.first, 0)
            XCTAssertTrue(samples.suffix(220).allSatisfy { $0 == 0 })
            XCTAssertLessThan(abs(mean), 0.002, cue.rawValue)
            XCTAssertLessThanOrEqual(peak, 0.241, cue.rawValue)
            XCTAssertGreaterThan(rms, 0.02, cue.rawValue)
            XCTAssertLessThan(rms, 0.15, cue.rawValue)
            XCTAssertLessThan(Double(samples.count) / 22050, 0.26)
            let biggestStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            XCTAssertLessThan(biggestStep, 0.12, cue.rawValue)
        }
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
    func testRevealCuesAreVeryShortAndSeparateFromAgentBurstLimit() {
        for cue in [EventSoundPlayer.Cue.expand, .collapse] {
            let wav = EventSoundPlayer.wavData(for: cue)
            XCTAssertLessThan(Double(read32(wav, 40)) / Double(22_050 * 2), 0.15)
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
        let wav = EventSoundPlayer.wavData(for: .completion)
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
        try EventSoundPlayer.wavData(for: .attention).write(to: audio)
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

        let samples = 11 * 22_050
        var wav = EventSoundPlayer.wavData(for: .working)
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
