import SwiftUI

struct RemoteSettingsView: View {
    @ObservedObject var controller: RemoteConnectionController
    let localSocketPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("remote.title")).font(.system(size: 17, weight: .semibold))
            Text(L10n.tr("remote.help"))
                .font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox(L10n.tr("remote.settingsTab")) {
                VStack(alignment: .leading, spacing: 11) {
                    TextField(L10n.tr("remote.host"), text: $controller.host)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("remote.host"))
                    TextField(L10n.tr("remote.path"), text: $controller.remoteSocketPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("remote.path"))
                    Text(L10n.tr("remote.pathHelp"))
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                    HStack {
                        Button(L10n.tr("remote.connect")) { controller.connect(localSocketPath: localSocketPath) }
                            .disabled(isActive)
                        Button(L10n.tr("remote.disconnect")) { controller.disconnect() }
                            .disabled(!isActive)
                        Spacer()
                        Label(statusText, systemImage: statusIcon)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                    }
                }
            }
            .groupBoxStyle(SettingsCardGroupBoxStyle())
            if case .failed(let failure) = controller.state {
                Label(errorText(failure), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text(L10n.tr("remote.security"))
                .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("remote.setup"))
                .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsInfoRow(symbol: "cable.connector", title: L10n.tr("remote.localSocket"), value: localSocketPath)
        }
    }

    private var isActive: Bool {
        switch controller.state {
        case .connecting, .connected, .retrying: true
        case .disconnected, .failed: false
        }
    }
    private var statusText: String {
        switch controller.state {
        case .disconnected: L10n.tr("remote.disconnected")
        case .connecting: L10n.tr("remote.connecting")
        case .connected: L10n.tr("remote.connected")
        case .retrying: L10n.tr("remote.retrying")
        case .failed: L10n.tr("remote.failed")
        }
    }
    private var statusIcon: String {
        switch controller.state {
        case .connected: "checkmark.circle.fill"
        case .connecting, .retrying: "arrow.triangle.2.circlepath"
        case .disconnected, .failed: "circle.dotted"
        }
    }
    private var statusColor: Color {
        switch controller.state {
        case .connected: .green
        case .failed: .orange
        default: SettingsPalette.secondary
        }
    }
    private func errorText(_ failure: RemoteConnectionFailure) -> String {
        switch failure {
        case .invalidHost: L10n.tr("remote.error.invalidHost")
        case .invalidPath: L10n.tr("remote.error.invalidPath")
        case .localSocketUnavailable: L10n.tr("remote.error.localSocketUnavailable")
        case .sshUnavailable: L10n.tr("remote.error.sshUnavailable")
        case .connectionFailed(let status): L10n.tr("remote.error.connectionFailed", status)
        }
    }
}
