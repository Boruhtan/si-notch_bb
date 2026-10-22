import Foundation
import SwiftUI

/// Release announcements, not an assertion about which remote plugins are installed.
struct PluginUpdate: Codable, Equatable, Identifiable {
    enum Change: String, Codable {
        case added, updated
        var labelKey: String { self == .added ? "updates.plugins.added" : "updates.plugins.updated" }
    }
    let id: String
    let name: String
    let version: String
    let change: Change
    let installURL: URL

    var isValid: Bool {
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
              !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              version.range(of: "^[0-9]+(?:\\.[0-9]+){1,2}(?:-[A-Za-z0-9.-]+)?$", options: .regularExpression) != nil,
              installURL.absoluteString.utf8.count <= 2048,
              let parts = URLComponents(url: installURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil else { return false }
        let path = parts.path.split(separator: "/")
        return path.count >= 2 && UpdateConfiguration.validRepository("\(path[0])/\(path[1])") &&
            !path.contains(where: { $0 == "." || $0 == ".." })
    }
    static func validList(_ updates: [Self]) -> Bool {
        updates.count <= 20 && Set(updates.map(\.id)).count == updates.count && updates.allSatisfy(\.isValid)
    }
}

enum PluginUpdateCatalog {
    private struct Cached: Codable {
        let version: String
        let channel: UpdateChannel
        let updates: [PluginUpdate]
    }
    static func bundled(_ bundle: Bundle = .main) -> [PluginUpdate] {
        guard let raw = bundle.object(forInfoDictionaryKey: "SIPluginUpdates"),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let updates = try? JSONDecoder().decode([PluginUpdate].self, from: data),
              PluginUpdate.validList(updates) else { return [] }
        return updates
    }
    static func displayed(data: Data, availableVersion: String, channel: UpdateChannel,
                          bundled: [PluginUpdate] = bundled()) -> [PluginUpdate] {
        // A cached announcement belongs to one signed release and selected channel.
        // After installation, the bundled announcement keeps installation links available.
        guard !availableVersion.isEmpty else { return bundled }
        guard data.count <= 64_000, let cache = try? JSONDecoder().decode(Cached.self, from: data),
              cache.version == availableVersion, cache.channel == channel,
              PluginUpdate.validList(cache.updates) else { return [] }
        return cache.updates
    }
    static func save(_ result: UpdateCheckResult, channel: UpdateChannel, defaults: UserDefaults) {
        switch result {
        case .available(let release):
            let updates = release.pluginUpdates ?? []
            guard PluginUpdate.validList(updates),
                  let data = try? JSONEncoder().encode(Cached(version: release.version, channel: channel, updates: updates)) else { return }
            defaults.set(data, forKey: "updatePluginCatalog")
            defaults.set(release.version, forKey: "updateAvailableVersion")
        case .upToDate:
            defaults.removeObject(forKey: "updateAvailableVersion")
            defaults.removeObject(forKey: "updatePluginCatalog")
        case .unconfigured: break
        }
    }
}

struct PluginUpdatesView: View {
    let updates: [PluginUpdate]
    var body: some View {
        if !updates.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Divider()
                Label(L10n.tr("updates.plugins.title"), systemImage: "puzzlepiece.extension")
                    .fontWeight(.semibold)
                Text(L10n.tr("updates.plugins.help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(updates) { plugin in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(plugin.name) \(plugin.version)").fontWeight(.medium)
                            Text(L10n.tr(plugin.change.labelKey)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Link(destination: plugin.installURL) {
                            Label(L10n.tr("updates.plugins.install"), systemImage: "arrow.up.right")
                        }
                        .accessibilityLabel("\(plugin.name) \(plugin.version). \(L10n.tr("updates.plugins.install"))")
                    }
                }
            }
        }
    }
}
