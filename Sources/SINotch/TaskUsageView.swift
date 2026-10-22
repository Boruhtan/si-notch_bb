import SwiftUI
import Charts
import SINotchCore

struct TaskUsageList: View {
    @ObservedObject var usage: UsageController
    @ObservedObject var history: HistoryController
    @State private var search = ""
    @State private var provider = "all"
    @State private var sortByCost = false
    @State private var days = 0
    @State private var selected = Set<String>()
    @State private var selecting = false
    @State private var limit = 30
    private var rows: [UsageTask] {
        let cutoff = days == 0 ? Date.distantPast : Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let matches = usage.tasks.filter {
            (provider == "all" || $0.provider == provider) && $0.updatedAt >= cutoff &&
            (search.isEmpty || taskName($0, history: history.records).localizedCaseInsensitiveContains(search))
        }
        return sortByCost ? matches.sorted { ($0.counts?.total ?? -1) > ($1.counts?.total ?? -1) } : matches
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("task.selectionTotal")).foregroundStyle(SettingsPalette.secondary)
                    Text(rows.compactMap(\.counts).isEmpty ? "—" : TokenFormat.compact(rows.compactMap(\.counts).reduce(TokenCounts.zero) { $0.adding($1) }.total))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(L10n.tr("task.totalHelp")).font(.caption).foregroundStyle(SettingsPalette.secondary)
                    if usage.catchingUp { Label(L10n.tr("tokens.catchingUp"), systemImage: "clock") }
                    if rows.contains(where: { $0.partial || $0.counts == nil }) { Text(L10n.tr("tokens.partial")).font(.caption).foregroundStyle(.orange) }
                    if usage.error { Text(L10n.tr("tokens.error")).font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            HStack {
                Picker(L10n.tr("tokens.provider"), selection: $provider) {
                    Text(L10n.tr("Все")).tag("all")
                    ForEach(["codex", "hermes", "pi"], id: \.self) { Text(SessionCardContent.providerName($0)).tag($0) }
                }.frame(maxWidth: 180)
                Picker(L10n.tr("task.period"), selection: $days) {
                    Text(L10n.tr("task.allTime")).tag(0); Text(L10n.tr("task.week")).tag(7); Text(L10n.tr("task.month")).tag(30)
                }.frame(maxWidth: 190)
                Spacer(minLength: 0)
            }.labelsHidden()
            TextField(L10n.tr("task.search"), text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Toggle(L10n.tr("task.sortTokens"), isOn: $sortByCost).toggleStyle(.checkbox)
                Spacer()
                Button(L10n.tr(selecting ? "task.cancelSelection" : "task.select")) { selecting.toggle(); selected = [] }
                if selecting { Button(L10n.tr("task.merge")) { usage.mergeTasks(Array(selected)); selected = []; selecting = false }.disabled(selected.count < 2) }
            }.font(.caption)
            if rows.isEmpty { Text(L10n.tr("task.empty")).foregroundStyle(SettingsPalette.secondary).padding(.vertical, 20) }
            LazyVStack(spacing: 6) {
                ForEach(Array(rows.prefix(limit))) { task in
                    HStack {
                        if selecting, !task.unassigned, !task.id.hasPrefix("group:") {
                            Toggle("", isOn: Binding(get: { selected.contains(task.id) }, set: { if $0 { selected.insert(task.id) } else { selected.remove(task.id) } }))
                                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(taskName(task, history: history.records))
                        }
                        Button { usage.selectedID = task.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: task.unassigned ? "questionmark.folder" : "checklist").foregroundStyle(.mint)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(taskName(task, history: history.records)).lineLimit(2)
                                    Text(task.startedAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(SettingsPalette.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(task.counts.map { TokenFormat.compact($0.total) } ?? "—").monospacedDigit()
                                if task.partial { Image(systemName: "info.circle").help(L10n.tr("tokens.partial")) }
                                Image(systemName: "chevron.right").font(.caption)
                            }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                if rows.count > limit { Button(L10n.tr("history.more")) { limit += 50 } }
            }
            Text(L10n.tr("task.definition")).font(.caption).foregroundStyle(SettingsPalette.secondary)
        }
    }
}

func taskName(_ task: UsageTask, history: [HistorySummary]) -> String {
    if task.unassigned { return L10n.tr("task.unassigned") + " · " + SessionCardContent.providerName(task.provider) }
    if let record = history.first(where: { r in r.sessionKey == task.sessionKey && r.turnID.map { task.memberIDs.contains(UsageTask.key(session: r.sessionKey, turn: $0)) } == true }) { return record.historyTitle }
    return task.title ?? (L10n.tr(task.id.hasPrefix("group:") ? "task.group" : "task.default") + " · " + SessionCardContent.providerName(task.provider))
}

struct TaskUsageDetail: View {
    let task: UsageTask
    @ObservedObject var usage: UsageController
    @ObservedObject var history: HistoryController
    @State private var selectedIndex: Int?
    @State private var byModel = false
    @State private var showRequests = false
    private var requests: [TaskUsageItem] { task.items.filter(\.isRequest).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date } }
    private var buckets: [[TaskUsageItem]] {
        let items = requests, size = max(1, Int(ceil(Double(items.count) / 60)))
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { usage.selectedID = nil } label: { Label(L10n.tr("task.all"), systemImage: "chevron.left") }.buttonStyle(.plain)
            Text(taskName(task, history: history.records)).font(.title3.weight(.semibold)).textSelection(.enabled)
            HStack {
                Text(task.startedAt, format: .dateTime.day().month().year().hour().minute())
                if let status = task.status { Label(status.historyLabel, systemImage: status.historySymbol) }
            }.font(.caption).foregroundStyle(SettingsPalette.secondary)
            Text(L10n.tr("tokens.withChildren")).font(.caption).foregroundStyle(SettingsPalette.secondary)
            GroupBox { TokenBreakdown(counts: task.counts).padding(12) }
            if task.partial { Label(L10n.tr("tokens.partial"), systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
            if let counts = task.counts { composition(counts) }
            if !requests.isEmpty { timeline }
            participants
            DisclosureGroup(L10n.tr("task.requests"), isExpanded: $showRequests) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(requests) { item in
                        DisclosureGroup {
                            TokenBreakdown(counts: item.counts).padding(.vertical, 8)
                        } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.model ?? L10n.tr("usage.unknown"))
                                Text(item.date, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(SettingsPalette.secondary)
                                if item.kind == "auxiliary" { Text(L10n.tr("task.auxiliary")).font(.caption) }
                            }
                            Spacer()
                            Text(TokenFormat.exact(item.counts.total)).monospacedDigit().textSelection(.enabled)
                        }
                        }
                    }
                }.padding(.top, 8)
            }
            if task.id.hasPrefix("group:") { Button(L10n.tr("task.ungroup")) { usage.ungroup(task.id); usage.selectedID = nil } }
            if let session = task.sessionKey { Button(L10n.tr("tokens.session")) { usage.selectedID = session } }
            Text(L10n.tr("task.tokenHelp")).font(.caption).foregroundStyle(SettingsPalette.secondary)
        }
    }
    private func composition(_ counts: TokenCounts) -> some View {
        let cached = counts.cached.flatMap { $0 <= counts.input ? $0 : nil }
        let parts: [(String, Int, Color)] = cached.map { [("task.freshInput", counts.input - $0, .mint), ("tokens.cached", $0, .cyan), ("task.output", counts.output, .orange)] }
            ?? [("task.input", counts.input, .mint), ("task.output", counts.output, .orange)]
        return GroupBox(L10n.tr("task.composition")) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(parts, id: \.0) { part in
                            Rectangle().fill(part.2).frame(width: proxy.size.width * Double(part.1) / Double(max(1, counts.total)))
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 3))
                }.frame(height: 10).accessibilityHidden(true)
                ForEach(parts, id: \.0) { part in
                    HStack { Circle().fill(part.2).frame(width: 7, height: 7); Text(L10n.tr(part.0)); Spacer(); Text(TokenFormat.exact(part.1)).monospacedDigit() }
                }
            }.font(.caption).padding(10)
        }
    }
    private var timeline: some View {
        let values = buckets
        let selection = min(max(0, selectedIndex ?? (values.count - 1)), values.count - 1)
        let chosen = values[selection]
        return GroupBox(L10n.tr("task.timeline")) {
            VStack(alignment: .leading, spacing: 10) {
                Chart(Array(values.enumerated()), id: \.offset) { index, items in
                    BarMark(x: .value(L10n.tr("task.request"), index), y: .value(L10n.tr("tokens.title"), items.reduce(0) { TokenCounts.add($0, $1.counts.total) }))
                        .foregroundStyle(index == selection ? Color.mint : Color.mint.opacity(0.45))
                }.chartXSelection(value: $selectedIndex).chartXAxis(.hidden).frame(height: 130)
                HStack {
                    Button { selectedIndex = max(0, selection - 1) } label: { Image(systemName: "chevron.left") }.disabled(selection == 0).accessibilityLabel(L10n.tr("task.previousRequest"))
                    Text(chosen[0].date, format: .dateTime.hour().minute().second())
                    Spacer()
                    Text(TokenFormat.exact(chosen.reduce(0) { TokenCounts.add($0, $1.counts.total) })).monospacedDigit()
                    Button { selectedIndex = min(values.count - 1, selection + 1) } label: { Image(systemName: "chevron.right") }.disabled(selection == values.count - 1).accessibilityLabel(L10n.tr("task.nextRequest"))
                }.font(.caption)
                Text(L10n.tr(values.count < requests.count ? "task.groupedRequests" : "task.chartHelp")).font(.caption).foregroundStyle(SettingsPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(10)
        }
    }
    private var participants: some View {
        let groups = Dictionary(grouping: task.items) { byModel ? ($0.model ?? L10n.tr("usage.unknown")) : $0.sessionKey }
        let totals = groups.map { ($0.key, $0.value.reduce(TokenCounts.zero) { $0.adding($1.counts) }.total) }.sorted { $0.1 > $1.1 }
        return GroupBox {
            VStack(spacing: 12) {
                Picker(L10n.tr("task.breakdown"), selection: $byModel) {
                    Text(L10n.tr("task.byAgents")).tag(false); Text(L10n.tr("task.byModels")).tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                ForEach(totals, id: \.0) { key, count in
                    let name = byModel ? key : key == task.sessionKey ? L10n.tr("task.mainAgent") : usage.sessions.first(where: { $0.id == key })?.title ?? L10n.tr("usage.unknown")
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(name).lineLimit(2); Spacer(); Text(TokenFormat.exact(count)).monospacedDigit() }
                        ProgressView(value: Double(count), total: Double(max(1, task.counts?.total ?? 0))).tint(.mint).accessibilityHidden(true)
                    }.font(.caption)
                }
            }.padding(10)
        }
    }
}
