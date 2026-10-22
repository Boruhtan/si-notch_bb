import AppKit
import SwiftUI

struct CodexUsageView: View {
    @ObservedObject var controller: CodexQuotaController
    @State private var selectionError: String?
    private var binary: URL? { controller.binary }
    private var status: CodexUsageStatus? { controller.status }
    private var error: String? { selectionError ?? controller.error }
    private var loading: Bool { controller.loading }

    var body: some View {
        GroupBox(L10n.tr("usage.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("usage.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondary)
                HStack(spacing: 8) {
                    Button(L10n.tr("usage.refresh")) { controller.refresh() }
                        .buttonStyle(NotchActionButtonStyle(prominent: true))
                        .disabled(binary == nil || loading)
                    Button(L10n.tr("usage.chooseCLI")) { chooseBinary() }.buttonStyle(NotchActionButtonStyle()).help(binary?.path ?? L10n.tr("usage.missingCLI"))
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let status {
                    switch status {
                    case .signedOut:
                        Label(L10n.tr("usage.signedOut"), systemImage: "person.crop.circle.badge.questionmark")
                    case .unsupportedAccount:
                        Label(L10n.tr("usage.unsupportedAccount"), systemImage: "info.circle")
                    case .limits(let snapshot):
                        if let plan = snapshot.planType {
                            Text(plan.capitalized).fontWeight(.semibold)
                        }
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bucket.limitName ?? bucket.limitId).fontWeight(.semibold)
                                if let primary = bucket.primary {
                                    windowRow(L10n.tr("usage.primary"), window: primary)
                                }
                                if let secondary = bucket.secondary {
                                    windowRow(L10n.tr("usage.secondary"), window: secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        Text("\(L10n.tr("usage.checked")): \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsPalette.secondary)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12))
            .padding(10)
        }
        .onAppear { controller.refreshIfNeeded() }
    }

    private func windowRow(_ title: String, window: CodexQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(windowTitle(title, durationMins: window.windowDurationMins))
                Spacer()
                if let remaining = window.remainingPercent {
                    Text("\(Int(remaining.rounded()))% \(L10n.tr("usage.remaining"))")
                        .monospacedDigit()
                } else {
                    Text(L10n.tr("usage.unknown"))
                }
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: remaining, total: 100)
            }
            if let date = window.resetDate {
                Text("\(L10n.tr("usage.resets")): \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsPalette.secondary)
            }
        }
    }

    private func windowTitle(_ title: String, durationMins: Int?) -> String {
        guard let durationMins, durationMins > 0 else { return title }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        guard let duration = formatter.string(from: TimeInterval(durationMins) * 60) else { return title }
        return "\(title) · \(duration)"
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("usage.chooseCLI")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
            guard let executable = CodexBinaryLocator.executable(in: selected) else {
                selectionError = CodexUsageError.binaryInvalid.localizedDescription
                return
            }
            selectionError = nil
            controller.select(executable)
        }
    }
}
