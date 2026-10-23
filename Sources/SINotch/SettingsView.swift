import SwiftUI
import SINotchCore
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appLanguage") var appLanguage = "auto"
    @AppStorage("hoverExpand") var hover = true
    @AppStorage("autoExpand") var autoExpand = true
    @AppStorage("keepOpen") var keepOpen = false
    @AppStorage("quiet") var quiet = false
    @AppStorage("displayMode") var displayMode = "notch"
    @AppStorage("screenID") var screenID = "auto"
    @AppStorage("followFocus") var followFocus = false
    @AppStorage("panelWidth") var width = 680.0
    @AppStorage("panelHeight") var height = 560.0
    @AppStorage("idleMinutes") var idleMinutes = 120
    @AppStorage("showCompanion") var companion = true
    @AppStorage("showOnlyWithSessions") var showOnlyWithSessions = false
    @AppStorage("hoverDelay") var hoverDelay = IslandTiming.hoverEnter
    @AppStorage("revealDwell") var revealDwell = 5.0
    @AppStorage("fontSize") var fontSize = 11.0
    @AppStorage("showModel") var showModel = true
    @AppStorage("showReasoning") var showReasoning = true
    @AppStorage("showProject") var showProject = true
    @AppStorage("showTasks") var showTasks = true
    @AppStorage("showSubagents") var showSubagents = true
    @AppStorage("showActivity") var showActivity = true
    @AppStorage("shortcutEnabled") var shortcutEnabled = true
    @AppStorage("shortcutModifier") var shortcutModifier = "ctrlAlt"
    @AppStorage("completionReveal") var completionReveal = false
    @AppStorage("attentionReveal") var attentionReveal = true
    @AppStorage("followupMinutes") var followupMinutes = 0
    @AppStorage("followupCompleted") var followupCompleted = false
    @AppStorage("blockedDirectories") var blockedDirectories = ""
    @AppStorage("blockedPromptPrefixes") var blockedPromptPrefixes = ""
    @AppStorage("codexAutoDetect") var codexAutoDetect = true
    @AppStorage("hideWhenIdle") var hideWhenIdle = false
    @AppStorage("hideInFullScreen") var hideInFullScreen = true
    @AppStorage("suppressWhenTargetAppFrontmost") var suppressWhenTargetAppFrontmost = true
    @AppStorage("dismissAutoRevealOnOutsideClick") var dismissAutoRevealOnOutsideClick = false
    @AppStorage("disableClickJump") var disableClickJump = false
    @AppStorage("collapseOnMouseLeave") var collapseOnMouseLeave = true
    @State var tab = 0
    @State var selectedProvider = "codex"
    @State var showAgentDiscovery = true
    @State var copied = false
    @State private var searchQuery = ""
    @State private var hoveredDestination: Int?
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedDestination: Int?
    @FocusState private var footerFocused: Bool
    @State var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onSelectionChange: ((Int, String) -> Void)?
    var cliPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/si-notchctl").path
        return FileManager.default.fileExists(atPath: bundled) ? bundled : Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("si-notchctl").path ?? "si-notchctl"
    }
    var shellQuotedCLI: String { shellQuote(cliPath) }
    func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var snippet: String {
        func event(_ name: String, title: String? = nil, message: String) -> String {
            var object = ["event": name, "session_id": "my-agent-1", "provider": "my-agent", "message": message]
            if let title { object["title"] = title }
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let value = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return shellQuotedCLI + " emit " + shellQuote(value)
        }
        return event("agent.working", title: L10n.tr("Моя задача"), message: L10n.tr("Работаю…")) + "\n\n" + event("agent.completed", message: L10n.tr("Готово"))
    }
    private var destinations: [SettingsDestination] { SettingsDestination.all }
    private var matchingDestinations: [SettingsDestination] { destinations.filter { $0.matches(searchQuery) } }
    private var selectedDestination: SettingsDestination { destinations.first { $0.id == tab } ?? destinations[0] }

    var body: some View {
        let _ = appLanguage
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(SettingsPalette.border).frame(width: 1)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    SettingsIconTile(symbol: selectedDestination.symbol, color: selectedDestination.color, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedDestination.title).font(.system(size: 22, weight: .semibold))
                        Text(selectedDestination.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(L10n.tr("Готово")) { model.closeSettings?() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                Rectangle().fill(SettingsPalette.border).frame(height: 1)
                if let error = model.settingsError {
                    Label(error.text, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28).padding(.top, 14)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if tab == 0 { general }
                        else if tab == 5 { display }
                        else if tab == 6 { notifications }
                        else if tab == 7 { shortcuts }
                        else if tab == 8 { usage }
                        else if tab == 1 { integrations }
                        else if tab == 3 { SoundSettingsView() }
                        else if tab == 4 { companionSettings }
                        else if tab == 10 { RemoteSettingsView(manager: model.remoteConnections, localSocketPath: model.socketPath) }
                        else if tab == 11 { HistorySettingsView(history: model.history, defaults: model.defaults) }
                        else if tab == 9 { SettingsAboutView(model: model) }
                        else { diagnostics }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 28).padding(.vertical, 26)
                }
                .id(tab)
            }.frame(maxWidth: .infinity)
        }
        .frame(minWidth: 820, minHeight: 660)
        .background(SettingsPalette.background)
        .preferredColorScheme(.dark)
        .tint(.accentColor)
        .toggleStyle(SettingsSwitchStyle())
        .controlSize(.regular)
        .groupBoxStyle(SettingsCardGroupBoxStyle())
        .defaultAppStorage(model.defaults)
        .environment(\.locale, Locale(identifier: L10n.language))
        .onChange(of: tab) { _, _ in onSelectionChange?(tab, selectedProvider) }
        .onChange(of: selectedProvider) { _, _ in onSelectionChange?(tab, selectedProvider) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsBrandHeader()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SettingsPalette.secondary).accessibilityHidden(true)
                TextField(L10n.tr("settings.search"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .focusEffectDisabled()
                    .accessibilityIdentifier("settings-search")
                    .onSubmit {
                        if let first = matchingDestinations.first {
                            tab = first.id
                            focusedDestination = first.id
                        }
                    }
                    .onExitCommand {
                        searchQuery = ""
                        searchFocused = false
                    }
                if !searchQuery.isEmpty {
                    Button { searchQuery = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SettingsPalette.secondary)
                    .accessibilityLabel(L10n.tr("settings.clearSearch"))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(searchFocused ? Color.accentColor : SettingsPalette.border, lineWidth: searchFocused ? 2 : 1))
            .padding(.horizontal, 14).padding(.bottom, 20)
            .background {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden().accessibilityHidden(true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if matchingDestinations.isEmpty {
                        Text(L10n.tr("settings.noSearchResults"))
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsPalette.secondary)
                            .padding(.horizontal, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(0..<3) { group in
                        let items = matchingDestinations.filter { $0.group == group }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group == 0 ? L10n.tr("settings.sectionMain") : group == 1 ? L10n.tr("settings.sectionAdvanced") : "si-notch")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SettingsPalette.secondary)
                                    .padding(.horizontal, 11).padding(.bottom, 4)
                                ForEach(items) { item in sidebarItem(item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 20)
            }
            Rectangle().fill(SettingsPalette.border).frame(height: 0.5).padding(.horizontal, 20)
            HStack {
                Link(destination: URL(string: "https://disroot.website/")!) {
                    HStack(spacing: 5) {
                        Text("dis/root")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsPalette.secondary)
                .focused($footerFocused)
                .focusEffectDisabled()
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(footerFocused ? Color.accentColor : .clear, lineWidth: 1))
                .help("disroot.website")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(width: 236)
        .background { SettingsSidebarBackground() }
    }

    private func sidebarItem(_ item: SettingsDestination) -> some View {
        let selected = tab == item.id
        return Button { tab = item.id } label: {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: item.symbol, color: item.color, size: 26)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.9))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? SettingsPalette.selected : Color.white.opacity(hoveredDestination == item.id ? 0.065 : 0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focusedDestination == item.id ? .white.opacity(0.8) : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedDestination, equals: item.id)
        .focusEffectDisabled()
        .onHover { hovering in hoveredDestination = hovering ? item.id : nil }
        .accessibilityIdentifier("settings-section-\(item.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox(L10n.tr("settings.startup")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.tr("language.title"), selection: $appLanguage) {
                        Text(L10n.tr("language.auto")).tag("auto")
                        Text(L10n.tr("language.en")).tag("en")
                        Text(L10n.tr("language.ru")).tag("ru")
                        Text(L10n.tr("language.zh-Hans")).tag("zh-Hans")
                    }
                    Toggle(L10n.tr("Запускать при входе в macOS"), isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; model.settingsError = nil }
                        catch { model.settingsError = .launchAtLogin(error.localizedDescription); launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                }
            }
            GroupBox(L10n.tr("settings.interaction")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("Раскрывать при наведении"), isOn: $hover)
                    HStack {
                        Text(L10n.tr("Задержка наведения"))
                        Slider(value: Binding(get: { HoverIntent.dwell(for: hoverDelay) }, set: { hoverDelay = $0 }),
                               in: IslandTiming.hoverEnter...0.8, step: 0.01)
                        Text(L10n.tr("%.2f с", HoverIntent.dwell(for: hoverDelay))).monospacedDigit()
                    }.disabled(!hover).help(L10n.tr("settings.hoverIntentHelp"))
                    Divider()
                    Picker(L10n.tr("Считать неактивной через"), selection: $idleMinutes) { Text(L10n.tr("30 минут")).tag(30); Text(L10n.tr("2 часа")).tag(120); Text(L10n.tr("8 часов")).tag(480); Text(L10n.tr("Никогда")).tag(0) }
                    Toggle(L10n.tr("settings.hideWhenIdle"), isOn: $hideWhenIdle)
                    Text(L10n.tr("settings.hideWhenIdleHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Toggle(L10n.tr("settings.disableClickJump"), isOn: $disableClickJump)
                }
            }
            GroupBox(L10n.tr("settings.filters")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.tr("settings.blockedDirectories"))
                    TextEditor(text: $blockedDirectories).font(.system(size: 11, design: .monospaced)).frame(height: 72)
                        .scrollContentBackground(.hidden).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel(L10n.tr("settings.blockedDirectories"))
                    Text(L10n.tr("settings.blockedPromptPrefixes"))
                    TextEditor(text: $blockedPromptPrefixes).font(.system(size: 11)).frame(height: 72)
                        .scrollContentBackground(.hidden).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel(L10n.tr("settings.blockedPromptPrefixes"))
                    Text(L10n.tr("settings.filterHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("Выйти из si-notch")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }.font(.system(size: 13))
    }
    var display: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Text(L10n.tr("settings.resetDisplayHelp"))
                    .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { DisplayPreferences.reset(in: model.defaults) } label: {
                    Label(L10n.tr("settings.resetDisplay"), systemImage: "arrow.counterclockwise")
                }.controlSize(.small)
            }
            GroupBox(L10n.tr("settings.visibility")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.tr("settings.showOnlyWithSessions"), isOn: $showOnlyWithSessions)
                    Text(L10n.tr("settings.showOnlyWithSessionsHelp"))
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L10n.tr("settings.hideInFullScreen"), isOn: $hideInFullScreen)
                    Text(L10n.tr("settings.hideInFullScreenHelp"))
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            IslandPreviewSettingsView()
            GroupBox(L10n.tr("settings.display")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.tr("Расположение"), selection: $displayMode) { Text(L10n.tr("settings.displayAutomatic")).tag("notch"); Text(L10n.tr("Под строкой меню")).tag("belowMenu") }
                    Text(L10n.tr("settings.externalDisplayHelp"))
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker(L10n.tr("Экран"), selection: $screenID) {
                        Text(L10n.tr("Автоматически (экран с чёлкой)")).tag("auto")
                        ForEach(NSScreen.screens, id: \.self) { screen in Text(screen.localizedName).tag(String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main")) }
                    }
                    Toggle(L10n.tr("При открытии выбирать экран под указателем"), isOn: $followFocus)
                    HStack { Text(L10n.tr("Ширина")); Slider(value: $width, in: 380...720, step: 10); Text("\(Int(width))").monospacedDigit().frame(width: 35) }
                    HStack { Text(L10n.tr("Высота")); Slider(value: $height, in: 360...800, step: 10); Text("\(Int(height))").monospacedDigit().frame(width: 35) }
                    HStack { Text(L10n.tr("settings.fontSize")); Slider(value: $fontSize, in: 10...16, step: 1); Text(L10n.tr("settings.points", Int(fontSize))).monospacedDigit().frame(width: 48) }
                }
            }
            GroupBox(L10n.tr("settings.cardDetails")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("settings.showModel"), isOn: $showModel)
                    Toggle(L10n.tr("settings.showReasoning"), isOn: $showReasoning)
                    Toggle(L10n.tr("settings.showProject"), isOn: $showProject)
                    Toggle(L10n.tr("settings.showTasks"), isOn: $showTasks)
                    Toggle(L10n.tr("settings.showSubagents"), isOn: $showSubagents)
                    Toggle(L10n.tr("settings.showActivity"), isOn: $showActivity)
                    Text(L10n.tr("settings.cardDetailsHelp"))
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.font(.system(size: 13))
    }
    var notifications: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox(L10n.tr("settings.notifications")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("Тихий режим: без звуков и автоматического раскрытия"), isOn: $quiet)
                    Toggle(L10n.tr("Раскрывать при завершении, вопросе или ошибке"), isOn: $autoExpand).disabled(quiet)
                    Toggle(L10n.tr("settings.completionReveal"), isOn: $completionReveal).disabled(quiet || !autoExpand)
                    Toggle(L10n.tr("settings.attentionReveal"), isOn: $attentionReveal).disabled(quiet || !autoExpand)
                    Toggle(L10n.tr("settings.suppressTargetFrontmost"), isOn: $suppressWhenTargetAppFrontmost).disabled(!autoExpand)
                    Text(L10n.tr("settings.suppressTargetHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            GroupBox(L10n.tr("settings.presentation")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("settings.dismissOutside"), isOn: $dismissAutoRevealOnOutsideClick)
                    Toggle(L10n.tr("Оставлять раскрытой после ухода указателя"), isOn: $keepOpen)
                    Toggle(L10n.tr("settings.collapseOnLeave"), isOn: $collapseOnMouseLeave).disabled(keepOpen)
                    Picker(L10n.tr("Показ завершения"), selection: $revealDwell) { Text(L10n.tr("3 секунды")).tag(3.0); Text(L10n.tr("5 секунд")).tag(5.0); Text(L10n.tr("10 секунд")).tag(10.0) }
                }
            }
            GroupBox(L10n.tr("settings.reminders")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.tr("settings.followupMinutes"), selection: $followupMinutes) {
                        Text(L10n.tr("Никогда")).tag(0)
                        Text(L10n.tr("settings.minutes5")).tag(5)
                        Text(L10n.tr("settings.minutes15")).tag(15)
                        Text(L10n.tr("settings.minutes30")).tag(30)
                    }
                    Toggle(L10n.tr("settings.followupCompleted"), isOn: $followupCompleted).disabled(followupMinutes == 0)
                }
            }
        }.font(.system(size: 13))
    }
    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox(L10n.tr("settings.shortcuts")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("settings.shortcutEnabled"), isOn: $shortcutEnabled)
                    Picker(L10n.tr("settings.shortcutModifier"), selection: $shortcutModifier) {
                        Text(L10n.tr("settings.shortcut.ctrlAlt")).tag("ctrlAlt")
                        Text(L10n.tr("settings.shortcut.ctrlShiftAlt")).tag("ctrlShiftAlt")
                    }.disabled(!shortcutEnabled)
                    Text(L10n.tr("settings.shortcutHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(L10n.tr("settings.panelKeys")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.font(.system(size: 13))
    }
    var companionSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupBox(L10n.tr("companion.title")) {
                Toggle(L10n.tr("Спутник в острове"), isOn: $companion)
            }
            CompanionSettingsView()
            Text(L10n.tr("Спутник реагирует на работу, ожидание, завершение и ошибку. Нажмите на него в раскрытой панели, чтобы поздороваться. Системные «Уменьшение движения» и «Уменьшение прозрачности» учитываются автоматически.")).font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 13))
    }
    var usage: some View { UsageView(usage: model.usage, quota: model.quota, history: model.history) }
    var integrations: some View {
        VStack(alignment: .leading, spacing: 13) {
            if showAgentDiscovery {
                HarnessDiscoveryView(receipts: model.providerReceipts, onConnect: { kind in
                    selectedProvider = kind.rawValue
                    showAgentDiscovery = false
                })
            } else {
                Button { showAgentDiscovery = true } label: {
                    Label(L10n.tr("discovery.title"), systemImage: "chevron.left")
                }.buttonStyle(.plain).foregroundStyle(SettingsPalette.secondary)
            Text(L10n.tr("Подключите локального агента")).font(.system(size: 17, weight: .semibold))
            Text(L10n.tr("agent.setup.intro")).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            HStack(spacing: 8) {
                if let lastEvent = model.providerReceipts[selectedProvider] {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L10n.tr("connection.received"))
                    Spacer()
                    Text(lastEvent, style: .relative).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                    Text(L10n.tr("connection.waiting")).foregroundStyle(.secondary)
                }
            }.font(.system(size: 13)).padding(.vertical, 8)
            if model.providerReceipts[selectedProvider] == nil, selectedProvider == "pi" || selectedProvider == "codex" {
                Text(L10n.tr(selectedProvider == "pi" ? "connection.piReload" : "connection.codexNextTurn"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker(L10n.tr("Агент"), selection: $selectedProvider) {
                Text(L10n.tr("integrations.provider.claude")).tag("claude")
                Text(L10n.tr("integrations.provider.codex")).tag("codex")
                Text(L10n.tr("integrations.provider.pi")).tag("pi")
                Text(L10n.tr("integrations.provider.opencode")).tag("opencode")
                Text(L10n.tr("integrations.provider.hermes")).tag("hermes")
                Text(L10n.tr("integrations.provider.gemini")).tag("gemini")
                Text(L10n.tr("integrations.provider.copilot")).tag("copilot")
                Text(L10n.tr("integrations.provider.cursor")).tag("cursor")
                Text(L10n.tr("Свой агент · JSON")).tag("custom")
            }.pickerStyle(.menu).onChange(of: selectedProvider) { _, _ in copied = false }
            if selectedProvider == "codex" {
                CodexHookSetupView(cliPath: cliPath)
                DisclosureGroup(L10n.tr("settings.codexDiscovery")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L10n.tr("settings.codexAutoDetect"), isOn: $codexAutoDetect)
                        Text(L10n.tr("settings.codexAutoDetectHelp"))
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DisclosureGroup(L10n.tr("Codex CLI · уведомление о завершении хода")) {
                    CodexSetupView(cliPath: cliPath)
                }.font(.system(size: 13))
            } else if selectedProvider == "pi" {
                PiSetupView(cliPath: cliPath)
            } else if let provider = HarnessKind(rawValue: selectedProvider), provider != .custom {
                AgentSetupView(provider: provider, cliPath: cliPath).id(selectedProvider)
            } else {
                Text(L10n.tr("Команды терминала для собственного агента. Один JSON-объект — одно событие. CLI request ждёт явного ответа в чёлке."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(snippet).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                }.frame(height: 225).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                Button(copied ? L10n.tr("Скопировано") : L10n.tr("Скопировать команды")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
            }
            Label(L10n.tr("События и ответы идут по Unix-сокету на этом Mac. Сетевого сервера нет."), systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    var diagnostics: some View {
        VStack(alignment: .leading, spacing: 17) {
            GroupBox(L10n.tr("settings.connection")) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.serverError?.text ?? L10n.tr("Локальный канал работает"),
                          systemImage: model.serverError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.serverError == nil ? .green : .orange)
                    Text(L10n.tr("Unix-сокет")).font(.system(size: 11, weight: .semibold)).foregroundStyle(SettingsPalette.secondary)
                    Text(model.socketPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Divider()
                    Text("CLI").font(.system(size: 11, weight: .semibold)).foregroundStyle(SettingsPalette.secondary)
                    Text(cliPath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }
            GroupBox(L10n.tr("settings.currentActivity")) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(L10n.tr("Получено событий"), value: "\(model.receivedCount)")
                    LabeledContent(L10n.tr("Сессий"), value: "\(model.sessions.count)")
                    LabeledContent(L10n.tr("Ожидающих ответов"), value: "\(model.pending.count)")
                    Divider()
                    HStack {
                        Button(model.paused ? L10n.tr("Возобновить события") : L10n.tr("Пауза событий")) { model.paused.toggle() }
                    }
                }
            }
            GroupBox(L10n.tr("settings.privacy")) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.tr("about.summary"))
                    Text(L10n.tr("settings.privacySessionAndCLI"))
                }.font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary).lineSpacing(3)
            }
        }.font(.system(size: 13))
    }
}
