import AppKit
import SINotchCore

enum SessionDestination: Equatable {
    case link(URL, bundleID: String)
    case application(String)
    case pi(PiSessionTarget)
    case hermesTerminal(HermesSessionTarget)

    var opensExactSession: Bool {
        switch self {
        case .link(let url, _): return ["codex", "hermes"].contains(url.scheme?.lowercased() ?? "")
        case .pi, .hermesTerminal: return true
        case .application: return false
        }
    }

    static func resolve(_ session: AgentSession, hostBundleID: String? = nil) -> SessionDestination? {
        if let pi = PiSessionTarget(session) { return .pi(pi) }
        return ordinary(session, hostBundleID: hostBundleID)
    }

    static func ordinary(_ session: AgentSession, hostBundleID: String? = nil) -> SessionDestination? {
        if let raw = session.targetURL, let destination = navigationLink(raw) { return destination }
        guard let bundle = hostBundleID ?? session.terminalBundleID, validBundleID(bundle) else { return nil }
        return .application(bundle)
    }

    // Only navigation routes are accepted. Editor command/extension URLs must
    // never become executable actions supplied through an agent event.
    private static func navigationLink(_ raw: String) -> SessionDestination? {
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              !parts.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = parts.url else { return nil }
        if scheme == "codex", parts.host == "threads",
           parts.path.split(separator: "/").count == 1,
           UUID(uuidString: String(parts.path.dropFirst())) != nil {
            return .link(url, bundleID: "com.openai.codex")
        }
        let editors = ["vscode": "com.microsoft.VSCode", "vscode-insiders": "com.microsoft.VSCodeInsiders",
                       "cursor": "com.todesktop.230313mzl4w4u92", "zed": "dev.zed.Zed"]
        if let bundle = editors[scheme], parts.host == "file", parts.path.hasPrefix("/"), parts.path.count > 1 {
            return .link(url, bundleID: bundle)
        }
        return nil
    }

    private static func validBundleID(_ value: String) -> Bool {
        value.count <= 256 && value.split(separator: ".").count >= 2 &&
            value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }
}

enum SessionNavigationAction: Equatable {
    case open(SessionDestination)
    case unavailable(noticeKey: String)
    case disabled

    var title: String? { titleKey.map { L10n.tr($0) } }
    var notice: String? { noticeKey.map { L10n.tr($0) } }

    var titleKey: String? {
        guard case let .open(destination) = self else { return nil }
        switch destination {
        case .link(let url, _) where url.scheme == "hermes":
            return "session.navigation.openHermesChat"
        case .link:
            return destination.opensExactSession ? "session.navigation.openSession" : "session.navigation.openFile"
        case .pi:
            return "session.navigation.openPiSession"
        case .hermesTerminal(let target):
            return target.remote == nil ? "session.navigation.openChatInTerminal" : "session.navigation.openChatSSH"
        case .application:
            return "session.navigation.openApplication"
        }
    }

    var noticeKey: String? {
        switch self {
        case .disabled:
            return nil
        case .open(let destination) where destination.opensExactSession:
            return nil
        default:
            return "session.navigation.exactUnavailable"
        }
    }
}

@MainActor
protocol SessionNavigating {
    func open(_ destination: SessionDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void)
}

@MainActor
final class SessionNavigator: SessionNavigating {
    func open(_ destination: SessionDestination, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch destination {
        case .pi(let target):
            if let original = target.rex, let rex = RexTerminal.installed() {
                rex.focus(original) { focused in
                    if focused { completion(true) }
                    else { Self.resumePi(target, completion: completion) }
                }
                return
            }
            if let terminal = target.terminal, SessionTerminal.focus(terminal) { completion(true); return }
            Self.resumePi(target, completion: completion)
            return
        case .hermesTerminal(let target):
            guard let command = target.command() else { completion(false); return }
            Self.launch(command, label: target.remote == nil ? "si-notch · Hermes" : "si-notch · Hermes SSH", completion: completion)
            return
        default: break
        }
        let workspace = NSWorkspace.shared
        guard let bundle = destination.applicationBundleID else { completion(false); return }
        // Activate the originating app; avoid spawning another terminal window.
        if case .application = destination,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            completion(running.activate(options: []))
            return
        }
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundle) else {
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let finished: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
            let success = app != nil && error == nil
            Task { @MainActor in completion(success) }
        }
        switch destination {
        case .link(let url, _):
            workspace.open([url], withApplicationAt: applicationURL, configuration: configuration, completionHandler: finished)
        case .application:
            workspace.openApplication(at: applicationURL, configuration: configuration, completionHandler: finished)
        case .pi, .hermesTerminal: break
        }
    }

    private static func resumePi(_ target: PiSessionTarget, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let command = target.command() else { completion(false); return }
        launch(command, label: "si-notch · Pi", completion: completion)
    }

    private static func launch(_ command: SessionTerminal.Command, label: String,
                               completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if let rex = RexTerminal.installed() { rex.launch(command, label: label, completion: completion) }
        else { SessionTerminal.launch(command, completion: completion) }
    }
}

private extension SessionDestination {
    var applicationBundleID: String? {
        switch self {
        case .link(_, let id), .application(let id): return id
        case .pi, .hermesTerminal: return nil
        }
    }
}
