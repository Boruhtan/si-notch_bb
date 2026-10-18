import Foundation

@MainActor
final class RemoteHermesSetupModel: ObservableObject {
    @Published var profiles: [RemoteHermesProfile] = []
    @Published private(set) var snapshot: RemoteHermesSnapshot?
    @Published private(set) var plan: RemoteHermesPlan?
    @Published private(set) var receipt: RemoteHermesReceipt?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var sshChecked = false
    private var inspectedTarget: [String]?
    private var previewProfiles: [RemoteHermesProfile] = []
    private let client: RemoteHermesSetupClient

    init(client: RemoteHermesSetupClient = .init()) { self.client = client }

    func invalidate() {
        snapshot = nil; plan = nil; receipt = nil; error = nil; profiles = []
        inspectedTarget = nil; sshChecked = false
    }

    func configurationChanged(_ connection: RemoteSSHConnection) {
        if inspectedTarget != connection.setupIdentity { invalidate() }
    }

    func canApply(_ connection: RemoteSSHConnection) -> Bool {
        !busy && plan?.hasChanges == true && inspectedTarget == connection.setupIdentity && profiles == previewProfiles
    }

    func checkConnection(_ connection: RemoteSSHConnection) async {
        guard !busy else { return }
        busy = true; error = nil; sshChecked = false
        defer { busy = false }
        do { try await client.checkConnection(connection); sshChecked = true }
        catch { self.error = error.localizedDescription }
    }

    func inspect(_ connection: RemoteSSHConnection, save: @escaping (RemoteHermesSnapshot) -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; plan = nil; receipt = nil; snapshot = nil
        defer { busy = false }
        do {
            let result = try await client.inspect(connection)
            var target = connection
            target.remoteSocketPath = result.socketPath
            snapshot = result; profiles = result.profiles; inspectedTarget = target.setupIdentity
            save(result)
        } catch { self.error = error.localizedDescription }
    }

    func preview(_ connection: RemoteSSHConnection) async {
        guard !busy, let snapshot, inspectedTarget == connection.setupIdentity else { return }
        busy = true; error = nil; plan = nil; receipt = nil
        defer { busy = false }
        do {
            let selected = profiles
            let result = try await client.preview(connection, snapshot: snapshot.snapshot, profiles: selected)
            plan = result; previewProfiles = selected
        } catch { self.error = error.localizedDescription }
    }

    func apply(_ connection: RemoteSSHConnection, save: @escaping ([RemoteHermesProfile]) -> Void) async {
        guard canApply(connection), let plan, let snapshot else { return }
        busy = true; error = nil
        defer { busy = false; self.plan = nil }
        do {
            receipt = try await client.apply(connection, snapshot: snapshot.snapshot, profiles: previewProfiles, planID: plan.planId)
            let actual = try await client.inspect(connection)
            self.snapshot = actual; profiles = actual.profiles
            save(actual.profiles)
        } catch {
            // An unknown SSH outcome must be inspected before another apply.
            self.snapshot = nil
            self.error = error.localizedDescription
        }
    }
}

extension RemoteSSHConnection {
    var setupIdentity: [String] { [id.uuidString, host, remoteSocketPath, pythonPath, hermesHome, hermesCLI] }
}
