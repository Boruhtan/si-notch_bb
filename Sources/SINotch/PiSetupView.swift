import SwiftUI

/// One-click registration for ordinary Pi launches. Never displays existing
/// settings values, which might include private provider configuration.
struct PiSetupView: View {
    let cliPath: String
    @State private var preview: PiSetup.Preview?
    @State private var error: String?
    @State private var backupName: String?
    @State private var applied = false
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private var setup: PiSetup {
        let contents = URL(fileURLWithPath: cliPath).deletingLastPathComponent().deletingLastPathComponent()
        return PiSetup(adapterPath: contents.appendingPathComponent("Resources/adapters/pi-si-notch.js").path,
                       helperPath: cliPath)
    }

    var body: some View {
        let _ = appLanguage
        GroupBox(L10n.tr("pi.setup.title")) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.tr("pi.setup.description"))
                    .foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview {
                    if preview.canApply {
                        Text(L10n.tr("pi.setup.preview"))
                            .foregroundStyle(SettingsPalette.secondary)
                        Text(preview.extensionPath)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L10n.tr("pi.setup.connect")) { connect(preview) }
                            .buttonStyle(NotchActionButtonStyle(prominent: true))
                    } else {
                        Label(L10n.tr("pi.setup.connected"), systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                if let backupName {
                    Label(L10n.tr("pi.setup.backup") + " " + backupName, systemImage: "doc.badge.clock")
                        .foregroundStyle(SettingsPalette.secondary)
                        .textSelection(.enabled)
                }
                if applied {
                    Text(L10n.tr("pi.setup.reload"))
                        .foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
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
        do {
            preview = try setup.preview()
            error = nil
        } catch {
            preview = nil
            self.error = errorText(error)
        }
    }

    private func connect(_ preview: PiSetup.Preview) {
        do {
            backupName = try setup.apply(preview)?.lastPathComponent
            applied = true
            refresh()
        } catch {
            backupName = nil
            applied = false
            refresh()
            self.error = errorText(error)
        }
    }

    private func errorText(_ error: Error) -> String {
        guard let error = error as? PiSetup.SetupError else { return error.localizedDescription }
        switch error {
        case .invalidAdapter: return L10n.tr("pi.setup.error.invalidAdapter")
        case .invalidHelper: return L10n.tr("pi.setup.error.invalidHelper")
        case .unsupportedFile: return L10n.tr("pi.setup.error.unsupportedFile")
        case .ambiguousInstallation: return L10n.tr("pi.setup.error.ambiguousInstallation")
        case .changedSincePreview: return L10n.tr("pi.setup.error.changedSincePreview")
        case .busy: return L10n.tr("pi.setup.error.busy")
        case .writeFailed: return L10n.tr("pi.setup.error.writeFailed")
        }
    }
}
