import Foundation

enum HarnessKind: String, CaseIterable, Identifiable, Sendable {
    case codex, pi, claude, opencode, hermes, gemini, copilot, cursor, custom

    var id: String { rawValue }
    var isPrimary: Bool { self == .codex || self == .pi }
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .pi: "Pi"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .hermes: "Hermes"
        case .gemini: "Gemini CLI"
        case .copilot: "Copilot CLI"
        case .cursor: "Cursor Agent"
        case .custom: "Custom agent"
        }
    }
    var supportLocalizationKey: String {
        switch self {
        case .gemini, .copilot, .cursor: "discovery.support.hooks"
        default: "discovery.support.\(rawValue)"
        }
    }
    fileprivate var commands: [String] {
        switch self {
        case .codex: ["codex"]
        case .pi: ["pi"]
        case .claude: ["claude"]
        case .opencode: ["opencode"]
        case .hermes: ["hermes"]
        case .gemini: ["gemini"]
        case .copilot: ["copilot"]
        case .cursor: ["cursor-agent", "agent"]
        case .custom: []
        }
    }
    fileprivate var applicationNames: [String] {
        switch self {
        case .codex: ["Codex.app"]
        case .opencode: ["OpenCode.app", "opencode.app"]
        case .hermes: ["Hermes.app"]
        case .cursor: ["Cursor.app"]
        // Claude Desktop is not evidence that Claude Code has been installed.
        default: []
        }
    }
}

struct HarnessLocation: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case executable, application }
    let kind: Kind
    let url: URL
    let resolvedURL: URL
    var id: String { kind.rawValue + ":" + resolvedURL.path }
}

struct HarnessDetection: Equatable, Sendable, Identifiable {
    let kind: HarnessKind
    let locations: [HarnessLocation]
    var id: String { kind.rawValue }
    var isDetected: Bool { !locations.isEmpty }
    var hasCLI: Bool { locations.contains { $0.kind == .executable } }
    var hasApplication: Bool { locations.contains { $0.kind == .application } }
    var primaryExecutablePath: String? { locations.first { $0.kind == .executable }?.url.path }
}

struct HarnessDiscoveryReport: Equatable, Sendable {
    let scannedAt: Date
    let results: [HarnessDetection]
    let executableDirectories: [URL]
    let applicationDirectories: [URL]
    var detected: [HarnessDetection] { results.filter(\.isDetected) }
}

/// Read-only discovery by exact conventional command/app names, never by executing
/// a found program. No shell startup files, credentials, or agent configs are read.
struct HarnessDiscoveryService: Sendable {
    let executableDirectories: [URL]
    let applicationDirectories: [URL]
    private let versionRoots: [(directory: URL, binSuffix: String)]

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         executableDirectories: [URL]? = nil, applicationDirectories: [URL]? = nil) {
        let home = homeDirectory.standardizedFileURL
        let conventional = ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) } +
            [".local/bin", ".bun/bin", ".npm-global/bin", ".opencode/bin", ".cargo/bin", ".volta/bin",
             ".asdf/shims", ".local/share/mise/shims", ".pyenv/shims", ".nodenv/shims", "Library/pnpm"].map {
                home.appendingPathComponent($0, isDirectory: true)
            }
        let environmentPaths = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).compactMap { entry -> URL? in
            let path = String(entry)
            // Empty/relative entries would search the current working directory.
            guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), path.utf8.count <= 4096 else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        self.executableDirectories = Self.uniqueDirectories(executableDirectories ?? conventional + environmentPaths)
        func root(_ key: String, _ fallback: String) -> URL {
            if let value = environment[key], value.hasPrefix("/"), value.utf8.count <= 4096,
               !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        versionRoots = executableDirectories != nil ? [] : [
            (root("NVM_DIR", ".nvm").appendingPathComponent("versions/node"), "bin"),
            (root("FNM_DIR", "Library/Application Support/fnm").appendingPathComponent("node-versions"), "installation/bin"),
            (home.appendingPathComponent(".local/share/fnm/node-versions"), "installation/bin"),
            (root("ASDF_DATA_DIR", ".asdf").appendingPathComponent("installs/nodejs"), "bin"),
            (root("MISE_DATA_DIR", ".local/share/mise").appendingPathComponent("installs/node"), "bin")
        ]
        self.applicationDirectories = Self.uniqueDirectories(applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ])
    }

    func scan(at date: Date = Date()) -> HarnessDiscoveryReport {
        let manager = FileManager.default
        // Enumerate only known version-manager directories on every rescan, so
        // installations made after the app started are visible from Finder too.
        let directories = Self.uniqueDirectories(executableDirectories + versionDirectories(manager: manager))
        let results = HarnessKind.allCases.map { kind -> HarnessDetection in
            var locations: [HarnessLocation] = []
            var identities: Set<String> = []
            for directory in directories {
                for name in kind.commands {
                    let url = directory.appendingPathComponent(name)
                    let resolved = url.resolvingSymlinksInPath()
                    guard Self.isRegularExecutable(url, manager: manager) else { continue }
                    // "agent" is ambiguous. Accept Cursor's conventional symlink
                    // target, but never label an unrelated generic agent as Cursor.
                    if kind == .cursor, name == "agent", !Self.isCursorTarget(resolved) { continue }
                    let location = HarnessLocation(kind: .executable, url: url, resolvedURL: resolved)
                    if identities.insert(location.id).inserted { locations.append(location) }
                }
            }
            for directory in applicationDirectories {
                for name in kind.applicationNames {
                    let url = directory.appendingPathComponent(name, isDirectory: true)
                    guard Self.isApplicationBundle(url, manager: manager) else { continue }
                    let location = HarnessLocation(kind: .application, url: url, resolvedURL: url.resolvingSymlinksInPath())
                    if identities.insert(location.id).inserted { locations.append(location) }
                }
            }
            return HarnessDetection(kind: kind, locations: locations)
        }
        return HarnessDiscoveryReport(scannedAt: date, results: results,
                                      executableDirectories: directories, applicationDirectories: applicationDirectories)
    }

    private func versionDirectories(manager: FileManager) -> [URL] {
        var result: [URL] = []
        for root in versionRoots {
            guard let entries = manager.enumerator(at: root.directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
            var count = 0
            while let url = entries.nextObject() as? URL, count < 32 {
                count += 1
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                result.append(url.appendingPathComponent(root.binSuffix, isDirectory: true))
            }
        }
        return result
    }

    private static func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seen: Set<String> = []
        return directories.compactMap { url in
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"), !url.path.contains("\n") else { return nil }
            let normalized = url.standardizedFileURL
            let identity = normalized.resolvingSymlinksInPath().path
            guard seen.insert(identity).inserted, seen.count <= 128 else { return nil }
            return normalized
        }
    }

    private static func isRegularExecutable(_ url: URL, manager: FileManager) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard manager.isExecutableFile(atPath: url.path),
              let attributes = try? manager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return true
    }

    private static func isCursorTarget(_ url: URL) -> Bool {
        url.pathComponents.contains { ["cursor-agent", "cursor-agent.app", "cursor.app"].contains($0.lowercased()) }
    }

    private static func isApplicationBundle(_ url: URL, manager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let attributes = try? manager.attributesOfItem(atPath: info.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 131_072,
              let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundlePackageType"] as? String == "APPL",
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty else { return false }
        return true
    }
}
