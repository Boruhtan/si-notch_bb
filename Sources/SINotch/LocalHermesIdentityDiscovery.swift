import CryptoKit
import Foundation

/// Read only observer identities, never Hermes credentials, history or model settings.
/// Fresh events still have to confirm presence; a settings file alone cannot hide an agent.
struct LocalHermesIdentityDiscovery {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func scan(socketPath: String) -> Set<AgentConnection.LocalIdentity> {
        let manager = FileManager.default
        let root = home.appendingPathComponent(".hermes", isDirectory: true)
        var homes = [root]
        if let configured = environment["HERMES_HOME"], configured.hasPrefix("/"),
           configured.utf8.count <= 4096,
           !configured.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            homes.append(URL(fileURLWithPath: configured, isDirectory: true))
        }
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        if let children = try? manager.contentsOfDirectory(at: profiles,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            homes += children.filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }.sorted { $0.path < $1.path }.prefix(256)
        }
        let expectedSocket = URL(fileURLWithPath: socketPath).standardizedFileURL
        return Set(homes.compactMap { home -> AgentConnection.LocalIdentity? in
            let settings = home.appendingPathComponent("plugins/si-notch/si-notch.json")
            guard let attributes = try? manager.attributesOfItem(atPath: settings.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 8192,
                  let data = try? Data(contentsOf: settings), data.count <= 8192,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let instance = object["instanceId"] as? String,
                  !instance.isEmpty, instance.unicodeScalars.count <= 4096 else { return nil }
            let defaultSocket = self.home.appendingPathComponent(".si-notch/run/events.sock").path
            if let configuredSocket = object["socketPath"], !(configuredSocket is String) { return nil }
            let socket = object["socketPath"] as? String ?? defaultSocket
            guard socket.hasPrefix("/"), URL(fileURLWithPath: socket).standardizedFileURL == expectedSocket else { return nil }
            let hash = SHA256.hash(data: Data(instance.utf8)).map { String(format: "%02x", $0) }.joined()
            return AgentConnection.LocalIdentity(provider: "hermes", connectionID: "hermes-instance-" + hash.prefix(32))
        })
    }
}
