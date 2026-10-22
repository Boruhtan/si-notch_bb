import SwiftUI
import SINotchCore

struct UsageView: View {
    @ObservedObject var usage: UsageController
    @ObservedObject var quota: CodexQuotaController
    @ObservedObject var history: HistoryController
    @State private var showSessions = false
    @State private var section = 0
    @State private var provider = "all"
    @State private var search = ""
    @State private var visibleCount = 30
    private var rows: [UsageSession] {
        usage.sessions.filter { (provider == "all" || $0.provider == provider) &&
            (search.isEmpty || "\($0.title) \($0.project ?? "") \($0.connectionName ?? "") \($0.sessionID)".localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(L10n.tr("settings.usage"), selection: $section) {
                Text(L10n.tr("tokens.title")).tag(0)
                Text(L10n.tr("usage.title")).tag(1)
            }.pickerStyle(.segmented).labelsHidden()
            if section == 1 { CodexUsageView(controller: quota) }
            else if let id = usage.selectedID, let task = usage.tasks.first(where: { $0.id == id }) {
                TaskUsageDetail(task: task, usage: usage, history: history)
            } else if let id = usage.selectedID, let selected = usage.sessions.first(where: { $0.id == id }) {
                detail(selected)
            } else if usage.selectedID != nil {
                Button(L10n.tr("tokens.allSessions")) { usage.selectedID = nil }.buttonStyle(.plain)
                Label(L10n.tr("tokens.missingSession"), systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
            } else {
                Picker(L10n.tr("tokens.title"), selection: $showSessions) {
                    Text(L10n.tr("task.title")).tag(false); Text(L10n.tr("tokens.sessions")).tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if showSessions { overview } else { TaskUsageList(usage: usage, history: history) }
            }
        }
        .onAppear { quota.refreshIfNeeded(); usage.refresh() }
        .onChange(of: usage.selectedID) { _, id in if id != nil { section = 0 } }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("tokens.recorded")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                            Text(usage.total(usage.sessions).map { TokenFormat.compact($0.total) } ?? "—")
                                .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        Spacer()
                        if usage.catchingUp { ProgressView().controlSize(.small) }
                        Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(NotchActionButtonStyle()).help(L10n.tr("usage.refresh"))
                            .accessibilityLabel(L10n.tr("usage.refresh"))
                    }
                    let total = max(1, usage.total(usage.sessions)?.total ?? 0)
                    ForEach(["codex", "hermes", "pi"], id: \.self) { name in
                        let count = usage.total(usage.sessions.filter { $0.provider == name })
                        HStack(spacing: 10) {
                            Text(SessionCardContent.providerName(name)).frame(width: 62, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule().fill(.white.opacity(0.06))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(color(name)).frame(width: proxy.size.width * min(1, Double(count?.total ?? 0) / Double(total)))
                                    }
                            }.frame(height: 5).accessibilityHidden(true)
                            Text(count.map { TokenFormat.compact($0.total) } ?? "—").monospacedDigit().frame(width: 78, alignment: .trailing)
                        }.font(.system(size: 12, weight: .medium))
                    }
                    Text(L10n.tr(usage.catchingUp ? "tokens.catchingUp" : "tokens.scope"))
                        .font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(12)
            }
            if usage.error {
                Label(L10n.tr("tokens.error"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Text(L10n.tr("tokens.sessions")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker(L10n.tr("tokens.provider"), selection: $provider) {
                    Text(L10n.tr("Все")).tag("all")
                    ForEach(Array(Set(usage.sessions.map(\.provider)).union(["codex", "hermes", "pi"])).sorted(), id: \.self) {
                        Text(SessionCardContent.providerName($0)).tag($0)
                    }
                }.labelsHidden().frame(width: 135)
            }
            TextField(L10n.tr("tokens.search"), text: $search).textFieldStyle(.roundedBorder)
            if rows.isEmpty {
                Label(L10n.tr("tokens.empty"), systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary).padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(Array(rows.prefix(visibleCount))) { row in
                        Button { usage.selectedID = row.id } label: { sessionRow(row) }.buttonStyle(.plain)
                    }
                    if rows.count > visibleCount { Button(L10n.tr("history.more")) { visibleCount += 50 }.buttonStyle(NotchActionButtonStyle()) }
                }
            }
            Text(L10n.tr("tokens.hermesHelp")).font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func sessionRow(_ row: UsageSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.parentID == nil ? "bubble.left" : "arrow.turn.down.right")
                .foregroundStyle(color(row.provider)).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text([SessionCardContent.providerName(row.provider), row.connectionName,
                      row.project.map { URL(fileURLWithPath: $0).lastPathComponent }, row.model]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.counts.map { TokenFormat.compact($0.total) } ?? "—").font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text(row.updatedAt, format: .dateTime.day().month().hour().minute()).font(.system(size: 9)).foregroundStyle(SettingsPalette.secondary)
            }
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(SettingsPalette.secondary)
        }.padding(11).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
    private func detail(_ row: UsageSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { usage.selectedID = nil } label: { Label(L10n.tr("tokens.allSessions"), systemImage: "chevron.left") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
            Text(row.title).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
            Text([SessionCardContent.providerName(row.provider), row.connectionName, row.model].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
            if let parent = row.parentID, let parentRow = usage.sessions.first(where: { $0.id == parent }) {
                Button { usage.selectedID = parent } label: { Label(parentRow.title, systemImage: "arrow.turn.up.left") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchDesign.accent)
            }
            GroupBox(L10n.tr("tokens.own")) { TokenBreakdown(counts: row.counts).padding(12) }
            if row.partial { Label(L10n.tr("tokens.partial"), systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange) }
            let family = usage.family(row.id)
            let children = family.filter { $0.id != row.id }
            if !children.isEmpty {
                GroupBox(L10n.tr("tokens.withChildren")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(usage.total(family).map { TokenFormat.exact($0.total) } ?? "—").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        if family.contains(where: { $0.counts == nil || $0.partial }) {
                            Text(L10n.tr("tokens.partial")).font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Text(L10n.tr("tokens.childrenHelp")).font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary)
                        ForEach(children) { child in
                            Button { usage.selectedID = child.id } label: { sessionRow(child) }.buttonStyle(.plain)
                        }
                    }.padding(10)
                }
            }
            Text(L10n.tr("tokens.breakdownHelp")).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Text(row.updatedAt, format: .dateTime.day().month().year().hour().minute())
                .font(.system(size: 10)).foregroundStyle(SettingsPalette.secondary)
        }
    }
    private func color(_ provider: String) -> Color { provider == "codex" ? .mint : provider == "hermes" ? .orange : .cyan }
}

struct TokenBreakdown: View {
    let counts: TokenCounts?
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            line("tokens.total", counts?.total, prominent: true)
            Divider().overlay(SettingsPalette.border)
            line("task.input", counts?.input)
            help("task.inputHelp")
            VStack(alignment: .leading, spacing: 5) {
                line("tokens.cached", counts?.cached)
                help("task.cacheHelp")
            }.padding(.leading, 14)
            line("task.output", counts?.output)
            help("task.outputHelp")
            DisclosureGroup(L10n.tr("task.details"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    line("tokens.cacheWrite", counts?.cacheWrite)
                    help("task.cacheWriteHelp")
                    line("tokens.reasoning", counts?.reasoning)
                    help("task.reasoningHelp")
                }.padding(.top, 8)
            }.font(.caption)
        }
    }
    private func help(_ key: String) -> some View {
        Text(L10n.tr(key)).font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func line(_ key: String, _ number: Int?, prominent: Bool = false) -> some View {
        HStack {
            Text(L10n.tr(key)); Spacer()
            Text(number.map(TokenFormat.exact) ?? "—").monospacedDigit().textSelection(.enabled)
                .help(number == nil ? L10n.tr("task.notReported") : TokenFormat.exact(number!))
                .accessibilityLabel(number.map(TokenFormat.exact) ?? L10n.tr("task.notReported"))
        }.font(.system(size: prominent ? 20 : 13, weight: prominent ? .semibold : .medium))
    }
}

enum TokenFormat {
    static func exact(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: L10n.language))) }
    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...4)).locale(Locale(identifier: L10n.language)))
    }
}
