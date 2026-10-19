import SwiftUI
import SINotchCore

/// NSRegistrationDomain is process-wide even for named UserDefaults suites.
/// A preview must keep its overrides entirely outside that shared domain.
private final class PreviewPreferences: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "si-notch.preview.\(UUID().uuidString)")! }
    override func register(defaults: [String: Any]) { values.merge(defaults) { _, new in new } }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

enum IslandPreviewLayout: String, CaseIterable, Identifiable {
    case compact, expanded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: L10n.tr("appearance.compact")
        case .expanded: L10n.tr("appearance.expanded")
        }
    }
}

/// Fixtures go straight into a local reducer. This model never starts app services,
/// sends IPC, processes incoming events, or changes an agent's configuration.
@MainActor final class IslandPreviewModel: ObservableObject {
    let model: AppModel
    @Published private(set) var layout: IslandPreviewLayout = .expanded
    @Published private(set) var status: AgentStatus = .working
    @Published private(set) var availableWidth: CGFloat = 420

    var expandedHeight: CGFloat { max(188, min(220, model.desiredPanelHeight)) }
    var visibleWidth: CGFloat {
        layout == .expanded ? availableWidth : model.cameraWidth + model.compactWingWidth + model.compactStatusWidth + model.compactShoulderWidth * 2
    }
    var visibleHeight: CGFloat { layout == .expanded ? expandedHeight : model.headerHeight }

    init() {
        let defaults = PreviewPreferences()
        model = AppModel(defaults: defaults)
        var preferences: [String: Any] = [:]
        for key in ["showCompanion", "showModel", "showReasoning", "showProject", "showTasks", "showSubagents", "showActivity", "fontSize"] {
            preferences[key] = UserDefaults.standard.object(forKey: key)
        }
        preferences.merge(["sound": false, "quiet": false, "autoExpand": false, "codexAutoDetect": false,
                           "completionReveal": false, "attentionReveal": false, "blockedDirectories": "", "blockedPromptPrefixes": ""]) { _, new in new }
        defaults.register(defaults: preferences)
        model.cameraWidth = 140
        model.headerHeight = 36
        refreshFixture()
        updateGeometry()
    }

    func setLayout(_ value: IslandPreviewLayout) {
        layout = value
        updateGeometry()
    }

    func setStatus(_ value: AgentStatus) {
        guard [.working, .waiting, .completed].contains(value) else { return }
        status = value
        refreshFixture()
        updateGeometry()
    }

    func setAvailableWidth(_ value: CGFloat) {
        guard value.isFinite else { return }
        availableWidth = max(280, min(420, value - 32))
        updateGeometry()
    }

    private func refreshFixture() {
        let messageKey: String
        let kind: AgentEventKind
        switch status {
        case .waiting: messageKey = "appearance.sampleWaiting"; kind = .waiting
        case .completed: messageKey = "appearance.sampleCompleted"; kind = .completed
        default: messageKey = "appearance.sampleWorking"; kind = .working
        }
        let id = "preview-design"
        var store = SessionStore()
        store.apply(AgentEvent(sessionID: id, provider: "codex", kind: kind,
                               title: "appearance.sampleTitle", message: messageKey,
                               toolName: status == .working ? "review" : nil))
        model.store = store
        model.appOwnedTitles = [id: "appearance.sampleTitle"]
        model.appOwnedMessages = [id: messageKey]
        model.selectedID = nil
    }

    private func updateGeometry() {
        model.expandedPanelWidth = availableWidth
        model.expandedPanelHeight = expandedHeight
        // Direct state assignment deliberately bypasses presentation timers/reveals.
        model.expanded = layout == .expanded
    }
}

/// Insert at the top of Settings > Display. The camera surface stays opaque;
/// everything inside the viewport is an isolated, noninteractive sample session.
@MainActor struct IslandPreviewSettingsView: View {
    @StateObject private var preview = IslandPreviewModel()
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = appLanguage
        GroupBox(L10n.tr("appearance.preview")) {
            VStack(alignment: .leading, spacing: 14) {
                GeometryReader { viewport in
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Color(red: 0.14, green: 0.23, blue: 0.31),
                                                Color(red: 0.29, green: 0.35, blue: 0.33),
                                                Color(red: 0.38, green: 0.24, blue: 0.28)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Ellipse().fill(.white.opacity(0.12)).frame(width: 250, height: 130)
                            .blur(radius: 45).offset(x: 120, y: 95)
                        IslandView(model: preview.model)
                            .frame(width: preview.visibleWidth, height: preview.visibleHeight)
                            .allowsHitTesting(false)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(L10n.tr("appearance.previewLabel", preview.layout.label, preview.status.label))
                            .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0), value: preview.layout)
                            .animation(reduceMotion ? nil : .spring(duration: 0.24, bounce: 0), value: preview.status)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
                    .onChange(of: viewport.size.width, initial: true) { _, width in preview.setAvailableWidth(width) }
                }.frame(height: 244)

                HStack(spacing: 16) {
                    Picker(L10n.tr("appearance.layout"), selection: Binding(get: { preview.layout }, set: { preview.setLayout($0) })) {
                        ForEach(IslandPreviewLayout.allCases) { option in Text(option.label).tag(option) }
                    }.pickerStyle(.segmented)
                    Picker(L10n.tr("appearance.state"), selection: Binding(get: { preview.status }, set: { preview.setStatus($0) })) {
                        ForEach([AgentStatus.working, .waiting, .completed], id: \.rawValue) { status in Text(status.label).tag(status) }
                    }.frame(maxWidth: 180)
                }
                Text(L10n.tr("appearance.previewHelp"))
                    .font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
