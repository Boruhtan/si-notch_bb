import SwiftUI

struct AgentInteractionView: View {
    @ObservedObject var model: AppModel
    let request: AgentInteraction
    let providerName: String
    let canOpenAgent: Bool
    let openAgent: () -> Void
    @State private var answers: [String: String] = [:]
    private var sending: Bool { model.interactionSubmitting.contains(request.id) }
    private var failed: Bool { model.interactionErrors.contains(request.id) }
    private var blocked: Bool {
        failed || model.interactions(for: request.sessionID).contains { model.interactionSubmitting.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr(request.isApproval ? "interaction.approvalTitle" : "interaction.questionTitle"), systemImage: request.isApproval ? "hand.raised" : "bubble.left")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !request.detail.isEmpty {
                        Text(request.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(request.questions) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(question.title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                                Button { answers[question.id] = option } label: {
                                    HStack(alignment: .top, spacing: 7) {
                                        Image(systemName: answers[question.id] == option ? "largecircle.fill.circle" : "circle")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(option).fixedSize(horizontal: false, vertical: true)
                                            if !question.optionDescriptions[index].isEmpty {
                                                Text(question.optionDescriptions[index]).foregroundStyle(NotchDesign.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).accessibilityIdentifier("interaction-option-\(request.id)-\(question.id)-\(index)")
                            }
                            if question.secret {
                                SecureField(L10n.tr("Ваш ответ"), text: answer(question.id)).textFieldStyle(.roundedBorder)
                            } else {
                                TextField(L10n.tr("Ваш ответ"), text: answer(question.id), axis: .vertical)
                                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("interaction-answer-" + question.id)
                            }
                        }
                    }
                }.padding(.trailing, 4)
            }.frame(maxHeight: request.isApproval ? 200 : 300)
            .disabled(blocked)
            if failed {
                Text(L10n.tr("interaction.failed", providerName)).font(.system(size: 11)).foregroundStyle(.orange)
            } else if sending {
                Label(L10n.tr("interaction.sending", providerName), systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
            }
            if !request.actions.isEmpty {
                // Each action is supplied by this request. No global Always Allow.
                ForEach(request.actions) { action in
                    Button(L10n.tr(action.label)) { model.respondToInteraction(request, action: action.id) }
                        .buttonStyle(NotchActionButtonStyle(prominent: !action.destructive, destructive: action.destructive))
                        .disabled(blocked).accessibilityIdentifier("interaction-action-" + request.id + "-" + action.id)
                }
            }
            if !request.isApproval {
                Button(L10n.tr("Ответить")) { model.respondToInteraction(request, answers: answers) }
                    .buttonStyle(NotchActionButtonStyle(prominent: true))
                    .disabled(blocked || !request.accepts(answers: answers))
                    .accessibilityIdentifier("interaction-submit-" + request.id)
            }
            if canOpenAgent {
                Button(L10n.tr("interaction.openAgent", providerName), action: openAgent).buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
            } else {
                Text(L10n.tr("interaction.openManually", providerName)).font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
            }
        }.padding(10).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .id(request.id)
    }
    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}
