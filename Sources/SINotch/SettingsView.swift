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
    @AppStorage("compactDetail") var compactDetail = false
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
    var body: some View {
        let _ = appLanguage
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsBrandHeader()
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        sidebarGroup(L10n.tr("settings.sectionMain")) {
                            sidebarItem(L10n.tr("settings.general"), icon: "gearshape.fill", color: .gray, tag: 0)
                            sidebarItem(L10n.tr("Подключение"), icon: "point.3.connected.trianglepath.dotted", color: .cyan, tag: 1)
                            sidebarItem(L10n.tr("settings.notifications"), icon: "bell.fill", color: .red, tag: 6)
                            sidebarItem(L10n.tr("settings.display"), icon: "display", color: .indigo, tag: 5)
                            sidebarItem(L10n.tr("sound.title"), icon: "speaker.wave.2.fill", color: .green, tag: 3)
                            sidebarItem(L10n.tr("settings.usage"), icon: "chart.pie.fill", color: .pink, tag: 8)
                        }
                        sidebarGroup(L10n.tr("settings.sectionAdvanced")) {
                            sidebarItem(L10n.tr("settings.shortcuts"), icon: "keyboard.fill", color: .purple, tag: 7)
                            sidebarItem(L10n.tr("remote.settingsTab"), icon: "network", color: .teal, tag: 10)
                            sidebarItem(L10n.tr("companion.title"), icon: "pawprint.fill", color: .mint, tag: 4)
                            sidebarItem(L10n.tr("Диагностика"), icon: "waveform.path.ecg", color: .orange, tag: 2)
                        }
                        sidebarGroup("si-notch") {
                            sidebarItem(L10n.tr("about.title"), icon: "info.circle.fill", color: .blue, tag: 9)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }.scrollIndicators(.hidden)
                Divider().overlay(SettingsPalette.border).padding(.horizontal, 16)
                Link("Made by dis/root", destination: URL(string: "https://disroot.website/")!)
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsPalette.secondary)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .frame(width: 220)
            .background { SettingsSidebarBackground() }
            Rectangle().fill(SettingsPalette.border).frame(width: 1)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    SettingsIconTile(symbol: tabIcon, color: tabColor, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tabTitle).font(.system(size: 20, weight: .semibold))
                        Text(tabSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsPalette.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(L10n.tr("Готово")) { model.closeSettings?() }.buttonStyle(NotchActionButtonStyle()).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 23).padding(.vertical, 20)
                Rectangle().fill(SettingsPalette.border).frame(height: 1)
                if let error = model.settingsError {
                    Label(error.text, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .padding(.horizontal, 24).padding(.top, 12)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        if tab == 0 { general }
                        else if tab == 5 { display }
                        else if tab == 6 { notifications }
                        else if tab == 7 { shortcuts }
                        else if tab == 8 { usage }
                        else if tab == 1 { integrations }
                        else if tab == 3 { SoundSettingsView() }
                        else if tab == 4 { companionSettings }
                        else if tab == 10 { RemoteSettingsView(manager: model.remoteConnections, localSocketPath: model.socketPath) }
                        else if tab == 9 { SettingsAboutView(model: model) }
                        else { diagnostics }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 23).padding(.vertical, 20)
                }.scrollIndicators(.hidden)
            }.frame(maxWidth: .infinity)
        }
            .frame(width: 820, height: 660)
            .background(SettingsPalette.background)
            .preferredColorScheme(.dark)
            .tint(NotchDesign.accent)
            .toggleStyle(SettingsSwitchStyle())
            .controlSize(.regular)
            .groupBoxStyle(SettingsCardGroupBoxStyle())
            .environment(\.locale, Locale(identifier: L10n.language))
            .onChange(of: tab) { _, _ in onSelectionChange?(tab, selectedProvider) }
            .onChange(of: selectedProvider) { _, _ in onSelectionChange?(tab, selectedProvider) }
    }
    func sidebarGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SettingsPalette.secondary)
                .padding(.horizontal, 9).padding(.bottom, 3)
            content()
        }
    }
    func sidebarItem(_ title: String, icon: String, color: Color, tag: Int) -> some View {
        Button { tab = tag } label: {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: icon, color: color, size: 24)
                Text(title).font(.system(size: 12, weight: tab == tag ? .semibold : .medium))
                Spacer(minLength: 0)
            }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(tab == tag ? SettingsPalette.selected : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tab == tag ? SettingsPalette.border : .clear, lineWidth: 0.8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(tab == tag ? .isSelected : [])
    }
    var tabTitle: String {
        switch tab {
        case 0: return L10n.tr("settings.general")
        case 5: return L10n.tr("settings.display")
        case 6: return L10n.tr("settings.notifications")
        case 7: return L10n.tr("settings.shortcuts")
        case 8: return L10n.tr("settings.usage")
        case 1: return L10n.tr("Подключение агентов")
        case 3: return L10n.tr("sound.title")
        case 4: return L10n.tr("companion.title")
        case 10: return L10n.tr("remote.settingsTab")
        case 9: return L10n.tr("about.title")
        default: return L10n.tr("Диагностика")
        }
    }
    var tabSubtitle: String {
        switch tab {
        case 0: return L10n.tr("settings.subtitleGeneral")
        case 1: return L10n.tr("settings.subtitleIntegrations")
        case 6: return L10n.tr("settings.subtitleNotifications")
        case 5: return L10n.tr("settings.subtitleDisplay")
        case 3: return L10n.tr("settings.subtitleSound")
        case 8: return L10n.tr("settings.subtitleUsage")
        case 7: return L10n.tr("settings.subtitleShortcuts")
        case 4: return L10n.tr("settings.subtitleCompanion")
        case 10: return L10n.tr("settings.subtitleRemote")
        case 9: return L10n.tr("settings.subtitleAbout")
        default: return L10n.tr("settings.subtitleDiagnostics")
        }
    }
    var tabIcon: String {
        switch tab {
        case 0: return "gearshape.fill"
        case 1: return "point.3.connected.trianglepath.dotted"
        case 6: return "bell.fill"
        case 5: return "display"
        case 3: return "speaker.wave.2.fill"
        case 8: return "chart.pie.fill"
        case 7: return "keyboard.fill"
        case 4: return "pawprint.fill"
        case 10: return "network"
        case 9: return "info.circle.fill"
        default: return "waveform.path.ecg"
        }
    }
    var tabColor: Color {
        switch tab {
        case 0: return .gray
        case 1: return .cyan
        case 6: return .red
        case 5: return .indigo
        case 3: return .green
        case 8: return .pink
        case 7: return .purple
        case 4: return .mint
        case 10: return .teal
        case 9: return .blue
        default: return .orange
        }
    }
    var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(L10n.tr("settings.general")) {
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
                    Toggle(L10n.tr("Раскрывать при наведении"), isOn: $hover)
                    HStack { Text(L10n.tr("Задержка наведения")); Slider(value: $hoverDelay, in: 0.02...0.8, step: 0.01); Text(L10n.tr("%.2f с", hoverDelay)).monospacedDigit() }.disabled(!hover).help(L10n.tr("settings.hoverIntentHelp"))
                    Picker(L10n.tr("Считать неактивной через"), selection: $idleMinutes) { Text(L10n.tr("30 минут")).tag(30); Text(L10n.tr("2 часа")).tag(120); Text(L10n.tr("8 часов")).tag(480); Text(L10n.tr("Никогда")).tag(0) }
                    Toggle(L10n.tr("settings.hideWhenIdle"), isOn: $hideWhenIdle)
                    Text(L10n.tr("settings.hideWhenIdleHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle(L10n.tr("settings.disableClickJump"), isOn: $disableClickJump)
                }.padding(10)
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
                }.padding(10)
            }
            HStack {
                Spacer()
                Button(L10n.tr("Выйти из si-notch")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }.font(.system(size: 12))
    }
    var display: some View {
        VStack(alignment: .leading, spacing: 16) {
            IslandPreviewSettingsView()
            GroupBox(L10n.tr("settings.display")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.tr("Расположение"), selection: $displayMode) { Text(L10n.tr("У чёлки / верхней границы")).tag("notch"); Text(L10n.tr("Под строкой меню")).tag("belowMenu") }
                    Picker(L10n.tr("Экран"), selection: $screenID) {
                        Text(L10n.tr("Автоматически (экран с чёлкой)")).tag("auto")
                        ForEach(NSScreen.screens, id: \.self) { screen in Text(screen.localizedName).tag(String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main")) }
                    }
                    Toggle(L10n.tr("При открытии выбирать экран под указателем"), isOn: $followFocus)
                    Toggle(L10n.tr("settings.hideInFullScreen"), isOn: $hideInFullScreen)
                    HStack { Text(L10n.tr("Ширина")); Slider(value: $width, in: 380...720, step: 10); Text("\(Int(width))").monospacedDigit().frame(width: 35) }
                    HStack { Text(L10n.tr("Высота")); Slider(value: $height, in: 360...800, step: 10); Text("\(Int(height))").monospacedDigit().frame(width: 35) }
                    HStack { Text(L10n.tr("settings.fontSize")); Slider(value: $fontSize, in: 10...16, step: 1); Text(L10n.tr("settings.points", Int(fontSize))).monospacedDigit().frame(width: 48) }
                    Toggle(L10n.tr("Название задачи в свёрнутом острове"), isOn: $compactDetail)
                }.padding(10)
            }
            GroupBox(L10n.tr("settings.cardDetails")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("settings.showModel"), isOn: $showModel)
                    Toggle(L10n.tr("settings.showReasoning"), isOn: $showReasoning)
                    Toggle(L10n.tr("settings.showProject"), isOn: $showProject)
                    Toggle(L10n.tr("settings.showTasks"), isOn: $showTasks)
                    Toggle(L10n.tr("settings.showSubagents"), isOn: $showSubagents)
                    Toggle(L10n.tr("settings.showActivity"), isOn: $showActivity)
                }.padding(10)
            }
        }.font(.system(size: 12))
    }
    var notifications: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(L10n.tr("settings.notifications")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("Тихий режим: без звуков и автоматического раскрытия"), isOn: $quiet)
                    Toggle(L10n.tr("Раскрывать при завершении, вопросе или ошибке"), isOn: $autoExpand).disabled(quiet)
                    Toggle(L10n.tr("settings.completionReveal"), isOn: $completionReveal).disabled(quiet || !autoExpand)
                    Toggle(L10n.tr("settings.attentionReveal"), isOn: $attentionReveal).disabled(quiet || !autoExpand)
                    Toggle(L10n.tr("settings.suppressTargetFrontmost"), isOn: $suppressWhenTargetAppFrontmost).disabled(!autoExpand)
                    Text(L10n.tr("settings.suppressTargetHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle(L10n.tr("settings.dismissOutside"), isOn: $dismissAutoRevealOnOutsideClick)
                    Toggle(L10n.tr("Оставлять раскрытой после ухода указателя"), isOn: $keepOpen)
                    Toggle(L10n.tr("settings.collapseOnLeave"), isOn: $collapseOnMouseLeave).disabled(keepOpen)
                    Picker(L10n.tr("Показ завершения"), selection: $revealDwell) { Text(L10n.tr("3 секунды")).tag(3.0); Text(L10n.tr("5 секунд")).tag(5.0); Text(L10n.tr("10 секунд")).tag(10.0) }
                    Picker(L10n.tr("settings.followupMinutes"), selection: $followupMinutes) {
                        Text(L10n.tr("Никогда")).tag(0)
                        Text(L10n.tr("settings.minutes5")).tag(5)
                        Text(L10n.tr("settings.minutes15")).tag(15)
                        Text(L10n.tr("settings.minutes30")).tag(30)
                    }
                    Toggle(L10n.tr("settings.followupCompleted"), isOn: $followupCompleted).disabled(followupMinutes == 0)
                }.padding(10)
            }
        }.font(.system(size: 12))
    }
    var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(L10n.tr("settings.shortcuts")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.tr("settings.shortcutEnabled"), isOn: $shortcutEnabled)
                    Picker(L10n.tr("settings.shortcutModifier"), selection: $shortcutModifier) {
                        Text(L10n.tr("settings.shortcut.ctrlAlt")).tag("ctrlAlt")
                        Text(L10n.tr("settings.shortcut.ctrlShiftAlt")).tag("ctrlShiftAlt")
                    }.disabled(!shortcutEnabled)
                    Text(L10n.tr("settings.shortcutHelp")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(L10n.tr("settings.panelKeys")).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(10)
            }
        }.font(.system(size: 12))
    }
    var companionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(L10n.tr("companion.title")) {
                Toggle(L10n.tr("Спутник в острове"), isOn: $companion).padding(10)
            }
            CompanionSettingsView()
            Text(L10n.tr("Спутник реагирует на работу, ожидание, завершение и ошибку. Нажмите на него в раскрытой панели, чтобы поздороваться. Системные «Уменьшение движения» и «Уменьшение прозрачности» учитываются автоматически.")).font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    var usage: some View {
        VStack(alignment: .leading, spacing: 14) {
            CodexUsageView()
            Text(L10n.tr("settings.usageScope")).font(.system(size: 11)).foregroundStyle(.secondary)
            let observed = model.sessions.filter { $0.usage != nil }
            if observed.isEmpty {
                GroupBox(L10n.tr("settings.usage")) {
                    VStack(spacing: 9) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(SettingsPalette.secondary)
                        Text(L10n.tr("settings.noUsage"))
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsPalette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                }
            } else {
                ForEach(observed) { session in
                    if let usage = session.usage {
                        GroupBox("\(session.provider) · \(model.displayTitle(session))") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let input = usage.inputTokens { usageRow("settings.inputTokens", input) }
                                if let output = usage.outputTokens { usageRow("settings.outputTokens", output) }
                                if let context = usage.contextTokens { usageRow("settings.contextTokens", context) }
                                if let window = usage.contextWindow { usageRow("settings.contextWindow", window) }
                                if let percent = usage.usedPercent { HStack { Text(L10n.tr("settings.contextUsed")); Spacer(); Text(percent / 100, format: .percent.precision(.fractionLength(1))) } }
                                if let secondary = usage.secondaryUsedPercent { HStack { Text(L10n.tr("settings.secondaryUsed")); Spacer(); Text(secondary / 100, format: .percent.precision(.fractionLength(1))) } }
                                if let cost = usage.costUSD { HStack { Text(L10n.tr("settings.agentReportedCost")); Spacer(); Text(cost, format: .currency(code: "USD")) } }
                            }.padding(10)
                        }
                    }
                }
            }
        }.font(.system(size: 12))
    }
    func usageRow(_ key: String, _ value: Int) -> some View {
        HStack { Text(L10n.tr(key)); Spacer(); Text(value, format: .number) }
    }
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
            }.font(.system(size: 12)).padding(.vertical, 8)
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
                }.font(.system(size: 12))
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
        }.font(.system(size: 12))
    }
}
