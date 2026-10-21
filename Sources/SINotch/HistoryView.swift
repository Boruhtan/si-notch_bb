import SwiftUI
import AppKit
import SINotchCore

struct HistoryView: View {
    @ObservedObject var history: HistoryController
    var body: some View {
        VStack(spacing: 0) {
            if history.error {
                Label(L10n.tr("history.error"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).padding(12)
            }
            if let entry = history.selected {
                HStack {
                    Button { history.back() } label: { Label(L10n.tr("history.back"), systemImage: "chevron.left") }
                    Spacer()
                    Button { copy(entry.items.map { "\($0.role.historyLabel):\n\($0.text)" }.joined(separator: "\n\n")) } label: {
                        Label(L10n.tr("history.copy"), systemImage: "doc.on.doc")
                    }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
                    .padding(.horizontal, 22).padding(.bottom, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Text(entry.summary.historyTitle).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                        HStack(spacing: 10) {
                            Label(entry.summary.status.historyLabel, systemImage: entry.summary.status.historySymbol)
                                .foregroundStyle(entry.summary.status.tint)
                            if entry.summary.memoryService {
                                Label(entry.summary.historyProviderName, systemImage: "brain")
                                    .foregroundStyle(NotchDesign.secondary).help(L10n.tr("session.serviceMemoryHelp"))
                            } else {
                                Text(entry.summary.historyProviderName).foregroundStyle(NotchDesign.secondary)
                            }
                        }.font(.system(size: 10, weight: .medium))
                        Text(entry.summary.startedAt, format: .dateTime.day().month().hour().minute())
                            .font(.system(size: 10)).foregroundStyle(NotchDesign.muted)
                        ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label(item.role.historyLabel, systemImage: item.role.historySymbol)
                                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(item.role == .command ? .cyan : NotchDesign.secondary)
                                    Spacer()
                                    Button { copy(item.text) } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.plain).foregroundStyle(NotchDesign.muted).help(L10n.tr("history.copy"))
                                        .accessibilityLabel(L10n.tr("history.copy"))
                                }
                                Text(item.text).font(.system(size: 11, design: item.role == .command ? .monospaced : .default))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if entry.truncated { Text(L10n.tr("history.truncated")).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 20).padding(.bottom, 16)
                }.scrollIndicators(.hidden).id(entry.id)
            } else {
                TextField(L10n.tr("history.search"), text: $history.search)
                    .textFieldStyle(.plain).font(.system(size: 12)).padding(10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .onChange(of: history.search) { _, _ in history.visibleCount = 50 }
                if history.loading { ProgressView().controlSize(.small).padding(24) }
                else if history.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 22)).foregroundStyle(NotchDesign.muted)
                        Text(L10n.tr("history.empty")).font(.system(size: 13, weight: .medium))
                        Text(L10n.tr("history.emptyHelp")).font(.system(size: 11)).foregroundStyle(NotchDesign.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 330)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let matches = history.matching
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(matches.prefix(history.visibleCount))) { item in
                                Button { history.open(item.id) } label: {
                                    HistoryRow(summary: item)
                                }.buttonStyle(.plain)
                            }
                            if matches.isEmpty { Text(L10n.tr("history.noMatches")).font(.system(size: 12)).foregroundStyle(.secondary).padding(24) }
                            if matches.count > history.visibleCount {
                                Button(L10n.tr("history.more")) { history.visibleCount += 50 }.buttonStyle(.plain).font(.system(size: 11)).padding(12)
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                    }.scrollIndicators(.hidden)
                }
            }
            HStack {
                Text(L10n.tr("history.recordCount", history.records.count))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(history.bytes), countStyle: .file))
            }.font(.system(size: 10)).foregroundStyle(NotchDesign.muted).padding(.horizontal, 22).padding(.vertical, 10)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

