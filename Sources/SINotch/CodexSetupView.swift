import AppKit
import SwiftUI

/// Embed this view in Settings > Connection when Codex is selected.
struct CodexSetupView: View {
    let cliPath: String
    @State private var preview: CodexConfigSetup.Preview?
    @State private var error: String?
    @State private var resultBackup: String?
    @State private var createdConfig = false
    @AppStorage("appLanguage") private var appLanguage = "auto"

    private var setup: CodexConfigSetup { CodexConfigSetup(helperPath: cliPath) }

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Codex CLI · уведомление о завершении хода"))
                .font(.system(size: 14, weight: .semibold))
            Text(L10n.tr("Этот адаптер показывает завершение хода Codex CLI. Работа инструментов, запросы разрешений и обнаружение сессий Codex Desktop требуют отдельных источников событий."))
                .font(.system(size: 11)).foregroundStyle(.secondary)

            GroupBox(L10n.tr("1. Команда терминала")) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("Эту команду можно выполнить в Fish или другом shell:"))
                    Text("codex --version")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button(L10n.tr("Скопировать команду терминала")) { copy("codex --version") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
            }

            GroupBox(L10n.tr("2. Содержимое файла ~/.codex/config.toml — НЕ команда терминала")) {
                VStack(alignment: .leading, spacing: 8) {
                    if let preview {
                        Text(L10n.tr("Предпросмотр изменения:"))
                        Text("+ " + preview.proposedLine)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        Text(preview.explanation)
                            .foregroundStyle(preview.existingNotify ? Color.orange : Color.secondary)
                        HStack {
                            Button(L10n.tr("Обновить предпросмотр")) { refresh() }
                            Button(L10n.tr("Открыть файл")) { openConfig() }
                            Button(L10n.tr("Добавить в config.toml")) { apply() }
                                .disabled(!preview.canApply)
                        }
                    } else {
                        Text(L10n.tr("Проверяем файл настройки…"))
                    }
                }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(5)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if resultBackup != nil || createdConfig {
                Label(resultBackup.map { L10n.tr("Добавлено. Резервная копия: %@", $0) } ?? L10n.tr("Создан config.toml с уведомлением si-notch."), systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.green)
            }
            Text(L10n.tr("После настройки завершите реальный ход Codex CLI при запущенном si-notch. Одной проверки синтетическим JSON недостаточно для проверки подключения."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .onAppear { refresh() }
        .onChange(of: appLanguage) { _, _ in refresh() }
    }

    private func refresh() {
        do { preview = try setup.preview(); error = nil }
        catch { preview = nil; self.error = error.localizedDescription }
    }

    private func apply() {
        guard let preview else { return }
        do {
            let backup = try setup.apply(preview)
            resultBackup = backup?.lastPathComponent
            createdConfig = backup == nil
            refresh()
        } catch { resultBackup = nil; createdConfig = false; refresh(); self.error = error.localizedDescription }
    }

    private func openConfig() {
        let url = setup.configURL
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
