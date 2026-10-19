import AppKit
import SwiftUI

/// Embed before the legacy notify setup in the Codex integration settings.
struct CodexHookSetupView: View {
    let cliPath: String
    @State private var preview: CodexHookSetup.Preview?
    @State private var error: String?
    @State private var backup: String?
    @State private var trustStatus: CodexHookTrustStatus?
    @State private var checkingTrust = false
    @State private var checkGeneration = 0
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private var adapterPath: String {
        URL(fileURLWithPath: cliPath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/adapters/codex-hook.py").path
    }

    private var setup: CodexHookSetup { CodexHookSetup(adapterPath: adapterPath, helperPath: cliPath) }

    var body: some View {
        let _ = appLanguage
        GroupBox(L10n.tr("codex.hooks.title")) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.tr("codex.hooks.description"))
                    .foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview {
                    if preview.canApply {
                        DisclosureGroup(L10n.tr("codex.hooks.preview")) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(L10n.tr("codex.hooks.addEvents") + ": " + preview.addedEvents.joined(separator: ", "))
                                    .foregroundStyle(SettingsPalette.secondary)
                                ScrollView {
                                    Text(preview.proposedJSON)
                                        .font(.system(size: 10, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 160)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        if trustStatus != .trusted {
                            Button(L10n.tr("codex.hooks.apply")) { connect() }
                                .buttonStyle(NotchActionButtonStyle(prominent: true))
                                .disabled(checkingTrust)
                        } else {
                            Button(L10n.tr("codex.hooks.checkTrust")) { checkTrust() }
                                .buttonStyle(NotchActionButtonStyle())
                                .disabled(checkingTrust)
                        }
                        if checkingTrust { ProgressView().controlSize(.small) }
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let backup {
                    Label(L10n.tr("codex.hooks.backup") + ": " + backup, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                switch trustStatus {
                case .notInstalled:
                    Label(L10n.tr("codex.hooks.notInstalled"), systemImage: "circle.dotted")
                        .foregroundStyle(SettingsPalette.secondary)
                case .needsReview:
                    Label(L10n.tr("codex.hooks.reviewRequired"),
                          systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                case .trusted:
                    Label(L10n.tr("codex.hooks.trusted"), systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                case nil: EmptyView()
                }
                if trustStatus != .trusted {
                    Text(L10n.tr("codex.hooks.nextStep"))
                        .foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .onAppear { refresh() }
        .onChange(of: appLanguage) { _, _ in refresh() }
    }

    private func refresh() {
        checkGeneration += 1
        trustStatus = nil
        checkingTrust = false
        do {
            preview = try setup.preview()
            error = nil
            if preview?.canApply == false { checkTrust() }
        } catch {
            preview = nil
            self.error = setupErrorText(error)
        }
    }

    private func connect() {
        guard !checkingTrust else { return }
        guard let binary = CodexBinaryLocator.detected() else {
            error = L10n.tr("codex.hooks.statusUnavailable")
            return
        }
        do {
            let current = try setup.preview()
            if current.canApply { backup = try setup.apply(current)?.lastPathComponent }
            preview = try setup.preview()
        } catch {
            self.error = setupErrorText(error)
            return
        }
        checkGeneration += 1
        let generation = checkGeneration
        checkingTrust = true
        error = nil
        let authorization = CodexHookAuthorization(command: setup.command, sourcePath: setup.hooksURL.path)
        Task {
            do {
                // Connect is explicit consent for these bundled hooks. Codex
                // supplies its current definition hashes; authorization rechecks
                // them and changes only these eight exact hook definitions.
                let plan = try await authorization.prepare(binary: binary)
                try await authorization.authorize(binary: binary, reviewed: plan)
                guard generation == checkGeneration else { return }
                trustStatus = .trusted
                checkingTrust = false
            } catch {
                guard generation == checkGeneration else { return }
                checkingTrust = false
                self.error = L10n.tr("codex.hooks.authorizationFailed")
            }
        }
    }

    private func setupErrorText(_ error: Error) -> String {
        guard let error = error as? CodexHookSetup.SetupError else { return error.localizedDescription }
        switch error {
        case .invalidAdapter: return L10n.tr("codex.hooks.error.invalidAdapter")
        case .invalidHelper: return L10n.tr("codex.hooks.error.invalidHelper")
        case .unsupportedFile: return L10n.tr("codex.hooks.error.unsupportedFile")
        case .changedSincePreview: return L10n.tr("codex.hooks.error.changedSincePreview")
        case .ambiguousInstallation: return L10n.tr("codex.hooks.error.ambiguousInstallation")
        }
    }

    private func checkTrust() {
        guard let preview, !preview.canApply else { return }
        guard let binary = CodexBinaryLocator.detected() else {
            error = L10n.tr("codex.hooks.statusUnavailable")
            return
        }
        checkGeneration += 1
        let generation = checkGeneration
        checkingTrust = true
        Task {
            do {
                let status = try await CodexHookTrustChecker().check(binary: binary, command: setup.command)
                guard checkGeneration == generation else { return }
                trustStatus = status
                checkingTrust = false
            } catch {
                guard checkGeneration == generation else { return }
                self.error = L10n.tr("codex.hooks.statusUnavailable")
                checkingTrust = false
            }
        }
    }
}
