import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsAboutView: View {
    @ObservedObject var model: AppModel
    @State private var exportError: String?
    @State private var copied = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var diagnosticsText: String {
        [
            L10n.tr("about.report.version", version, build),
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            L10n.tr("about.report.channel", model.serverError == nil ? L10n.tr("about.connected") : L10n.tr("about.unavailable")),
            L10n.tr("about.report.events", model.receivedCount),
            L10n.tr("about.report.sessions", model.sessions.count),
            L10n.tr("about.report.pending", model.pending.count),
            L10n.tr("about.report.paused", model.paused ? L10n.tr("about.yes") : L10n.tr("about.no"))
        ].joined(separator: "\n") + "\n"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                BrandMark(size: 78)
                    .frame(width: 86, height: 86)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(SettingsPalette.border))
                Text("si-notch")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L10n.tr("about.version", version, build))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondary)
                Text(L10n.tr("about.summary"))
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsPalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 390)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)

            UpdateSettingsView()

            GroupBox(L10n.tr("about.project")) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsInfoRow(symbol: "person.crop.circle", title: L10n.tr("about.developer"), value: "dis/root")
                    Divider().overlay(SettingsPalette.border)
                    Link(destination: URL(string: "https://disroot.website/")!) {
                        SettingsInfoRow(symbol: "globe", title: L10n.tr("about.website"), value: "disroot.website ↗")
                    }.buttonStyle(.plain)
                    Divider().overlay(SettingsPalette.border)
                    Link(destination: URL(string: "https://github.com/eugeneb1ack/si-notch/blob/main/LICENSE")!) {
                        SettingsInfoRow(symbol: "doc.text", title: L10n.tr("about.license"), detail: L10n.tr("about.licenseName"))
                    }.buttonStyle(.plain)
                    Divider().overlay(SettingsPalette.border)
                    Link(destination: URL(string: "https://github.com/eugeneb1ack/si-notch")!) {
                        HStack(spacing: 12) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(SettingsPalette.secondary).frame(width: 22)
                            Text(L10n.tr("about.repository"))
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                                .foregroundStyle(SettingsPalette.secondary)
                        }
                        .frame(minHeight: 34)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("about.repositoryHelp"))
                }
            }

            GroupBox(L10n.tr("about.diagnostics")) {
                VStack(alignment: .leading, spacing: 11) {
                    SettingsInfoRow(
                        symbol: model.serverError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        title: L10n.tr("about.localChannel"),
                        value: model.serverError == nil ? L10n.tr("about.connected") : L10n.tr("about.unavailable"))
                    Text(L10n.tr("about.diagnosticsHelp"))
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(copied ? L10n.tr("about.copied") : L10n.tr("about.copyDiagnostics")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnosticsText, forType: .string)
                            copied = true
                        }
                        Button(L10n.tr("about.exportDiagnostics")) { exportDiagnostics() }
                    }
                    if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = L10n.tr("about.exportDiagnostics")
        panel.nameFieldStringValue = "si-notch-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try diagnosticsText.write(to: url, atomically: true, encoding: .utf8)
                exportError = nil
            } catch {
                exportError = L10n.tr("about.exportFailed")
            }
        }
    }
}
