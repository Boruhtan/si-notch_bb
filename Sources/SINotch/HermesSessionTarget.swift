import CryptoKit
import Foundation
import SINotchCore

struct HermesChatRoute: Equatable {
    static let bundleID = "com.nousresearch.hermes"
    let url: URL
    let id: String

    init?(_ session: AgentSession) {
        guard session.provider == "hermes", let raw = session.targetURL,
              let route = SessionRoute(raw, scheme: "hermes", host: "open"),
              route.path.hasPrefix("/") else { return nil }
        let id = String(route.path.dropFirst())
        guard id.utf8.count <= 128, !id.contains(".."),
              id.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil,
              id != "latest" else { return nil }
        // Bind the navigation ID to the same identity used by the observer.
        // Neither another profile's chat nor a later URL can replace it.
        let unscoped = Self.opaque(id)
        let expected = session.connectionID.map { Self.opaque($0 + ":" + unscoped) } ?? unscoped
        guard session.id == expected else { return nil }
        self.id = id
        url = URL(string: "hermes://open/" + id)!
    }

    private static func opaque(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "hermes-" + hash
    }
}

struct HermesSessionTarget: Equatable {
    struct Remote: Equatable {
        let host: String
        let python: String
        let cli: String
    }

    let chat: HermesChatRoute
    let profile: String
    let home: String
    let remote: Remote?

    init?(chat: HermesChatRoute, profile: String, home: String, remote: Remote? = nil) {
        guard profile.utf8.count <= 128,
              profile.range(of: #"\A[a-z0-9][a-z0-9_-]*\z"#, options: .regularExpression) != nil,
              SessionTerminal.absolutePath(home),
              profile == "default" || home.hasSuffix("/profiles/" + profile) else { return nil }
        if let remote {
            guard (try? RemoteSSHCommand.validateHost(remote.host)) != nil,
                  Self.validExecutablePath(remote.python),
                  Self.validExecutablePath(remote.cli) else { return nil }
        }
        self.chat = chat
        self.profile = profile
        self.home = home
        self.remote = remote
    }

    init?(chat: HermesChatRoute, connection: RemoteSSHConnection, profileID: String) {
        let matches = connection.profiles.filter { $0.connectionId == profileID }
        guard matches.count == 1, let selected = matches.first, selected.enabled, selected.pluginInstalled else { return nil }
        self.init(chat: chat, profile: selected.id, home: selected.home,
            remote: .init(host: connection.host.trimmingCharacters(in: .whitespacesAndNewlines),
                          python: connection.pythonPath, cli: connection.hermesCLI))
    }

    func command() -> SessionTerminal.Command? {
        if let remote {
            guard var args = try? RemoteHermesSetupClient.arguments(host: remote.host, pythonPath: remote.python,
                                                                    source: Self.resumeSource) else { return nil }
            args[0] = "-tt"
            args.insert(contentsOf: ["-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none"], at: 1)
            args[args.count - 1] += " " + resumeArguments(cli: remote.cli).map(SessionTerminal.quote).joined(separator: " ")
            return .init(program: "/usr/bin/ssh", arguments: args)
        }
        let local = FileManager.default.homeDirectoryForCurrentUser
        let pythons = [".hermes/hermes-agent/venv/bin/python", ".hermes/hermes-agent/.venv/bin/python"]
            .map { local.appendingPathComponent($0).path } + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let cli = SessionTerminal.executable("hermes"),
              let python = pythons.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        return .init(program: python, arguments: ["-c", Self.resumeSource] + resumeArguments(cli: cli))
    }

    private func resumeArguments(cli: String) -> [String] { [cli, home, profile, chat.id] }

    private static func validExecutablePath(_ path: String) -> Bool {
        path.hasPrefix("~/") ? SessionTerminal.absolutePath(String(path.dropFirst())) : SessionTerminal.absolutePath(path)
    }

    // The ID must exist in this exact profile before Hermes can interpret it as
    // a title or prefix. The same process then hands off to the interactive TUI.
    private static let resumeSource = """
    import os
    import sqlite3
    import sys
    from pathlib import Path

    cli, home, profile, session_id = sys.argv[1:]
    home = Path(home)
    db = home / 'state.db'
    try:
        with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True, timeout=2) as connection:
            found = connection.execute('SELECT 1 FROM sessions WHERE id = ? LIMIT 1', (session_id,)).fetchone()
    except (OSError, sqlite3.Error, ValueError):
        found = None
    if not found:
        sys.exit('si-notch: this exact Hermes session is unavailable in the configured profile.')
    os.environ['HERMES_HOME'] = str(home if profile == 'default' else home.parent.parent)
    os.environ['PATH'] = str(Path.home() / '.local/bin') + ':/opt/homebrew/bin:/usr/local/bin:' + os.environ.get('PATH', '/usr/bin:/bin')
    cli = str(Path(cli).expanduser())
    os.execv(cli, [cli, '--profile', profile, '--tui', '--resume', session_id])
    """
}
