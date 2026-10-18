import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SoundSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("sound") private var sound = false
    @AppStorage("quiet") private var quiet = false
    @AppStorage("soundVolume") private var volume = 0.3
    @AppStorage("soundWorking") private var working = false
    @State private var previewResult: EventSoundPlayer.PlaybackResult? = nil
    @State private var importError: SoundLibrary.ImportError? = nil
    @State private var selectionRevision = 0

    var body: some View {
        let _ = appLanguage
        let _ = selectionRevision
        VStack(alignment: .leading, spacing: 18) {
            GroupBox(L10n.tr("sound.title")) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L10n.tr("sound.enabled"), isOn: $sound)
                    Text(L10n.tr("sound.description"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if quiet {
                        Label(L10n.tr("sound.quietNotice"), systemImage: "moon.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L10n.tr("sound.volume"))
                        Slider(value: $volume, in: 0...1, step: 0.05)
                            .accessibilityLabel(L10n.tr("sound.volume"))
                        Text("\(Int((volume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    .disabled(!sound || quiet)
                    Toggle(L10n.tr("sound.working"), isOn: $working)
                        .disabled(!sound || quiet)
                }
                .padding(10)
            }
            GroupBox(L10n.tr("sound.library")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("sound.library.description"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(EventSoundPlayer.Cue.allCases, id: \.self) { cue in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Toggle(label(for: cue), isOn: Binding(
                                    get: { UserDefaults.standard.object(forKey: cue.enabledPreference) as? Bool ?? true },
                                    set: { UserDefaults.standard.set($0, forKey: cue.enabledPreference); selectionRevision += 1 }))
                                    .toggleStyle(.switch).fixedSize().fontWeight(.medium)
                                Spacer()
                                Text(SoundLibrary.shared.selectedName(for: cue) ?? L10n.tr("sound.builtin"))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            HStack {
                                Button(L10n.tr("sound.import")) { chooseAudio(for: cue) }
                                if SoundLibrary.shared.hasCustomSound(for: cue) {
                                    Button(L10n.tr("sound.restore")) {
                                        SoundLibrary.shared.restoreBuiltIn(for: cue)
                                        selectionRevision += 1
                                        importError = nil
                                    }
                                }
                                Spacer()
                                Button(L10n.tr("sound.preview")) {
                                    previewResult = EventSoundPlayer.shared.preview(
                                        cue: cue, enabled: sound, quiet: quiet, volume: volume)
                                }
                            }
                        }
                        if cue != EventSoundPlayer.Cue.allCases.last { Divider() }
                    }
                    if let importError {
                        Label(importMessage(for: importError), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    if let previewResult {
                        Label(previewMessage(for: previewResult), systemImage: previewResult == .played ? "speaker.wave.2" : "speaker.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
        }
        .font(.system(size: 12))
    }

    private func label(for cue: EventSoundPlayer.Cue) -> String {
        switch cue {
        case .expand: return L10n.tr("sound.expand")
        case .collapse: return L10n.tr("sound.collapse")
        case .sessionStart: return L10n.tr("sound.sessionStart")
        case .working: return L10n.tr("sound.workingCue")
        case .completion: return L10n.tr("sound.completion")
        case .attention: return L10n.tr("sound.attention")
        case .failure: return L10n.tr("sound.failure")
        }
    }

    private func previewMessage(for result: EventSoundPlayer.PlaybackResult) -> String {
        switch result {
        case .played: return L10n.tr("sound.previewPlaying")
        case .muted: return L10n.tr("sound.previewMuted")
        case .rateLimited: return L10n.tr("sound.previewRateLimited")
        case .unavailable: return L10n.tr("sound.previewUnavailable")
        }
    }

    private func chooseAudio(for cue: EventSoundPlayer.Cue) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("sound.import.title")
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try SoundLibrary.shared.importAudio(from: url, for: cue)
                    selectionRevision += 1
                    importError = nil
                    previewResult = nil
                } catch let error as SoundLibrary.ImportError {
                    importError = error
                } catch {
                    importError = .storage
                }
            }
        }
    }

    private func importMessage(for error: SoundLibrary.ImportError) -> String {
        switch error {
        case .notRegular: return L10n.tr("sound.import.error.notRegular")
        case .tooLarge: return L10n.tr("sound.import.error.tooLarge")
        case .tooLong: return L10n.tr("sound.import.error.tooLong")
        case .invalidAudio: return L10n.tr("sound.import.error.invalidAudio")
        case .storage: return L10n.tr("sound.import.error.storage")
        }
    }
}
