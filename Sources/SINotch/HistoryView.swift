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
                        Text(entry.summary.title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                        if entry.summary.memoryService {
                            Label(L10n.tr("session.serviceMemory"), systemImage: "gearshape.2").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(entry.summary.startedAt, format: .dateTime.day().month().hour().minute())
                            .font(.system(size: 10)).foregroundStyle(NotchDesign.muted)
                        ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.role.historyLabel)
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
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: item.memoryService ? "gearshape.2" : item.status.symbol)
                                                .foregroundStyle(item.status.tint).frame(width: 16)
                                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(NotchDesign.muted)
                                        }
                                        HStack(spacing: 8) {
                                            Text(item.provider.capitalized)
                                            if item.memoryService { Text(L10n.tr("session.serviceMemory")) }
                                            if let project = item.project { Text(URL(fileURLWithPath: project).lastPathComponent).lineLimit(1) }
                                            Spacer(minLength: 4)
                                            Text(item.updatedAt, format: .dateTime.day().month().hour().minute())
                                        }.font(.system(size: 10)).foregroundStyle(NotchDesign.secondary)
                                    }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                                        .contentShape(Rectangle())
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
    var historyLabel: String {
        switch self {
        case .user: return L10n.tr("history.role.user")
        case .assistant: return L10n.tr("history.role.assistant")
        case .command: return L10n.tr("history.role.command")
        }
    }
}
