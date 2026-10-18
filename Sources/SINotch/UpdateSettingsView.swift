import AppKit
import SwiftUI

struct UpdateSettingsView: View {
    @AppStorage("updateChannel") private var savedChannel = UpdateChannel.stable.rawValue
    @AppStorage("updateBackgroundChecks") private var backgroundChecks = true
    @AppStorage("updateAvailableVersion") private var backgroundAvailableVersion = ""
    @State private var result: UpdateCheckResult?
    @State private var error: String?
    @State private var checking = false
    @State private var downloading = false
    @State private var installing = false
    @State private var verifiedArchive: URL?
    @State private var generation = 0
    @State private var checkTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?

    private let service = UpdateService()
    private var channel: UpdateChannel { UpdateChannel(rawValue: savedChannel) ?? .stable }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "SIReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {
        GroupBox(L10n.tr("updates.title")) {
            VStack(alignment: .leading, spacing: 11) {
                Picker(L10n.tr("updates.channel"), selection: $savedChannel) {
                    Text(L10n.tr("updates.stable")).tag(UpdateChannel.stable.rawValue)
                    Text(L10n.tr("updates.beta")).tag(UpdateChannel.beta.rawValue)
                }
                .pickerStyle(.segmented)
                .disabled(installing)
                .onChange(of: savedChannel) { _, _ in
                    generation += 1
                    checkTask?.cancel(); downloadTask?.cancel()
                    checking = false; downloading = false
                    discardVerifiedArchive()
                    result = nil; error = nil; backgroundAvailableVersion = ""
                }
                Toggle(L10n.tr("updates.background"), isOn: $backgroundChecks)
                Text(L10n.tr("updates.backgroundHelp"))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondary)

                HStack {
                    Button(L10n.tr("updates.check")) { startCheck() }
                        .disabled(checking || installing || service.configuration == nil)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if service.configuration == nil {
                    Label(L10n.tr("updates.unconfigured"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if result == nil && !backgroundAvailableVersion.isEmpty {
                    Label("\(L10n.tr("updates.available")) \(backgroundAvailableVersion)", systemImage: "arrow.down.circle")
                } else if let result {
                    switch result {
                    case .unconfigured:
                        Label(L10n.tr("updates.unconfigured"), systemImage: "exclamationmark.triangle")
                    case .upToDate:
                        Label(L10n.tr("updates.upToDate"), systemImage: "checkmark.circle")
                    case .available(let release):
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(L10n.tr("updates.available")) \(release.version)", systemImage: "arrow.down.circle")
                            if !release.notes.isEmpty {
                                Text(L10n.tr("updates.releaseNotes"))
                                    .fontWeight(.semibold)
                                Text(release.notes)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let verifiedArchive {
                                Label(L10n.tr("updates.verified"), systemImage: "checkmark.shield")
                                Button(L10n.tr("updates.install")) {
                                    installing = true
                                    do { try UpdateInstaller.start(archive: verifiedArchive, release: release) }
                                    catch { installing = false; self.error = error.localizedDescription }
                                }
                                Button(L10n.tr("updates.openArchive")) { NSWorkspace.shared.activateFileViewerSelecting([verifiedArchive]) }
                            } else {
                                Button(L10n.tr("updates.download")) {
                                    startDownload(release)
                                }
                                .disabled(downloading)
                                if downloading { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12))
            .padding(10)
        }
        .task {
            if service.configuration != nil { startCheck() }
        }
        .onDisappear {
            generation += 1
            checkTask?.cancel(); downloadTask?.cancel()
            discardVerifiedArchive()
        }
    }

    private func discardVerifiedArchive() {
        guard !installing, let archive = verifiedArchive else { return }
        verifiedArchive = nil
        try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
    }

    @MainActor private func startCheck() {
        generation += 1
        checkTask?.cancel(); downloadTask?.cancel()
        discardVerifiedArchive()
        result = nil
        checking = true; downloading = false
        let token = generation
        let requestedChannel = channel
        checkTask = Task { await check(token: token, channel: requestedChannel) }
    }

    @MainActor private func check(token: Int, channel: UpdateChannel) async {
        checking = true; error = nil
        defer { if generation == token { checking = false } }
        do {
            let checked = try await service.check(currentVersion: version, channel: channel)
            guard generation == token, !Task.isCancelled, self.channel == channel else { return }
            result = checked
            if case .available(let release) = checked { backgroundAvailableVersion = release.version }
            else { backgroundAvailableVersion = "" }
        }
        catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = "\(L10n.tr("updates.checkFailed")) \(error.localizedDescription)"
        }
    }

    @MainActor private func startDownload(_ release: UpdateRelease) {
        generation += 1
        downloadTask?.cancel()
        downloading = true
        let token = generation
        downloadTask = Task { await download(release, token: token) }
    }

    @MainActor private func download(_ release: UpdateRelease, token: Int) async {
        downloading = true; error = nil
        defer { if generation == token { downloading = false } }
        do {
            let archive = try await service.downloadVerified(release)
            guard generation == token, !Task.isCancelled, result == .available(release) else {
                try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
                return
            }
            verifiedArchive = archive
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = "\(L10n.tr("updates.downloadFailed")) \(error.localizedDescription)"
        }
    }
}
