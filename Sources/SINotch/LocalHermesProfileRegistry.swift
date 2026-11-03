import CryptoKit
import Foundation

struct LocalHermesProfile: Equatable {
    let connectionID: String
    let name: String
    var provider: String { "hermes" }
    var id: String { provider + "/" + connectionID }
}

/// Inventory only: a saved identity never establishes online presence or work.
/// Reads observer settings, not Hermes credentials, conversations or model configuration.
struct LocalHermesProfileRegistry {
    var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")

    func scan() -> [LocalHermesProfile] {
        let manager = FileManager.default
        let root = self.root.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("profiles")
        let children = (try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let homes = [root] + children.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.sorted { $0.path < $1.path }.prefix(1024)
        let profiles = homes.compactMap { home -> LocalHermesProfile? in
            let file = home.appendingPathComponent("plugins/si-notch/si-notch.json")
            guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  let attributes = try? manager.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 8192,
                  let data = try? Data(contentsOf: file), data.count <= 8192,
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let instance = settings["instanceId"] as? String, !instance.isEmpty, instance.count <= 4096,
                  let name = settings["displayName"] as? String else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 128,
                  !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".si-notch/run/events.sock").path
            let socket = settings["socketPath"] as? String ?? expected
            guard socket == expected else { return nil }
            let digest = SHA256.hash(data: Data(instance.utf8)).map { String(format: "%02x", $0) }.joined()
            return LocalHermesProfile(connectionID: "hermes-instance-" + digest.prefix(32), name: trimmed)
        }
        // Cloned identities are ambiguous. Never silently combine their tasks.
        let grouped = Dictionary(grouping: profiles, by: \.id)
        return profiles.filter { grouped[$0.id]?.count == 1 }
    }
}
