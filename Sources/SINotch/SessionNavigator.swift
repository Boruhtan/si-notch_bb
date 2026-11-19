import AppKit
import SINotchCore

enum SessionDestination: Equatable {
    case link(URL, bundleID: String)
    case application(String)

    var opensExactSession: Bool {
        guard case let .link(url, _) = self else { return false }
        return url.scheme?.lowercased() == "codex"
    }

    static func resolve(_ session: AgentSession, hostBundleID: String? = nil) -> SessionDestination? {
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
        case .link:
            return destination.opensExactSession ? "session.navigation.openSession" : "session.navigation.openFile"
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
        let workspace = NSWorkspace.shared
        let bundle: String
        switch destination {
        case .link(_, let identifier): bundle = identifier
        case .application(let identifier): bundle = identifier
        }
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
        }
    }
}
