import SwiftUI

struct RemoteSettingsView: View {
    @ObservedObject var manager: RemoteConnectionManager
    let localSocketPath: String
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("remote.title")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { if let id = manager.add() { expanded.insert(id) } } label: {
                    Label(L10n.tr("remote.add"), systemImage: "plus")
                }
            }
            Text(L10n.tr("remote.connectionsHelp")).font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = manager.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            ForEach(manager.connections) { connection in
                RemoteConnectionCard(manager: manager, id: connection.id, localSocketPath: localSocketPath,
                    expanded: Binding(get: { expanded.contains(connection.id) }, set: {
                        if $0 { expanded.insert(connection.id) } else { expanded.remove(connection.id) }
                    }))
            }
            if manager.connections.isEmpty {
                Text(L10n.tr("remote.empty")).font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary).padding(.vertical, 12)
            }
            Text(L10n.tr("remote.security")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsInfoRow(symbol: "cable.connector", title: L10n.tr("remote.localSocket"), value: localSocketPath)
        }
        .onAppear { if manager.connections.count == 1, let id = manager.connections.first?.id { expanded.insert(id) } }
    }
}

private struct RemoteConnectionCard: View {
    @ObservedObject var manager: RemoteConnectionManager
    let id: UUID
    let localSocketPath: String
    @Binding var expanded: Bool
    @StateObject private var setup = RemoteHermesSetupModel()
    @State private var removing = false
    private var connection: RemoteSSHConnection { manager.connections.first { $0.id == id } ?? RemoteSSHConnection(name: "") }
    private var active: Bool { manager.isActive(id) }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.tr("remote.name"), text: field(\.name)).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("remote.name"))
                    TextField(L10n.tr("remote.host"), text: field(\.host)).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("remote.host")).disabled(active || setup.busy)
                    TextField(L10n.tr("remote.path"), text: field(\.remoteSocketPath)).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("remote.path")).disabled(active || setup.busy)
                    Text(L10n.tr("remote.pathHelp")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                    HStack {
                        Button(L10n.tr(active ? "remote.disconnect" : "remote.connect")) {
                            if active { manager.disconnect(id) } else { manager.connect(id, localSocketPath: localSocketPath) }
                        }.disabled(setup.busy)
                        Button(L10n.tr("remote.checkConnection")) { Task { await setup.checkConnection(connection) } }
                            .disabled(setup.busy || connection.host.isEmpty)
                        Spacer()
                        Toggle(L10n.tr("remote.showInAgents"), isOn: field(\.showInAgents)).toggleStyle(.checkbox)
                    }
                    if setup.sshChecked {
                        Label(L10n.tr("remote.sshChecked"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.green)
                    }
                    if case .failed(let failure) = manager.state(id) {
                        Text(errorText(failure)).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Divider()
                    profilesSection
                    DisclosureGroup(L10n.tr("remote.advanced")) {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(L10n.tr("remote.python")) { TextField("", text: field(\.pythonPath)).textFieldStyle(.roundedBorder) }
                            LabeledContent(L10n.tr("remote.hermesHome")) { TextField("", text: field(\.hermesHome)).textFieldStyle(.roundedBorder) }
                            LabeledContent(L10n.tr("remote.hermesCLI")) { TextField("", text: field(\.hermesCLI)).textFieldStyle(.roundedBorder) }
                        }.disabled(setup.busy).font(.system(size: 11)).padding(.top, 8)
                    }
                    HStack {
                        Spacer()
                        Button(role: .destructive) { removing = true } label: { Label(L10n.tr("remote.remove"), systemImage: "trash") }
                            .disabled(setup.busy)
                    }
                }.padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "network").foregroundStyle(.teal)
                    Text(connection.name.isEmpty ? L10n.tr("remote.defaultName") : connection.name).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text(statusText).font(.system(size: 11)).foregroundStyle(manager.state(id) == .connected ? .green : SettingsPalette.secondary)
                }.padding(.vertical, 3)
            }
        }.groupBoxStyle(SettingsCardGroupBoxStyle())
        .confirmationDialog(L10n.tr("remote.removeConfirm", connection.name), isPresented: $removing, titleVisibility: .visible) {
            Button(L10n.tr("remote.remove"), role: .destructive) { manager.remove(id) }
            Button(L10n.tr("remote.cancel"), role: .cancel) {}
        } message: { Text(L10n.tr("remote.removeHelp")) }
        .onChange(of: connection.setupIdentity) { _, _ in setup.configurationChanged(connection) }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("remote.profiles")).fontWeight(.semibold)
                Spacer()
                if setup.busy { ProgressView().controlSize(.small) }
                Button(L10n.tr("remote.checkProfiles")) {
                    Task { await setup.inspect(connection) { result in
                        var value = connection; value.profiles = result.profiles
                        value.remoteSocketPath = result.socketPath
                        manager.update(value)
                    } }
                }.disabled(setup.busy || connection.host.isEmpty)
            }
            Text(L10n.tr("remote.profilesHelp")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if setup.snapshot == nil, !connection.profiles.isEmpty {
                Text(connection.profiles.filter(\.enabled).map(\.displayName).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if setup.snapshot != nil {
                HStack {
                    Button(L10n.tr("remote.selectAll")) { for index in setup.profiles.indices { setup.profiles[index].enabled = true } }
                    Button(L10n.tr("remote.selectNone")) { for index in setup.profiles.indices { setup.profiles[index].enabled = false } }
                }.buttonStyle(.link).font(.system(size: 11)).disabled(setup.busy)
                ForEach($setup.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Toggle(isOn: $profile.enabled) { Text(profile.id).font(.system(size: 11, design: .monospaced)) }.toggleStyle(.checkbox)
                            TextField(L10n.tr("remote.profileName"), text: $profile.displayName).textFieldStyle(.roundedBorder)
                                .accessibilityLabel(L10n.tr("remote.profileName") + " " + profile.id)
                        }
                        Toggle(L10n.tr("remote.showText"), isOn: $profile.showSessionText).toggleStyle(.checkbox)
                            .font(.system(size: 11)).padding(.leading, 22).disabled(!profile.enabled)
                    }.disabled(setup.busy)
                }
                Text(L10n.tr("remote.textHelp")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                Button(L10n.tr("remote.preview")) { Task { await setup.preview(connection) } }.disabled(setup.busy)
            }
            if let plan = setup.plan {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.hasChanges ? L10n.tr("remote.previewCounts", plan.changes.count, plan.fileCount, plan.configCount) : L10n.tr("remote.noChanges"))
                        .font(.system(size: 11, weight: .medium))
                    ForEach(plan.changes) { change in
                        Text("\(change.displayName) · \(actionText(change.action))").font(.system(size: 11))
                    }
                    if plan.hasChanges {
                        Button(L10n.tr("remote.apply")) { Task { await setup.apply(connection, save: saveProfiles) } }
                            .disabled(!setup.canApply(connection))
                        if !setup.canApply(connection) && !setup.busy {
                            Text(L10n.tr("remote.previewAgain")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if let receipt = setup.receipt {
                Text(L10n.tr("remote.applied")).font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                if !receipt.backup.isEmpty { Text(L10n.tr("remote.backup", receipt.backup)).font(.system(size: 10)).textSelection(.enabled) }
                if receipt.profiles.contains(where: { $0.enabled == true && !$0.loaded }) {
                    Text(L10n.tr("remote.loadNextRun")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                }
            }
            if let error = setup.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }

    private func actionText(_ action: String) -> String {
        switch action {
        case "connect": L10n.tr("remote.action.connect")
        case "disconnect": L10n.tr("remote.action.disconnect")
        default: L10n.tr("remote.action.update")
        }
    }
    private func saveProfiles(_ profiles: [RemoteHermesProfile]) { var value = connection; value.profiles = profiles; manager.update(value) }
    private func field<T>(_ keyPath: WritableKeyPath<RemoteSSHConnection, T>) -> Binding<T> {
        Binding(get: { connection[keyPath: keyPath] }, set: { newValue in
            var value = connection; value[keyPath: keyPath] = newValue; manager.update(value)
        })
    }
    private var statusText: String {
        switch manager.state(id) {
        case .disconnected: L10n.tr("remote.disconnected")
        case .connecting: L10n.tr("remote.connecting")
        case .connected: L10n.tr("remote.connected")
        case .retrying: L10n.tr("remote.retrying")
        case .failed: L10n.tr("remote.failed")
        }
    }
    private func errorText(_ failure: RemoteConnectionFailure) -> String {
        switch failure {
        case .invalidHost: L10n.tr("remote.error.invalidHost")
        case .invalidPath: L10n.tr("remote.error.invalidPath")
        case .localSocketUnavailable: L10n.tr("remote.error.localSocketUnavailable")
        case .sshUnavailable: L10n.tr("remote.error.sshUnavailable")
        case .socketRecoveryFailed: L10n.tr("remote.error.socketRecoveryFailed")
        case .connectionFailed(let status): L10n.tr("remote.error.connectionFailed", status)
        }
    }
}
