import SwiftUI

enum SettingsPalette {
    static let background = Color(white: 0.12)
    static let sidebar = Color(white: 0.15)
    static let card = Color(white: 0.155)
    static let selected = Color.accentColor
    static let border = Color.white.opacity(0.09)
    static let secondary = Color.white.opacity(0.65)
}

/// Glass belongs to navigation. Content cards stay opaque for comfortable reading.
struct SettingsSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            SettingsPalette.sidebar
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.12)), in: Rectangle())
        } else {
            Rectangle().fill(.regularMaterial)
                .overlay(Color.black.opacity(0.08))
        }
    }
}

/// A quiet app identity for the sidebar; the product's own icon carries the detail.
struct SettingsBrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("si-notch")
                    .font(.system(size: 16, weight: .semibold))
                Text(L10n.tr("Настройки"))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondary)
            }
            .foregroundStyle(.white.opacity(0.94))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct SettingsCardGroupBoxStyle: GroupBoxStyle {
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 2)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(17)
                .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(contrast == .increased ? 0.35 : 0.045), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keeps the native macOS switch, but places every switch in the same trailing column.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 14) {
            configuration.label
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .padding(.vertical, 2)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

struct SettingsInfoRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SettingsPalette.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minHeight: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Stable IDs are shared with menu shortcuts and the screenshot exporter.
struct SettingsDestination: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let group: Int
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        let text = ([title, subtitle] + keywords).joined(separator: " ")
        return terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }

    static var all: [SettingsDestination] {
        [
            .init(id: 0, title: L10n.tr("settings.general"), subtitle: L10n.tr("settings.subtitleGeneral"),
                  symbol: "gearshape.fill", color: .gray, group: 0,
                  keywords: [L10n.tr("language.title"), L10n.tr("Запускать при входе в macOS"),
                             L10n.tr("Раскрывать при наведении"), L10n.tr("Задержка наведения"),
                             L10n.tr("settings.filters"), L10n.tr("settings.blockedDirectories"),
                             L10n.tr("settings.blockedPromptPrefixes"), L10n.tr("settings.hideWhenIdle"),
                             L10n.tr("Считать неактивной через"), L10n.tr("settings.disableClickJump")]),
            .init(id: 1, title: L10n.tr("Подключение"), subtitle: L10n.tr("settings.subtitleIntegrations"),
                  symbol: "point.3.connected.trianglepath.dotted", color: .cyan, group: 0,
                  keywords: ["Codex Claude Pi OpenCode Hermes Gemini Copilot Cursor JSON", L10n.tr("settings.codexAutoDetect")]),
            .init(id: 6, title: L10n.tr("settings.notifications"), subtitle: L10n.tr("settings.subtitleNotifications"),
                  symbol: "bell.fill", color: .red, group: 0,
                  keywords: [L10n.tr("Тихий режим: без звуков и автоматического раскрытия"),
                             L10n.tr("settings.completionReveal"), L10n.tr("settings.attentionReveal"),
                             L10n.tr("settings.followupMinutes"), L10n.tr("settings.collapseOnLeave"),
                             L10n.tr("settings.suppressTargetFrontmost"), L10n.tr("settings.dismissOutside"),
                             L10n.tr("Оставлять раскрытой после ухода указателя"), L10n.tr("Показ завершения")]),
            .init(id: 5, title: L10n.tr("settings.display"), subtitle: L10n.tr("settings.subtitleDisplay"),
                  symbol: "display", color: .indigo, group: 0,
                  keywords: [L10n.tr("appearance.preview"), L10n.tr("settings.visibility"), L10n.tr("Расположение"),
                             L10n.tr("Экран"), L10n.tr("Ширина"), L10n.tr("Высота"), L10n.tr("settings.fontSize"),
                             L10n.tr("settings.showOnlyWithSessions"), L10n.tr("settings.hideInFullScreen"),
                             L10n.tr("settings.cardDetails"), L10n.tr("settings.showModel"), L10n.tr("settings.showReasoning"),
                             L10n.tr("settings.showProject"), L10n.tr("settings.showTasks"), L10n.tr("settings.showSubagents"),
                             L10n.tr("settings.showActivity")]),
            .init(id: 3, title: L10n.tr("sound.title"), subtitle: L10n.tr("settings.subtitleSound"),
                  symbol: "speaker.wave.2.fill", color: .green, group: 0,
                  keywords: [L10n.tr("sound.volume"), L10n.tr("sound.library"), L10n.tr("sound.import")]),
            .init(id: 8, title: L10n.tr("settings.usage"), subtitle: L10n.tr("settings.subtitleUsage"),
                  symbol: "chart.pie.fill", color: .pink, group: 0),
            .init(id: 11, title: L10n.tr("history.title"), subtitle: L10n.tr("history.subtitle"),
                  symbol: "clock.arrow.circlepath", color: .blue, group: 1),
            .init(id: 7, title: L10n.tr("settings.shortcuts"), subtitle: L10n.tr("settings.subtitleShortcuts"),
                  symbol: "keyboard.fill", color: .purple, group: 1,
                  keywords: [L10n.tr("settings.shortcutModifier")]),
            .init(id: 10, title: L10n.tr("remote.settingsTab"), subtitle: L10n.tr("settings.subtitleRemote"),
                  symbol: "network", color: .teal, group: 1, keywords: ["SSH Hermes"]),
            .init(id: 4, title: L10n.tr("companion.title"), subtitle: L10n.tr("settings.subtitleCompanion"),
                  symbol: "pawprint.fill", color: .mint, group: 1,
                  keywords: [L10n.tr("companion.description")]),
            .init(id: 2, title: L10n.tr("Диагностика"), subtitle: L10n.tr("settings.subtitleDiagnostics"),
                  symbol: "waveform.path.ecg", color: .orange, group: 1, keywords: ["CLI", L10n.tr("Unix-сокет")]),
            .init(id: 9, title: L10n.tr("about.title"), subtitle: L10n.tr("settings.subtitleAbout"),
                  symbol: "info.circle.fill", color: .blue, group: 2,
                  keywords: [L10n.tr("updates.title"), L10n.tr("about.license"), "GitHub"])
        ]
    }
}
