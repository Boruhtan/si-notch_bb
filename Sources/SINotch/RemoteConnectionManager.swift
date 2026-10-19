import Combine
import Foundation

struct RemoteSSHConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host = ""
    var remoteSocketPath = ""
    var pythonPath = "~/.hermes/hermes-agent/venv/bin/python"
    var hermesHome = "~/.hermes"
    var hermesCLI = "~/.local/bin/hermes"
    var showInAgents = true
    var profiles: [RemoteHermesProfile] = []
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.tr("remote.defaultName") : name }
}

/// Saved configuration, connection intent and tunnel ownership.
@MainActor
final class RemoteConnectionManager: ObservableObject {
    static let storageKey = "remoteSSHConnections.v1"
    static let reconnectKey = "remoteSSHReconnectIDs.v1"
    @Published private(set) var connections: [RemoteSSHConnection] = []
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let makeController: () -> RemoteConnectionController
    private var controllers: [UUID: RemoteConnectionController] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var loadFailed = false
    private var retiredIDs: Set<String> = []
    @Published private var reconnectIDs: Set<UUID>

    init(defaults: UserDefaults = .standard, makeController: (() -> RemoteConnectionController)? = nil) {
        self.defaults = defaults
        reconnectIDs = Set((defaults.stringArray(forKey: Self.reconnectKey) ?? []).compactMap(UUID.init(uuidString:)))
        self.retiredIDs = Set(defaults.stringArray(forKey: "remoteSSHRetiredProfiles.v1") ?? [])
        self.makeController = makeController ?? { RemoteConnectionController(defaults: nil) }
        if let data = defaults.data(forKey: Self.storageKey) {
            if let saved = try? JSONDecoder().decode([RemoteSSHConnection].self, from: data),
               Set(saved.map(\.id)).count == saved.count {
                connections = saved
            } else {
                loadFailed = true
                error = L10n.tr("remote.savedInvalid")
            }
        } else if let host = defaults.string(forKey: "remoteSSHHost"), !host.isEmpty {
            var migrated = RemoteSSHConnection(name: L10n.tr("remote.defaultName"))
            migrated.host = host
            migrated.remoteSocketPath = defaults.string(forKey: "remoteSSHSocketPath") ?? ""
            connections = [migrated]
        }
    }

    @discardableResult
    func add() -> UUID? {
        guard !loadFailed else { return nil }
        let connection = RemoteSSHConnection(name: L10n.tr("remote.numberedName", connections.count + 1))
        connections.append(connection)
        save()
        return connection.id
    }

    func update(_ connection: RemoteSSHConnection) {
        guard !loadFailed, let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        let previous = connections[index]
        if isActive(connection.id), previous.host != connection.host || previous.remoteSocketPath != connection.remoteSocketPath {
            error = L10n.tr("remote.disconnectToEdit")
            return
        }
        connections[index] = connection
        if previous.host != connection.host || previous.remoteSocketPath != connection.remoteSocketPath {
            remember(connection.id, reconnect: false)
        }
        if let controller = controllers[connection.id], !isActive(connection.id) {
            controller.host = connection.host
            controller.remoteSocketPath = connection.remoteSocketPath
        }
        error = nil
        save()
    }

    var agentConfigurations: [AgentConnection.Configuration] {
        let configured = connections.flatMap { connection in
            connection.profiles.compactMap { profile in
                profile.connectionId.map { AgentConnection.Configuration(connectionID: $0, name: profile.displayName,
                    connectorID: connection.id, visible: connection.showInAgents && profile.enabled) }
            }
        }
        let activeIDs = Set(configured.map(\.connectionID))
        return configured + retiredIDs.subtracting(activeIDs).map {
            AgentConnection.Configuration(connectionID: $0, name: "", connectorID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, visible: false)
        }
    }

    func remove(_ id: UUID) {
        guard !loadFailed else { return }
        if let connection = connections.first(where: { $0.id == id }) {
            retiredIDs.formUnion(connection.profiles.compactMap(\.connectionId))
            defaults.set(Array(retiredIDs).sorted(), forKey: "remoteSSHRetiredProfiles.v1")
        }
        disconnect(id)
        controllers.removeValue(forKey: id)
        subscriptions.removeValue(forKey: id)
        connections.removeAll { $0.id == id }
        save()
    }

    func state(_ id: UUID) -> RemoteConnectionState { controllers[id]?.state ?? .disconnected }

    func isActive(_ id: UUID) -> Bool {
        switch state(id) {
        case .connecting, .connected, .retrying: true
        default: false
        }
    }

    func connect(_ id: UUID, localSocketPath: String) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        let host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = connection.remoteSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connections.contains(where: { $0.id != id && isActive($0.id) &&
            $0.host.trimmingCharacters(in: .whitespacesAndNewlines) == host &&
            $0.remoteSocketPath.trimmingCharacters(in: .whitespacesAndNewlines) == path }) else {
            error = L10n.tr("remote.endpointInUse")
            return
        }
        error = nil
        let controller: RemoteConnectionController
        if let existing = controllers[id] { controller = existing }
        else {
            controller = makeController()
            controllers[id] = controller
            subscriptions[id] = controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
        controller.host = host
        controller.remoteSocketPath = path
        controller.pythonPath = connection.pythonPath
        controller.connect(localSocketPath: localSocketPath)
        if isActive(id) { remember(id, reconnect: true) }
    }

    func restoreConnections(localSocketPath: String) {
        for connection in connections where reconnectIDs.contains(connection.id) && !isActive(connection.id) {
            connect(connection.id, localSocketPath: localSocketPath)
        }
    }

    func reconnectAtLaunch(_ id: UUID) -> Bool { reconnectIDs.contains(id) }

    func setReconnectAtLaunch(_ id: UUID, enabled: Bool) {
        guard !loadFailed, connections.contains(where: { $0.id == id }) else { return }
        remember(id, reconnect: enabled)
    }

    func disconnect(_ id: UUID) {
        remember(id, reconnect: false)
        controllers[id]?.disconnect()
    }

    /// Shutdown stops tunnels without changing the user's saved connection intent.
    func disconnectAll() { controllers.values.forEach { $0.disconnect() } }

    private func remember(_ id: UUID, reconnect: Bool) {
        guard reconnectIDs.contains(id) != reconnect else { return }
        if reconnect { reconnectIDs.insert(id) } else { reconnectIDs.remove(id) }
        defaults.set(reconnectIDs.map(\.uuidString).sorted(), forKey: Self.reconnectKey)
    }

    private func save() {
        guard !loadFailed, let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
