import CryptoKit
import Foundation
import Security

enum UpdateChannel: String, Codable, CaseIterable {
    case stable, beta
}

struct UpdateRelease: Codable, Equatable {
    let version: String
    let bundleVersion: String
    let bundleBuild: String
    let channel: UpdateChannel
    let notes: String
    let url: URL
    let sha256: String
    let size: Int64
    var pluginUpdates: [PluginUpdate]? = nil
}

struct UpdateFeed: Codable {
    let feedVersion: Int
    let releases: [UpdateRelease]
}

struct SignedUpdateFeed: Codable {
    let payload: String
    let signature: String
}

enum UpdateCheckResult: Equatable {
    case unconfigured
    case upToDate
    case available(UpdateRelease)
}

enum UpdateError: Error, LocalizedError {
    case invalidConfiguration, insecureURL, invalidResponse, oversized, invalidSignature, unavailable
    case invalidFeed, invalidVersion, invalidArchive, hashMismatch, codeSignature

    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.tr("updates.unavailable")
        case .invalidConfiguration: return "Update feed configuration is invalid."
        case .insecureURL: return "The update URL must use HTTPS."
        case .invalidResponse: return "The update server returned an invalid response."
        case .oversized: return "The update exceeds the size limit."
        case .invalidSignature: return "The update feed signature is invalid."
        case .invalidFeed: return "The update feed is invalid."
        case .invalidVersion: return "The installed version is invalid."
        case .invalidArchive: return "The update archive is invalid."
        case .hashMismatch: return "The update archive checksum does not match."
        case .codeSignature: return "The app code signature does not match this release."
        }
    }
}

struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: Curve25519.Signing.PublicKey
    let teamID: String
    let bundleID: String
    let repository: String?

    init?(bundle: Bundle = .main) {
        guard let feed = bundle.object(forInfoDictionaryKey: "SIUpdateFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https", url.host != nil,
              let encodedKey = bundle.object(forInfoDictionaryKey: "SIUpdatePublicKey") as? String,
              let keyData = Data(base64Encoded: encodedKey), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        feedURL = url
        publicKey = key
        teamID = bundle.object(forInfoDictionaryKey: "SIUpdateTeamID") as? String ?? ""
        guard teamID.isEmpty || teamID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        bundleID = identifier
        repository = bundle.object(forInfoDictionaryKey: "SIUpdateRepository") as? String
        guard repository == nil || Self.validRepository(repository!) else { return nil }
    }

    init(feedURL: URL, publicKey: Curve25519.Signing.PublicKey, teamID: String, bundleID: String, repository: String? = nil) {
        self.feedURL = feedURL
        self.publicKey = publicKey
        self.teamID = teamID
        self.bundleID = bundleID
        self.repository = repository
    }

    static func validRepository(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
}

struct UpdateVersion: Comparable {
    let major: Int, minor: Int, patch: Int
    let prerelease: [String]

    init?(_ text: String) {
        let split = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let core = split[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = core[0].split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0.count == 1 || $0.first != "0") }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
        if core.count == 2 {
            let ids = core[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
            prerelease = ids
        } else { prerelease = [] }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for pair in [(lhs.major, rhs.major), (lhs.minor, rhs.minor), (lhs.patch, rhs.patch)] {
            if pair.0 != pair.1 { return pair.0 < pair.1 }
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) {
            if a == b { continue }
            let an = Int(a), bn = Int(b)
            if let an, let bn { return an < bn }
            if an != nil { return true }
            if bn != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct UpdateService {
    static let maxFeedBytes = 1_048_576
    static let maxArchiveBytes: Int64 = 250 * 1_048_576
    let configuration: UpdateConfiguration?
    let session: URLSession

    init(configuration: UpdateConfiguration? = UpdateConfiguration(), session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func check(currentVersion: String, channel: UpdateChannel) async throws -> UpdateCheckResult {
        guard let configuration else { return .unconfigured }
        guard let current = UpdateVersion(currentVersion) else { throw UpdateError.invalidVersion }
        let feed = try await latestFeed(configuration, channel: channel)
        var candidates: [(UpdateVersion, UpdateRelease)] = []
        for release in feed.releases {
            guard let version = UpdateVersion(release.version) else { throw UpdateError.invalidFeed }
            if (channel == .beta || release.channel == .stable) && version > current {
                candidates.append((version, release))
            }
        }
        guard let newest = candidates.max(by: { $0.0 < $1.0 }) else { return .upToDate }
        return .available(newest.1)
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    private func latestFeed(_ configuration: UpdateConfiguration, channel: UpdateChannel) async throws -> UpdateFeed {
        guard let repository = configuration.repository else {
            return try await verifiedFeed(configuration, url: configuration.feedURL)
        }
        guard UpdateConfiguration.validRepository(repository) else { throw UpdateError.invalidConfiguration }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
        let data = try await fetch(url, limit: Self.maxFeedBytes)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        let eligible = releases.compactMap { release -> (UpdateVersion, GitHubRelease, URL)? in
            let versionText = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard !release.draft, channel == .beta || !release.prerelease,
                  let version = UpdateVersion(versionText), channel == .beta || version.prerelease.isEmpty,
                  let asset = release.assets.first(where: { $0.name == "update.json" }),
                  asset.browser_download_url.scheme == "https",
                  asset.browser_download_url.host == "github.com",
                  asset.browser_download_url.path.hasPrefix("/\(repository)/releases/download/") else { return nil }
            return (version, release, asset.browser_download_url)
        }.sorted { $0.0 > $1.0 }
        guard let latest = eligible.first else { return UpdateFeed(feedVersion: 1, releases: []) }
        let feed = try await verifiedFeed(configuration, url: latest.2)
        let expectedVersion = latest.1.tag_name.hasPrefix("v") ? String(latest.1.tag_name.dropFirst()) : latest.1.tag_name
        guard feed.releases.count == 1, let item = feed.releases.first,
              item.version == expectedVersion,
              item.channel == (latest.1.prerelease ? .beta : .stable),
              item.url.host == "github.com",
              item.url.path.hasPrefix("/\(repository)/releases/download/\(latest.1.tag_name)/") else { throw UpdateError.invalidFeed }
        return feed
    }

    private func verifiedFeed(_ configuration: UpdateConfiguration, url: URL) async throws -> UpdateFeed {
        let data = try await fetch(url, limit: Self.maxFeedBytes)
        return try Self.decodeVerifiedFeed(data, configuration: configuration)
    }

    static func decodeVerifiedFeed(_ data: Data, configuration: UpdateConfiguration) throws -> UpdateFeed {
        let envelope = try JSONDecoder().decode(SignedUpdateFeed.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              configuration.publicKey.isValidSignature(signature, for: payload) else { throw UpdateError.invalidSignature }
        let feed = try JSONDecoder().decode(UpdateFeed.self, from: payload)
        guard feed.feedVersion == 1, !feed.releases.isEmpty, feed.releases.count <= 100 else { throw UpdateError.invalidFeed }
        for release in feed.releases {
            guard UpdateVersion(release.version) != nil,
                  release.bundleVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
                  release.bundleBuild.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil,
                  release.url.scheme?.lowercased() == "https", release.url.host != nil,
                  release.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  release.size > 0, release.size <= Self.maxArchiveBytes,
                  release.notes.utf8.count <= 64_000,
                  PluginUpdate.validList(release.pluginUpdates ?? []) else { throw UpdateError.invalidFeed }
        }
        return feed
    }

    // The signed manifest authenticates ad hoc builds too. Developer ID builds
    // additionally pin the Apple team; all builds require a valid code seal.
    func downloadVerified(_ release: UpdateRelease) async throws -> URL {
        guard let configuration else { throw UpdateError.invalidConfiguration }
        let feed = try await latestFeed(configuration, channel: release.channel)
        guard feed.releases.contains(release) else { throw UpdateError.invalidFeed }
        guard release.url.scheme?.lowercased() == "https", release.url.host != nil,
              release.size > 0, release.size <= Self.maxArchiveBytes else { throw UpdateError.invalidFeed }
        let archive = try await fetch(release.url, limit: Int(release.size))
        guard archive.count == release.size else { throw UpdateError.invalidArchive }
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UpdateError.hashMismatch }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let zip = directory.appendingPathComponent("si-notch.zip")
            try archive.write(to: zip, options: .atomic)
            let extracted = directory.appendingPathComponent("expanded", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, extracted.path]
            ditto.standardOutput = FileHandle.nullDevice
            ditto.standardError = FileHandle.nullDevice
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateError.invalidArchive }
            let app = extracted.appendingPathComponent("si-notch.app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: app.path),
                  let bundle = Bundle(url: app),
                  Self.matchesSignedBundle(release, bundle: bundle, bundleID: configuration.bundleID) else { throw UpdateError.invalidArchive }
            try Self.verifyCodeSignature(app, teamID: configuration.teamID, bundleID: configuration.bundleID)
            try? FileManager.default.removeItem(at: extracted)
            return zip
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else { throw UpdateError.insecureURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("si-notch", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw UpdateError.unavailable }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme?.lowercased() == "https" else { throw UpdateError.invalidResponse }
        if http.expectedContentLength > Int64(limit) { throw UpdateError.oversized }
        var result = Data()
        result.reserveCapacity(min(limit, 65_536))
        for try await byte in bytes {
            if result.count >= limit { throw UpdateError.oversized }
            result.append(byte)
        }
        return result
    }

    static func verifyCodeSignature(_ app: URL, teamID: String, bundleID: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError.codeSignature }
        let requirementText = "identifier \"\(bundleID)\"" + (teamID.isEmpty ? "" : " and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw UpdateError.codeSignature
        }
    }

    static func matchesSignedBundle(_ release: UpdateRelease, bundle: Bundle, bundleID: String) -> Bool {
        bundle.bundleIdentifier == bundleID &&
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.bundleVersion &&
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == release.bundleBuild
    }
}

@MainActor
final class UpdateBackgroundChecker {
    static let shared = UpdateBackgroundChecker()
    private var timer: Timer?
    private var checking = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfEnabled() }
        }
        Task { await checkIfEnabled() }
    }

    private func checkIfEnabled() async {
        guard !checking, UserDefaults.standard.bool(forKey: "updateBackgroundChecks") else { return }
        checking = true
        defer { checking = false }
        let channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "stable") ?? .stable
        let version = Bundle.main.object(forInfoDictionaryKey: "SIReleaseVersion") as? String ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        do {
            let result = try await UpdateService().check(currentVersion: version, channel: channel)
            let selected = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "stable") ?? .stable
            guard UserDefaults.standard.bool(forKey: "updateBackgroundChecks"), selected == channel else { return }
            PluginUpdateCatalog.save(result, channel: channel, defaults: .standard)
        } catch {
            // Background network failures never affect the agent or foreground UI.
        }
    }
}
