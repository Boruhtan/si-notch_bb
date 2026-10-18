import SwiftUI

/// The callback only selects a setup flow. This view never applies configuration.
struct HarnessDiscoveryView: View {
    var receipts: [String: Date] = [:]
    let onConnect: (HarnessKind) -> Void
    var service = HarnessDiscoveryService()
    var onDiscovery: ((HarnessDiscoveryReport) -> Void)?
    @State private var report: HarnessDiscoveryReport?
    @State private var scanning = false
    @AppStorage("appLanguage") private var appLanguage = "auto"

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("discovery.help"))
                        .font(.system(size: 12)).foregroundStyle(SettingsPalette.secondary)
                }
                Spacer(minLength: 4)
                Button { Task { await refresh() } } label: {
                    Label(L10n.tr("discovery.refresh"), systemImage: "arrow.clockwise")
                }.buttonStyle(NotchActionButtonStyle()).disabled(scanning)
                    .help(L10n.tr("discovery.safety"))
            }
            if scanning {
                Label(L10n.tr("discovery.checking"), systemImage: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
            } else if let report {
                Text(L10n.tr("discovery.foundCount", report.detected.count))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsPalette.secondary)
                if report.detected.isEmpty {
                    Text(L10n.tr("discovery.noAgents"))
                        .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                }
            }
            if !detectedRows.isEmpty {
                GroupBox(L10n.tr("discovery.found")) {
                    VStack(spacing: 16) {
                        ForEach(detectedRows) { detection in row(detection) }
                    }
                }
            }
            if !absentRows.isEmpty {
                DisclosureGroup(L10n.tr("discovery.others")) {
                    VStack(spacing: 16) {
                        ForEach(absentRows) { detection in row(detection) }
                    }.padding(.top, 12)
                }.font(.system(size: 12, weight: .medium))
            }
            Button { onConnect(.custom) } label: {
                Label(L10n.tr("discovery.customAction"), systemImage: "plus.circle")
            }.buttonStyle(.plain).font(.system(size: 12))

        }
        .task { await refresh() }
    }

    private var rows: [HarnessDetection] {
        report?.results ?? HarnessKind.allCases.map { HarnessDetection(kind: $0, locations: []) }
    }

    private var detectedRows: [HarnessDetection] { rows.filter { $0.isDetected && $0.kind != .custom } }
    private var absentRows: [HarnessDetection] { rows.filter { !$0.isDetected && $0.kind != .custom } }

    private func row(_ detection: HarnessDetection) -> some View {
        HStack(alignment: .top, spacing: 10) {
            SettingsIconTile(symbol: ProviderStyle(provider: detection.kind.rawValue).symbol,
                             color: ProviderStyle(provider: detection.kind.rawValue).color, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(detection.kind.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(statusText(detection))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(receipts[detection.kind.rawValue] != nil ? Color.green : SettingsPalette.secondary)
                }
                Text(L10n.tr(detection.kind.supportLocalizationKey))
                    .font(.system(size: 11)).foregroundStyle(SettingsPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            }
            Spacer(minLength: 0)
            Button(L10n.tr(detection.isDetected ? "discovery.connect" : "discovery.instructions")) {
                onConnect(detection.kind)
            }
            .buttonStyle(NotchActionButtonStyle(prominent: detection.kind.isPrimary))
            .help(detection.locations.map { $0.url.path }.joined(separator: "\n"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ detection: HarnessDetection) -> String {
        if receipts[detection.kind.rawValue] != nil { return L10n.tr("connection.received") }
        if detection.kind == .custom { return L10n.tr("discovery.manual") }
        if report == nil { return L10n.tr("discovery.checking") }
        if detection.hasApplication && !detection.hasCLI { return L10n.tr("discovery.appOnly") }
        return L10n.tr(detection.isDetected ? "discovery.found" : "discovery.notFound")
    }

    @MainActor private func refresh() async {
        guard !scanning else { return }
        scanning = true
        let scanner = service
        let result = await Task.detached(priority: .utility) { scanner.scan() }.value
        scanning = false
        guard !Task.isCancelled else { return }
        report = result
        onDiscovery?(result)
    }

}
