import AppKit
import SwiftUI

struct CodexUsageView: View {
    @AppStorage(CodexBinaryLocator.preferenceKey) private var selectedCLI = ""
    @State private var binary: URL?
    @State private var status: CodexUsageStatus?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = 0

    var body: some View {
        GroupBox(L10n.tr("usage.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("usage.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.secondary)
                if let binary {
                    Text(binary.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SettingsPalette.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Label(L10n.tr("usage.missingCLI"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button(L10n.tr("usage.refresh")) { refresh() }
                        .buttonStyle(NotchActionButtonStyle(prominent: true))
                        .disabled(binary == nil || loading)
                    Button(L10n.tr("usage.chooseCLI")) { chooseBinary() }.buttonStyle(NotchActionButtonStyle())
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
        .onAppear { binary = CodexBinaryLocator.detected() }
        .onChange(of: selectedCLI) { _, _ in
            generation += 1
            binary = CodexBinaryLocator.detected()
            status = nil; error = nil; loading = false
        }
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

    private func refresh() {
        guard let binary else { return }
        generation += 1
        let token = generation
        loading = true; error = nil
        Task {
            do {
                let result = try await CodexUsageService().refresh(binary: binary)
                guard generation == token else { return }
                status = result
                loading = false
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
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
                error = CodexUsageError.binaryInvalid.localizedDescription
                return
            }
            selectedCLI = executable.path
            binary = executable
            status = nil; error = nil
        }
    }
}
