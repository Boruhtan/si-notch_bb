import SwiftUI
import AppKit
import SINotchCore

private struct SessionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension AgentStatus {
    var label: String {
        switch self { case .idle: return L10n.tr("На связи"); case .working: return L10n.tr("В работе"); case .waiting: return L10n.tr("Ждёт ответа"); case .approval: return L10n.tr("Нужно разрешение"); case .completed: return L10n.tr("Готово"); case .failed: return L10n.tr("Ошибка"); case .ended: return L10n.tr("Завершена") }
    }
    var tint: Color {
        switch self { case .working: return Color(red: 0.40, green: 0.89, blue: 0.56); case .approval, .waiting: return .orange; case .failed: return Color(red: 1, green: 0.47, blue: 0.43); case .completed: return Color(red: 0.48, green: 0.79, blue: 1); default: return .gray }
    }
    var symbol: String {
        switch self { case .idle: return "circle.dotted"; case .working: return "waveform"; case .waiting: return "bubble.left"; case .approval: return "hand.raised"; case .completed: return "checkmark"; case .failed: return "exclamationmark.triangle"; case .ended: return "stop" }
    }
}

struct IslandView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appLanguage") var appLanguage = "auto"
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @AppStorage("showCompanion") var showCompanion = true
    @AppStorage("shortcutModifier") var shortcutModifier = "ctrlAlt"
    @AppStorage("shortcutEnabled") var shortcutEnabled = true
    var shortcutLabel: String { shortcutEnabled ? L10n.tr(shortcutModifier == "ctrlShiftAlt" ? "settings.shortcut.ctrlShiftAlt" : "settings.shortcut.ctrlAlt") : "" }
    var body: some View {
        let _ = appLanguage
        GeometryReader { viewport in
            let compactHeight = model.compactHeight
            let compactWidth = model.cameraWidth + model.compactWingWidth + model.compactStatusWidth + 2 * model.compactShoulderWidth
            let expansion = Self.revealProgress(viewport: viewport.size, compactWidth: compactWidth,
                                                expandedWidth: model.expandedPanelWidth)
            let droplet = reduceMotion ? 0 : sin(expansion * .pi)
            let reveal = min(1, max(0, (expansion - 0.12) / 0.60))
            let contentOpacity = reveal * reveal * (3 - 2 * reveal)
            ZStack(alignment: model.trailingSurface ? .topTrailing : .top) {
                // The native frame includes one point of top bleed. Do not keep
                // the expanded hierarchy alive for that compact-only pixel.
                if model.expanded || viewport.size.height > compactHeight + 1.5 {
                    // Lay out the content once at its destination width. The native
                    // window reveals it; shrinking text during the transition causes
                    // line wrapping and makes the header visibly jump.
                    expandedContent
                        .frame(width: model.expandedPanelWidth, height: model.expandedPanelHeight, alignment: .top)
                        .opacity(contentOpacity)
                        .allowsHitTesting(model.expanded)
                        .accessibilityHidden(!model.expanded)
                }
                if !model.expanded || expansion < 0.72 {
                    compactContent.frame(width: compactWidth, height: compactHeight)
                        .opacity(1 - contentOpacity)
                        .allowsHitTesting(!model.expanded)
                        .accessibilityHidden(model.expanded)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
            .clipped()
            .foregroundStyle(.white)
            .background(IslandAppearanceSurface())
            .overlay(alignment: .bottom) { if model.paused { Rectangle().fill(.orange).frame(height: 2) } }
            // The silhouette follows the same live geometry as the window.
            // Switching these radii with the boolean state caused a corner pop
            // before the first animation frame and again on fast reversal.
            .clipShape(IslandSilhouette(shoulder: model.compactShoulderWidth + (14 - model.compactShoulderWidth) * expansion,
                                       bottomRadius: model.floatingSurface ? 15 + 9 * expansion : 13 + 11 * expansion + 6 * droplet,
                                       droplet: droplet * 0.5, floating: model.floatingSurface))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: L10n.language))
        .onExitCommand { model.setExpanded(false) }
        .onMoveCommand { direction in
            if direction == .down { model.moveSelection(1) }
            else if direction == .up { model.moveSelection(-1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("si-notch, %@", L10n.count("sessions", model.sessions.count)))
    }

    static func revealProgress(viewport: CGSize, compactWidth: CGFloat, expandedWidth: CGFloat) -> CGFloat {
        // Width tracks compact ↔ expanded motion. Height also changes while an
        // already open group/card resizes; using it would reopen the outline and
        // fade the content every time the destination height changes.
        min(1, max(0, (viewport.width - compactWidth) / max(1, expandedWidth - compactWidth)))
    }

    var compactContent: some View {
        let requests = model.attentionQueue.requests.count
        let count = requests > 0 ? requests : model.sessions.count
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if model.paused {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                } else if showCompanion {
                    CompanionView(status: model.dominantStatus, size: 20, interactive: false).allowsHitTesting(false)
                } else {
                    Image(systemName: model.dominantStatus.symbol).foregroundStyle(model.dominantStatus.tint)
                }
            }.padding(.horizontal, 3).frame(width: model.compactWingWidth)
            Color.clear.frame(width: model.cameraWidth)
            Group {
                if count == 0 { Circle().fill(model.dominantStatus.tint).frame(width: 5, height: 5) }
                else {
                    Text(count > 99 ? "99+" : "\(count)")
                        .monospacedDigit().font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(requests > 0 ? .orange : model.dominantStatus.tint).lineLimit(1).minimumScaleFactor(0.8)
                }
            }.frame(width: model.compactStatusWidth)
        }
        .padding(.horizontal, model.compactShoulderWidth)
        .font(.system(size: 11))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(true) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Открыть si-notch, %@, %@", L10n.count("sessions", model.sessions.count), model.dominantStatus.label))
        .accessibilityHint(requests > 0 ? L10n.tr("Внимание") + " · \(requests)" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.setExpanded(true) }
        .help(shortcutLabel)
    }

    var expandedContent: some View {
        VStack(spacing: 0) {
            HStack {
                if model.showAgents {
                    Text(L10n.tr("agents.title")).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchDesign.secondary)
                } else if model.showingAttention {
                    Text(L10n.tr("Внимание")).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchDesign.secondary)
                } else if !model.sessions.isEmpty {
                    HStack(spacing: 6) {
                        if showCompanion { CompanionView(status: model.dominantStatus, size: 22) }
                        Text(model.paused ? L10n.tr("Приём событий на паузе") : L10n.count("sessions", model.sessions.count))
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }.foregroundStyle(NotchDesign.secondary)
                }
                Spacer(minLength: model.cameraWidth)
                Button { model.openUsage?(nil) } label: { Image(systemName: "chart.bar").font(.system(size: 12)) }
                    .buttonStyle(IslandGlassButtonStyle()).controlSize(.small).help(L10n.tr("settings.usage")).accessibilityLabel(L10n.tr("settings.usage"))
                Button { model.openSettings?() } label: { Image(systemName: "gearshape").font(.system(size: 12)) }.buttonStyle(IslandGlassButtonStyle()).controlSize(.small).help(L10n.tr("Настройки")).accessibilityLabel(L10n.tr("Настройки"))
                Button { model.setExpanded(false) } label: { Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold)) }.buttonStyle(IslandGlassButtonStyle()).controlSize(.small).padding(.leading, 4).help(L10n.tr("Свернуть")).accessibilityLabel(L10n.tr("Свернуть панель"))
            }
            .frame(height: model.headerHeight).padding(.horizontal, 20)
            // Navigation stays at the top while either tab adapts its height.
            navigation
            if let error = model.serverError {
                Label(error.text, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 22).padding(.bottom, 10)
            }
            VStack(spacing: 0) {
                if model.showAgents { agentsList }
                else if model.showingAttention { AttentionQueueView(model: model) }
                else {
                    if !model.showingHistory && (model.sessions.count > 3 || !model.search.isEmpty) {
                        TextField(L10n.tr("Поиск сессий"), text: $model.search).textFieldStyle(.plain).font(.system(size: 12)).padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 20).padding(.bottom, 10)
                    }
                    HStack(spacing: 5) {
                        ForEach(["Все", "В работе", "Готово", "history.title"], id: \.self) { filter in
                            Button { model.activeFilter = filter } label: {
                                Text(L10n.tr(filter)).font(.system(size: 10, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(model.activeFilter == filter ? .white.opacity(0.14) : .clear, in: Capsule())
                                    .foregroundStyle(model.activeFilter == filter ? .white : NotchDesign.secondary)
                            }.buttonStyle(.plain).accessibilityAddTraits(model.activeFilter == filter ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.bottom, 10)
                    if model.showingHistory { HistoryView(history: model.history, usage: model.usage, openUsage: { model.openUsage?($0) }) }
                    else if model.sessions.isEmpty { emptyState }
                    else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.filtered) { session in
                                    SessionCard(session: session, model: model)
                                        .background(GeometryReader { geometry in
                                            Color.clear.preference(key: SessionHeightPreferenceKey.self,
                                                value: [session.id: geometry.size.height])
                                        })
                                }
                                if model.filtered.isEmpty { Text(L10n.tr("Здесь пока нет сессий")).font(.system(size: 12)).foregroundStyle(.secondary).padding(30) }
                            }.padding(.horizontal, 16).padding(.bottom, 14)
                        }.scrollIndicators(.hidden)
                        .id(model.activeFilter + "\0" + model.search)
                        .onPreferenceChange(SessionHeightPreferenceKey.self) { model.measureSessionCards($0) }
                    }
                    if !model.showingHistory && (model.quiet || model.sessions.contains(where: { $0.status == .completed || $0.status == .failed })) {
                        HStack(spacing: 6) {
                            if model.quiet { Label(L10n.tr("Тихий режим"), systemImage: "moon.fill").font(.system(size: 10)) }
                            Spacer()
                            if model.sessions.contains(where: { $0.status == .completed || $0.status == .failed }) {
                                Button { model.clearFinished() } label: { Text(L10n.tr("Убрать готовые")).font(.system(size: 11)) }.buttonStyle(.plain)
                            }
                        }.foregroundStyle(NotchDesign.muted).padding(.horizontal, 22).padding(.bottom, 12)
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }
    var navigation: some View {
        let attentionCount = model.attentionQueue.count
        return VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 20)
            HStack(spacing: 4) {
                navigationTab(title: L10n.tr("agents.sessions"), symbol: "list.bullet", id: "sessions",
                              selected: !model.showAgents && !model.showingAttention) { model.selectAgents(false) }
                navigationTab(title: L10n.tr("Внимание"), symbol: "bell", id: "attention", selected: model.showingAttention,
                              badge: attentionCount > 0 ? "\(attentionCount)" : nil, badgeColor: .orange) { model.selectAttention() }
                navigationTab(title: L10n.tr("agents.title"), symbol: "terminal", id: "agents", selected: model.showAgents,
                              badge: L10n.tr("agents.onlineCount", model.agents.filter { $0.state == .online }.count),
                              badgeHelp: L10n.tr("agents.presenceHelp")) { model.selectAgents(true) }
            }.padding(.horizontal, 16).frame(height: 39)
        }
    }
    private func navigationTab(title: String, symbol: String, id: String, selected: Bool, badge: String? = nil,
                               badgeColor: Color = NotchDesign.muted, badgeHelp: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).lineLimit(1).layoutPriority(1)
                if let badge {
                    Text(badge).font(.system(size: 10, design: .monospaced)).foregroundStyle(badgeColor)
                        .lineLimit(1).minimumScaleFactor(0.75).help(badgeHelp)
                }
            }.font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 27)
                .foregroundStyle(selected ? .white : NotchDesign.secondary)
                .background(selected ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("island-tab-" + id)
    }
    var agentsList: some View {
        VStack(spacing: 0) {
            if model.agentPanelOverflows {
                ScrollView { agentGroups }
            } else {
                agentGroups
            }
            Button { model.openIntegrations?() } label: {
                Text(L10n.tr("agents.manage")).font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).frame(height: 36)
            }.buttonStyle(.plain).foregroundStyle(NotchDesign.secondary)
        }.padding(.vertical, 8)
    }
    var agentGroups: some View {
        let details = model.agentSessionsByProfile
        let counts = model.agentGroupCounts
        return VStack(spacing: 0) {
            agentRows(model.ungroupedLocalAgents, details: details).padding(.horizontal, 24)
            if let group = model.localHermesGroup {
                agentGroup(.localHermes, name: group.name, symbol: "desktopcomputer", counts: counts[.localHermes],
                           expanded: model.localHermesGroupExpanded, setExpanded: model.setLocalHermesGroupExpanded) {
                    agentRows(group.profiles, details: details)
                } status: {
                    HStack(spacing: 8) {
                        Text(L10n.tr("agents.localGroup")).foregroundStyle(NotchDesign.secondary)
                        Text(L10n.tr("agents.localGroup.online", group.onlineCount, group.profiles.count))
                            .foregroundStyle(NotchDesign.secondary)
                        Circle().fill(group.onlineCount > 0 ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityIdentifier("agent-group-" + LocalHermesAgentGroup.id)
            }
            ForEach(model.applicationAgentGroups, id: \.host) { group in
                let id = AgentGroupID.application(group.host)
                agentGroup(id, name: group.host.name, symbol: group.host == .rex ? "terminal" : "curlybraces",
                           counts: counts[id], expanded: model.applicationGroupExpanded(group.host),
                           setExpanded: { model.setApplicationGroupExpanded(group.host, $0) }) {
                    VStack(spacing: 0) {
                        agentGrid(group.sessions.map { AgentPanelSession(session: $0) }, row: agentSession)
                        if group.sessions.isEmpty {
                            Text(L10n.tr(group.host == .zed ? "agents.hostEmpty.zed" : "agents.hostEmpty.rex"))
                                .font(.system(size: 11)).foregroundStyle(NotchDesign.secondary).frame(height: 32)
                        }
                    }
                } status: {
                    Text(L10n.tr("agents.hostTasks", group.sessions.count)).foregroundStyle(NotchDesign.secondary)
                }
                .accessibilityIdentifier("agent-host-" + group.host.rawValue)
            }
            ForEach(model.remoteConnections.connections.filter(\.showInAgents)) { connection in
                let profiles = model.agents.filter { $0.connectorID == connection.id }
                let id = AgentGroupID.remote(connection.id)
                agentGroup(id, name: connection.displayName, symbol: "network", counts: counts[id],
                           expanded: model.connectorExpanded(connection.id),
                           setExpanded: { model.setConnectorExpanded(connection.id, $0) }) {
                    VStack(spacing: 0) {
                        agentRows(profiles, details: details)
                        if profiles.isEmpty {
                            Text(L10n.tr("remote.noProfiles")).font(.system(size: 11))
                                .foregroundStyle(NotchDesign.secondary).frame(height: 32)
                        }
                    }
                } status: {
                    HStack(spacing: 8) {
                        Text(L10n.tr("remote.sshState", model.remoteConnections.state(connection.id).label))
                            .foregroundStyle(NotchDesign.secondary)
                        Text("\(profiles.count)").foregroundStyle(NotchDesign.secondary)
                        Button { model.openRemoteConnections?() } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).help(L10n.tr("remote.settingsTab"))
                        Circle().fill(model.remoteConnections.state(connection.id) == .connected ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityIdentifier("agent-connection-" + connection.id.uuidString)
            }
            if model.agents.isEmpty && model.applicationAgentGroups.isEmpty && !model.remoteConnections.connections.contains(where: \.showInAgents) {
                Text(L10n.tr("agents.empty")).font(.system(size: 12)).foregroundStyle(NotchDesign.secondary).frame(height: 56)
            }
        }
    }

    private func agentGroup<Content: View, Status: View>(
        _ id: AgentGroupID, name: String, symbol: String, counts: AgentGroupCounts?, expanded: Bool,
        setExpanded: @escaping (Bool) -> Void, @ViewBuilder content: () -> Content, @ViewBuilder status: () -> Status
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { setExpanded(!expanded) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchDesign.secondary).frame(width: 9)
                        Image(systemName: symbol).frame(width: 16)
                        Text(name).fontWeight(.medium).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: AgentPanelLayout.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityValue(L10n.tr(expanded ? "agents.expanded" : "agents.collapsed"))
                .accessibilityIdentifier("group-toggle-" + id.key)
                if !expanded, let counts {
                    ViewThatFits(in: .horizontal) {
                        groupCounters(counts, for: id, compact: false).fixedSize()
                        groupCounters(counts, for: id, compact: true).fixedSize()
                    }
                    .layoutPriority(1)
                }
                status().lineLimit(1)
            }
            .font(.system(size: 11))
            .frame(height: AgentPanelLayout.rowHeight)
            if expanded { content().padding(.leading, 12) }
        }
        .padding(.horizontal, 24).tint(NotchDesign.secondary)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .accessibilityElement(children: .contain)
    }

    private func groupCounters(_ counts: AgentGroupCounts, for id: AgentGroupID, compact: Bool) -> some View {
        HStack(spacing: 8) {
            if counts.waiting > 0 {
                Button { model.selectAttention(group: id) } label: {
                    counterLabel("agents.group.waiting", count: counts.waiting, symbol: "bubble.left", compact: compact)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("agents.group.openAttention", model.groupName(id)))
                .accessibilityLabel(L10n.tr("agents.group.waiting", counts.waiting))
                .accessibilityIdentifier("group-attention-" + id.key)
            }
            if counts.working > 0 {
                counterLabel("agents.group.working", count: counts.working, symbol: "waveform", compact: compact)
                    .foregroundStyle(AgentStatus.working.tint)
            }
            if counts.completed > 0 {
                counterLabel("agents.group.completed", count: counts.completed, symbol: "checkmark", compact: compact)
                    .foregroundStyle(NotchDesign.secondary)
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
    }

    private func counterLabel(_ key: String, count: Int, symbol: String, compact: Bool) -> some View {
        let title = L10n.tr(key, count)
        return Group {
            if compact { Label("\(count)", systemImage: symbol) }
            else { Text(title) }
        }.accessibilityLabel(title).help(title)
    }
    private func agentRows(_ agents: [AgentConnection], details: [String: [AgentSession]]) -> some View {
        let sessions = agents.flatMap { agent in
            (details[agent.id] ?? []).map { AgentPanelSession(session: $0, profileName: agent.name) }
        }
        return VStack(spacing: 0) {
            agentGrid(agents) { agentRow($0, compact: min(agents.count, model.agentPanelColumns) > 1) }
            agentGrid(sessions, row: agentSession)
        }
    }
    @ViewBuilder private func agentGrid<Item: Identifiable, Row: View>(_ items: [Item], row: @escaping (Item) -> Row) -> some View {
        let count = min(items.count, model.agentPanelColumns)
        if count <= 1 {
            VStack(spacing: 0) { ForEach(items, content: row) }
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: AgentPanelLayout.columnSpacing, alignment: .topLeading),
                                count: count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(items, content: row)
            }
        }
    }
    private func agentSession(_ item: AgentPanelSession) -> some View {
        let session = item.session
        let title = model.displayTitle(session)
        let label = item.profileName.flatMap { $0 == title ? nil : $0 + " · " + title } ?? title
        let style = ProviderStyle(provider: session.provider)
        return VStack(spacing: 0) {
            Button { model.showAgentSession(session.id) } label: {
                agentSessionLine(label, symbol: style.symbol, symbolColor: style.color, status: session.status)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(label).accessibilityIdentifier("agent-session-" + session.id)
            ForEach(session.tasks) { task in
                agentSessionLine(task.title, symbol: "checklist", symbolColor: NotchDesign.secondary, status: task.status)
                    .padding(.leading, 16)
            }
            ForEach(session.subagents) { child in
                agentSessionLine(child.name, symbol: "arrow.turn.down.right", symbolColor: NotchDesign.secondary, status: child.status)
                    .padding(.leading, 16)
            }
        }
    }
    private func agentSessionLine(_ title: String, symbol: String, symbolColor: Color, status: AgentStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(symbolColor).frame(width: 16)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(status.label).lineLimit(1).layoutPriority(1)
                .foregroundStyle(status.isActive ? status.tint : NotchDesign.secondary)
        }.font(.system(size: 11)).frame(height: AgentPanelLayout.rowHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + " · " + status.label)
    }
    private func agentRow(_ agent: AgentConnection, compact: Bool) -> some View {
        let style = ProviderStyle(provider: agent.provider)
        let presence = Circle().fill(agent.state == .online ? Color.green : Color.gray.opacity(0.5)).frame(width: 5, height: 5)
        let activity = HStack(spacing: 4) {
            Text(agent.activity.label).lineLimit(1)
                .foregroundStyle(agent.activity == .attention ? .orange : agent.activity == .working ? .green : NotchDesign.secondary)
            if agent.activeTaskCount > 1 { Text("\(agent.activeTaskCount)").foregroundStyle(NotchDesign.secondary) }
        }
        let label = [agent.name, agent.state.label, agent.activity.label].joined(separator: " · ")
        return HStack(spacing: 8) {
            Image(systemName: style.symbol).foregroundStyle(style.color).frame(width: 16)
            if compact {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        presence
                        Text(agent.name).fontWeight(.medium).lineLimit(1)
                    }
                    activity.font(.system(size: 10))
                }
                Spacer(minLength: 0)
            } else {
                Text(agent.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                presence
                Text(agent.state.label).foregroundStyle(NotchDesign.secondary)
                Text("·").foregroundStyle(NotchDesign.muted)
                activity
            }
        }.font(.system(size: 11)).frame(height: AgentPanelLayout.rowHeight)
            .help(label).accessibilityElement(children: .ignore).accessibilityLabel(label)
            .accessibilityIdentifier("agent-profile-" + agent.id)
    }
    var emptyState: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center, spacing: 15) {
                if showCompanion { CompanionView(status: .idle, size: 58) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("Всё спокойно")).font(.system(size: 18, weight: .semibold))
                    Text(L10n.tr(model.agents.contains { $0.state == .online } ? "empty.ready" : "empty.description")).font(.system(size: 12)).foregroundStyle(NotchDesign.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 9) {
                if !model.agents.contains(where: { $0.state == .online }) {
                    Button { model.openIntegrations?() } label: { Label(L10n.tr("Подключить агента"), systemImage: "plus") }.buttonStyle(NotchActionButtonStyle(prominent: true))
                }
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SessionCard: View {
    let session: AgentSession
    @ObservedObject var model: AppModel
    var attention: AttentionSessionItem? = nil
    @AppStorage("appLanguage") var appLanguage = "auto"
    @State private var promptExpanded = false
    @AppStorage("fontSize") var fontSize = 11.0
    @AppStorage("showModel") var showModel = true
    @AppStorage("showReasoning") var showReasoning = true
    @AppStorage("showProject") var showProject = true
    @AppStorage("showTasks") var showTasks = true
    @AppStorage("showSubagents") var showSubagents = true
    @AppStorage("showActivity") var showActivity = true
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var selected: Bool { model.selectedID == session.id || (attention == nil && model.pending[session.id] != nil) }
    var needsAgentResponse: Bool {
        [.waiting, .approval].contains(session.status) && session.lastEventID?.hasPrefix("interaction-submitted:") != true
    }
    var providerStyle: ProviderStyle { ProviderStyle(provider: session.provider.lowercased() == "codex" && session.isWorkSession == true ? "work" : session.provider) }
    var content: SessionCardContent {
        SessionCardContent(session: session, displayTitle: model.displayTitle(session),
                           displayMessage: session.lastMessage.map { model.displayMessage(session, $0) }, statusLabel: session.status.label)
    }
    var body: some View {
        let _ = appLanguage
        let info = content
        let route = model.navigationAction(for: session)
        let requests = model.interactions(for: session.id)
        let externalResponse = requests.isEmpty && model.pending[session.id] == nil && needsAgentResponse
        let showNavigation = attention != nil || !requests.isEmpty || externalResponse || selected
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Button { activateCard(route) } label: {
                    HStack(alignment: .top, spacing: 11) {
                        Circle().fill(session.status.tint).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(info.primaryTitle).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.94))
                                .lineLimit(selected ? 3 : 2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Label(profileLabel(info.providerName), systemImage: providerStyle.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(providerStyle.color).lineLimit(1)
                                if showProject || attention != nil, let project = info.projectName, !info.projectIsTitle {
                                    Text("·").foregroundStyle(NotchDesign.muted)
                                    Label(project, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                                }
                                if let attention {
                                    Text("·").foregroundStyle(NotchDesign.muted)
                                    Label(attention.machineName, systemImage: "desktopcomputer").lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if attention == nil {
                                    Text(session.updatedAt, style: .relative).font(.system(size: 9)).lineLimit(1).foregroundStyle(NotchDesign.muted)
                                }
                            }.font(.system(size: 10)).foregroundStyle(NotchDesign.secondary)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(cardActionLabel(info, route: route))
                    .accessibilityIdentifier("open-session-" + session.id)
                    .help(attention == nil ? (route.title ?? route.notice ?? "") : "")
                Button {
                    model.selectSession(selected ? nil : session.id)
                } label: {
                    Image(systemName: selected ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(NotchDesign.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("%@, %@, %@. Подробнее", info.providerName, info.primaryTitle, session.status.label))
                    .accessibilityIdentifier("session-details-" + session.id)
            }
            HStack(spacing: 6) {
                ZStack {
                    if session.status == .working { PixelTerminalIndicator(color: providerStyle.color).transition(.opacity) }
                    else { Image(systemName: session.status.symbol).font(.system(size: 10, weight: .medium)).transition(.opacity) }
                }.frame(width: 14, height: 15).animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.status)
                Text(session.status.label).font(.system(size: 10, weight: .medium)).contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.status)
                if info.isMemoryService {
                    Label(L10n.tr("session.serviceMemory"), systemImage: "brain")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(NotchDesign.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.07), in: Capsule())
                        .help(L10n.tr("session.serviceMemoryHelp"))
                }
                if showActivity, let tool = info.tool {
                    Text("·").foregroundStyle(NotchDesign.muted)
                    Label(tool, systemImage: info.toolSymbol).font(.system(size: 10, design: .monospaced))
                        .lineLimit(1).foregroundStyle(NotchDesign.secondary)
                }
                Spacer()
                if let since = attention?.waitingSince {
                    HStack(spacing: 4) {
                        Text(L10n.tr("attention.waitingSince"))
                        Text(since, style: .timer).monospacedDigit()
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(1)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("attention-wait-time-" + session.id)
                }
                if showTasks, !session.tasks.isEmpty {
                    Label("\(session.tasks.filter(\.completed).count)/\(session.tasks.count)", systemImage: "checklist")
                        .font(.system(size: 9)).foregroundStyle(NotchDesign.secondary)
                }
                if showSubagents, !session.subagents.isEmpty { Label("\(session.subagents.count)", systemImage: "person.2").font(.system(size: 9)).foregroundStyle(NotchDesign.secondary) }
            }.foregroundStyle(session.status.tint)
                .contentShape(Rectangle()).onTapGesture { activateCard(route) }
            if (showModel && info.modelName != nil) || (showReasoning && info.reasoningEffort != nil) {
                HStack(spacing: 10) {
                    if showModel, let name = info.modelName { Label(name, systemImage: "cpu").help(name) }
                    if showReasoning, let effort = info.reasoningEffort { Label(effort, systemImage: "brain").help(effort) }
                }.font(.system(size: max(10, min(16, fontSize)) - 1))
                    .foregroundStyle(NotchDesign.secondary).lineLimit(1).truncationMode(.middle)
            }
            if !selected, showActivity, let summary = info.summary, model.pending[session.id] == nil {
                Text(summary).font(.system(size: max(10, min(16, fontSize)))).foregroundStyle(NotchDesign.secondary)
                    .lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture { activateCard(route) }
            }
            if model.navigationErrorID == session.id {
                Label(L10n.tr(model.navigationNoticeKey ?? "session.openFailed"), systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !requests.isEmpty {
                ForEach(requests) { request in
                    AgentInteractionView(model: model, request: request, providerName: info.providerName)
                }
            } else if externalResponse && attention == nil {
                Text(L10n.tr(session.status == .approval ? "interaction.approvalInAgent" : "interaction.answerInAgent", info.providerName))
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if showNavigation {
                navigationControl(route, prominent: externalResponse)
            }
            if selected {
                let tokenRow = model.usage.task(session: UsageSession.key(provider: session.provider, connection: session.connectionID, session: session.id), turn: session.turnID)
                Button { model.openUsage?(tokenRow?.id ?? UsageSession.key(provider: session.provider, connection: session.connectionID, session: session.id)) } label: {
                    HStack {
                        Label(L10n.tr("task.tokens"), systemImage: "chart.bar")
                        Spacer()
                        Text(tokenRow?.counts.map { TokenFormat.compact($0.total) } ?? "—").monospacedDigit()
                        if tokenRow?.partial == true { Image(systemName: "info.circle").help(L10n.tr("tokens.partial")) }
                        Image(systemName: "chevron.right")
                    }.font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
                        .padding(9).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("session-usage-" + session.id)
                if showActivity, let message = info.message, model.pending[session.id] == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr(session.status == .completed || session.status == .failed ? "session.lastResult" : "session.latestUpdate"))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(NotchDesign.muted)
                        Text(message).font(.system(size: max(10, min(16, fontSize)))).foregroundStyle(NotchDesign.secondary)
                            .lineSpacing(3).lineLimit(5).textSelection(.enabled)
                    }.padding(.top, 2)
                }
                if let prompt = info.taskPrompt {
                    DisclosureGroup(isExpanded: $promptExpanded) {
                        Text(prompt).font(.system(size: max(10, min(16, fontSize)))).foregroundStyle(NotchDesign.secondary)
                            .lineSpacing(3).lineLimit(6).textSelection(.enabled)
                    } label: {
                        Text(L10n.tr("session.task")).font(.system(size: 10, weight: .medium)).foregroundStyle(NotchDesign.muted)
                    }.tint(NotchDesign.muted).padding(.top, 2)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                }
                if showTasks, !session.tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.tasks.prefix(12), id: \.id) { task in Label(task.title, systemImage: task.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 10)).foregroundStyle(task.completed ? session.status.tint : .white.opacity(0.5)).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.top, 2)
                }
                if showSubagents, !session.subagents.isEmpty {
                    ForEach(session.subagents.prefix(12), id: \.id) { child in HStack { Image(systemName: "arrow.turn.down.right"); Text(child.name).lineLimit(2); Spacer(); Text(child.status.label).foregroundStyle(child.status.tint).lineLimit(1) }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
                }
                if showActivity, let history = model.activity[session.id], history.count > 1 {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.tr("session.activity.title")).font(.system(size: 10, weight: .medium)).foregroundStyle(NotchDesign.muted)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(history.reversed()) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(item.timestamp, style: .time).foregroundStyle(NotchDesign.muted).frame(width: 58, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.label).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                                            if let message = item.message, info.message?.hasPrefix(message) != true {
                                                Text(message).foregroundStyle(NotchDesign.secondary).lineLimit(3)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.system(size: 10, design: .monospaced))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 120)
                    }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
                if showProject, let path = session.projectPath {
                    Label(path, systemImage: "folder").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchDesign.muted).lineLimit(1).truncationMode(.middle).help(path)
                }
                if let usage = session.usage {
                    if let used = usage.usedPercent {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(L10n.tr("Использовано")); Spacer(); Text("\(Int(used))%") }.font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                            ProgressView(value: min(100, max(0, used)), total: 100).tint(used > 85 ? .orange : providerStyle.color)
                        }
                    }
                }
                if model.pending[session.id] == nil {
                    HStack {
                        Spacer()
                        Button { model.dismiss(session.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(NotchDesign.muted).help(L10n.tr("Убрать сессию")).accessibilityLabel(L10n.tr("Убрать сессию %@", session.title))
                    }.padding(.top, 2)
                }
            }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 11).fill(providerStyle.color.opacity(selected ? 0.07 : 0.025)))
        .overlay {
            if session.status == .approval || model.pending[session.id] != nil {
                RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.75)
            } else if selected {
                RoundedRectangle(cornerRadius: 11).strokeBorder(providerStyle.color.opacity(0.22), lineWidth: 0.75)
            }
        }
        .overlay(alignment: .bottom) {
            if !selected { Rectangle().fill(.white.opacity(0.055)).frame(height: 0.5).padding(.horizontal, 13) }
        }
    }

    private func profileLabel(_ provider: String) -> String {
        guard let profile = attention?.profileName, profile != provider else { return provider }
        return provider + " · " + profile
    }

    private func cardActionLabel(_ info: SessionCardContent, route: SessionNavigationAction) -> String {
        if attention == nil, let title = route.title { return title + " · " + info.primaryTitle }
        let label = L10n.tr("%@, %@, %@. Подробнее", profileLabel(info.providerName), info.primaryTitle, session.status.label)
        guard let attention else { return label }
        let project = info.projectIsTitle ? nil : info.projectName
        return [label, project, attention.machineName].compactMap { $0 }.joined(separator: " · ")
    }

    private func activateCard(_ route: SessionNavigationAction) {
        if attention != nil || route.title == nil { model.selectSession(selected ? nil : session.id) }
        else { model.activateSession(session) }
    }

    @ViewBuilder private func navigationControl(_ route: SessionNavigationAction, prominent: Bool) -> some View {
        if attention != nil, let title = route.title, let notice = route.notice {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    navigationButton(title, prominent: prominent)
                    navigationNotice(notice)
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                    navigationButton(title, prominent: prominent)
                    navigationNotice(notice)
                }
            }
        } else {
            if let title = route.title { navigationButton(title, prominent: prominent) }
            if let notice = route.notice { navigationNotice(notice) }
        }
    }

    @ViewBuilder private func navigationButton(_ title: String, prominent: Bool) -> some View {
        let button = Button { model.jump(session) } label: { Label(title, systemImage: "arrow.up.forward") }
        if attention != nil {
            button.buttonStyle(AttentionActionButtonStyle(prominent: prominent))
                .accessibilityIdentifier("attention-session-action-" + session.id)
        } else {
            button.buttonStyle(NotchActionButtonStyle(prominent: prominent))
                .accessibilityIdentifier("respond-in-agent-" + session.id)
        }
    }

    private func navigationNotice(_ notice: String) -> some View {
        Text(notice).font(.system(size: 10)).foregroundStyle(NotchDesign.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("session-navigation-notice-" + session.id)
    }
}
