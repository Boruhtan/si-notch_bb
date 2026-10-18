import SwiftUI
import SINotchCore

struct CompanionSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("companionStyle") private var savedStyle = CompanionStyle.robot.rawValue
    @AppStorage("showCompanion") private var showCompanion = true
    @State private var previewStatus: AgentStatus = .working
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 8)]
    private var selectedStyle: CompanionStyle { CompanionStyle(rawValue: savedStyle) ?? .robot }

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("companion.description"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                CompanionView(status: previewStatus, size: 94, style: selectedStyle)
                    .id(selectedStyle)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr(selectedStyle.displayNameKey))
                        .font(.system(size: 17, weight: .medium))
                    Picker(L10n.tr("companion.previewStatus"), selection: $previewStatus) {
                        ForEach(AgentStatus.allCases, id: \.rawValue) { status in
                            Text(status.label).tag(status)
                        }
                    }.frame(maxWidth: 250)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 8)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CompanionStyle.allCases) { style in
                    let selected = selectedStyle == style
                    Button {
                        savedStyle = style.rawValue
                        showCompanion = true
                    } label: {
                        VStack(spacing: 8) {
                            CompanionView(status: .idle, size: 40,
                                          interactive: false, style: style, animated: false)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            HStack(spacing: 5) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(NotchDesign.accent)
                                        .font(.system(size: 10))
                                }
                                Text(L10n.tr(style.displayNameKey))
                                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selected ? NotchDesign.accent.opacity(0.10) : Color.white.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? NotchDesign.accent.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr(style.displayNameKey))
                    .accessibilityIdentifier("companion-option-" + style.rawValue)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: savedStyle)
        }
        .font(.system(size: 12))
    }
}
