import SwiftUI
import AppKit

struct AgentSetupView: View {
    let provider: HarnessKind
    let cliPath: String
    @State private var preview: AgentSetup.Preview?
    @State private var error: String?
    @State private var applied = false
    @State private var backups: [URL] = []
    @State private var localProfiles: [AgentSetup.LocalHermesProfile] = []
    @State private var selectedLocalProfile = ""
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private var setup: AgentSetup {
        var environment = ProcessInfo.processInfo.environment
        if provider == .hermes, let profile = localProfiles.first(where: { $0.id == selectedLocalProfile }) {
            environment["HERMES_HOME"] = profile.home.path
        }
        return AgentSetup(provider: provider, helperPath: cliPath, environment: environment)
    }
    var body: some View {
        let _ = appLanguage
        GroupBox(L10n.tr("agent.setup.title", provider.displayName)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("agent.setup.description")).foregroundStyle(SettingsPalette.secondary)
                if provider == .hermes, !localProfiles.isEmpty {
                    Picker(L10n.tr("agent.setup.hermesProfile"), selection: $selectedLocalProfile) {
                        ForEach(localProfiles) { Text($0.name).tag($0.id) }
                    }
                }
                if let preview {
                    ForEach(preview.files, id: \.url) { file in
                        Text(file.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/"))
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if preview.canApply {
                        Button(L10n.tr("agent.setup.connect", provider.displayName)) { connect() }
                            .buttonStyle(NotchActionButtonStyle(prominent: true))
                    } else {
                        Label(L10n.tr("agent.setup.configured"), systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    if applied || !preview.canApply {
                        if provider == .hermes {
                            Text(L10n.tr("agent.setup.hermesEnable"))
                            HStack {
                                Text(setup.hermesEnableCommand).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Button(L10n.tr("Скопировать команды")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(setup.hermesEnableCommand, forType: .string)
                                }.controlSize(.small)
                            }
                        } else { Text(L10n.tr("agent.setup.restart")) }
                    }
                }
                if !backups.isEmpty {
                    Label(L10n.tr("agent.setup.backup"), systemImage: "doc.badge.clock")
                        .foregroundStyle(SettingsPalette.secondary)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button(L10n.tr("discovery.refresh")) { refresh() }.controlSize(.small)
                }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .onAppear { refresh() }
        .onChange(of: appLanguage) { _, _ in refresh() }
        .onChange(of: selectedLocalProfile) { _, _ in applied = false; backups = []; refresh() }
    }

    private func refresh() {
        if provider == .hermes, localProfiles.isEmpty {
            localProfiles = setup.localHermesProfiles()
            selectedLocalProfile = localProfiles.first?.id ?? ""
        }
        do { preview = try setup.preview(); error = nil }
        catch { preview = nil; self.error = message(error) }
    }
    private func connect() {
        guard let preview else { return }
        do { backups = try setup.apply(preview); applied = true; refresh() }
        catch { applied = false; refresh(); self.error = message(error) }
    }
    private func message(_ error: Error) -> String {
        guard let error = error as? AgentSetup.SetupError else { return L10n.tr("agent.setup.error.file") }
        switch error {
        case .invalidHelper: return L10n.tr("pi.setup.error.invalidHelper")
        case .unsupportedFile: return L10n.tr("agent.setup.error.file")
        case .conflictingAdapter: return L10n.tr("agent.setup.error.conflict")
        case .hooksDisabled: return L10n.tr("agent.setup.error.disabled")
        case .changedSincePreview: return L10n.tr("pi.setup.error.changedSincePreview")
        case .busy: return L10n.tr("pi.setup.error.busy")
        case .writeFailed: return L10n.tr("pi.setup.error.writeFailed")
        }
    }
}
