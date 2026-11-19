import SwiftUI

struct AttentionQueueView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let queue = model.attentionQueue
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if queue.count == 0 {
                        Text(L10n.tr("attention.empty"))
                            .font(.system(size: 12)).foregroundStyle(NotchDesign.secondary)
                            .padding(.vertical, 24).frame(maxWidth: .infinity)
                    }
                    if !queue.requests.isEmpty {
                        sectionTitle("attention.requests", id: "attention-requests")
                        ForEach(queue.requests) { item in
                            SessionCard(session: item.session, model: model, attention: item)
                        }
                    }
                    if !queue.errors.isEmpty || !queue.ssh.isEmpty {
                        sectionTitle("attention.problems", id: "attention-problems")
                        ForEach(queue.errors) { item in
                            SessionCard(session: item.session, model: model, attention: item)
                        }
                        ForEach(queue.ssh) { connection in
                            sshCard(connection)
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }.accessibilityIdentifier("attention-queue")
        }
    }

    private func sectionTitle(_ key: String, id: String) -> some View {
        Text(L10n.tr(key))
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(NotchDesign.secondary)
            .padding(.leading, 4).accessibilityAddTraits(.isHeader).accessibilityIdentifier(id)
    }

    private func sshCard(_ connection: AttentionSSHItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(L10n.tr("remote.sshState", connection.state.label))
                    .font(.system(size: 10)).foregroundStyle(NotchDesign.secondary)
            }
            Spacer(minLength: 8)
            if let open = model.openRemoteConnections {
                Button(L10n.tr("attention.sshSettings"), action: open)
                    .buttonStyle(AttentionActionButtonStyle())
                    .accessibilityIdentifier("attention-ssh-settings-" + connection.id.uuidString)
            }
        }.padding(13).background(.orange.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .contain).accessibilityIdentifier("attention-ssh-" + connection.id.uuidString)
    }
}

struct AttentionActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? NotchDesign.ink : .white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(prominent ? NotchDesign.accent : .white.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
    }
}