private struct HistoryRow: View {
    let summary: HistorySummary
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.status.historySymbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(summary.status.tint)
                .frame(width: 24, height: 24)
                .background(summary.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(summary.historyTitle).font(.system(size: 12, weight: .medium))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchDesign.muted).padding(.top, 3).accessibilityHidden(true)
                }
                HStack(spacing: 6) {
                    Text(summary.status.historyLabel).foregroundStyle(summary.status.tint).fixedSize()
                    Text("·").foregroundStyle(NotchDesign.muted)
                    if summary.memoryService {
                        Label(summary.historyProviderName, systemImage: "brain")
                            .help(L10n.tr("session.serviceMemoryHelp")).fixedSize()
                    } else {
                        Text(summary.historyProviderName).lineLimit(1)
                    }
                    if let project = summary.project {
                        Text(URL(fileURLWithPath: project).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                    }
                    Spacer(minLength: 0)
                    Text(summary.updatedAt, format: .dateTime.day().month().hour().minute()).fixedSize()
                }.font(.system(size: 10)).foregroundStyle(NotchDesign.secondary)
            }
        }.padding(.horizontal, 11).padding(.vertical, 10)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            .help(L10n.tr("history.statusHelp", summary.status.historyLabel))
    }
}

extension HistorySummary {
    var historyTitle: String { memoryService ? L10n.tr("history.memoryTitle") : title }
    var historyProviderName: String { SessionCardContent.providerName(provider) }
}

extension AgentStatus {
    var historySymbol: String {
        switch self {
        case .idle: return "minus"
        case .working: return "ellipsis"
        case .waiting: return "questionmark.bubble"
        case .approval: return "hand.raised"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .ended: return "stop.fill"
        }
    }
    var historyLabel: String {
        switch self {
        case .idle: return L10n.tr("history.idle")
        case .ended: return L10n.tr("history.ended")
        default: return label
        }
    }
}

struct HistorySettingsView: View {
    @ObservedObject var history: HistoryController
    let defaults: UserDefaults
    @State private var count = ""
    @State private var megabytes = ""
    @State private var confirmClear = false
    @State private var invalid = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(L10n.tr("history.enabled"), isOn: Binding(get: { history.policy.enabled }, set: { enabled in
                var policy = history.policy; policy.enabled = enabled; save(policy)
            }))
            Text(L10n.tr("history.description")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L10n.tr("history.maximumCount")); Spacer()
                        TextField("1000", text: $count).frame(width: 90).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text(L10n.tr("history.maximumMB")); Spacer()
                        TextField("200", text: $megabytes).frame(width: 90).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 10) {
                        Button(L10n.tr("history.apply")) { apply() }
                        Button(L10n.tr("history.defaults")) {
                            count = "1000"; megabytes = "200"; apply()
                        }
                    }
                    if invalid { Text(L10n.tr("history.invalidLimits")).font(.system(size: 11)).foregroundStyle(.orange) }
                    Text(L10n.tr("history.retention")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(10)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("history.recordCount", history.records.count)).font(.system(size: 12, weight: .medium))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(history.bytes), countStyle: .file)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("history.clear"), role: .destructive) { confirmClear = true }.disabled(history.records.isEmpty)
            }
            Text(L10n.tr("history.privacy")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if history.error { Label(L10n.tr("history.error"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 12)) }
        }
        .onAppear { count = String(history.policy.maximumCount); megabytes = String(history.policy.maximumBytes / (1024 * 1024)) }
        .confirmationDialog(L10n.tr("history.clearQuestion"), isPresented: $confirmClear) {
            Button(L10n.tr("history.clear"), role: .destructive) { history.clear() }
        } message: { Text(L10n.tr("history.clearHelp")) }
    }
    private func apply() {
        guard let count = Int(count), let mb = Int(megabytes), (1...10000).contains(count), (1...2048).contains(mb) else { invalid = true; return }
        invalid = false; save(HistoryPolicy(enabled: history.policy.enabled, count: count, megabytes: mb))
    }
    private func save(_ policy: HistoryPolicy) {
        defaults.set(policy.enabled, forKey: "historyEnabled")
        defaults.set(policy.maximumCount, forKey: "historyMaximumCount")
        defaults.set(policy.maximumBytes / (1024 * 1024), forKey: "historyMaximumMB")
        history.configure(policy)
    }
}

extension AgentHistoryItem.Role {
    var historySymbol: String {
        switch self {
        case .user: return "person"
        case .assistant: return "text.bubble"
        case .command: return "terminal"
        }
    }
    var historyLabel: String {
        switch self {
        case .user: return L10n.tr("history.role.user")
        case .assistant: return L10n.tr("history.role.assistant")
        case .command: return L10n.tr("history.role.command")
        }
    }
}
