import CryptoKit
import Foundation
import XCTest
@testable import SINotch

private final class UpdateURLProtocol: URLProtocol {
    static var responses: [String: (Int, [String: String], Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let (status, headers, data) = Self.responses[url.absoluteString],
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: UpdateError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UpdateServiceTests: XCTestCase {
    private let feedURL = URL(string: "https://updates.example.test/manifest.json")!
    private let archiveURL = URL(string: "https://updates.example.test/si-notch.zip")!

    override func tearDown() {
        UpdateURLProtocol.responses = [:]
        super.tearDown()
    }

    private func fixture(_ releases: [UpdateRelease]) throws -> (UpdateService, Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(UpdateFeed(feedVersion: 1, releases: releases))
        let envelope = SignedUpdateFeed(payload: payload.base64EncodedString(),
                                        signature: try key.signature(for: payload).base64EncodedString())
        UpdateURLProtocol.responses[feedURL.absoluteString] = (200, ["Content-Type": "application/json"], try JSONEncoder().encode(envelope))
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [UpdateURLProtocol.self]
        let service = UpdateService(configuration: UpdateConfiguration(feedURL: feedURL, publicKey: key.publicKey,
                                                                       teamID: "ABCDEFGHIJ", bundleID: "io.github.eugeneb1ack.si-notch"),
                                    session: URLSession(configuration: sessionConfig))
        return (service, key)
    }

    private func release(_ version: String, _ channel: UpdateChannel, digest: String = String(repeating: "a", count: 64), size: Int64 = 100) -> UpdateRelease {
        UpdateRelease(version: version, bundleVersion: String(version.split(separator: "-")[0]), bundleBuild: "1",
                      channel: channel, notes: "Release notes", url: archiveURL, sha256: digest, size: size)
    }

    private func plugin(_ url: String = "https://github.com/test-owner/si-notch/tree/v1.1.0/plugins/hermes#installation") -> PluginUpdate {
        PluginUpdate(id: "hermes", name: "Hermes", version: "1.10", change: .updated, installURL: URL(string: url)!)
    }
    func testSignedPluginAnnouncementsAndLegacyFeed() async throws {
        var item = release("1.1.0", .stable); item.pluginUpdates = [plugin()]
        let (service, _) = try fixture([item])
        let result = try await service.check(currentVersion: "1.0.0", channel: .stable)
        XCTAssertEqual(result, .available(item))
        let (legacy, _) = try fixture([release("1.0.1", .stable)])
        let old = try await legacy.check(currentVersion: "1.0.0", channel: .stable)
        if case .available(let value) = old { XCTAssertNil(value.pluginUpdates) } else { XCTFail("Legacy feed must work") }
    }
    func testInvalidPluginLinksAndDuplicateIDsRejectSignedFeed() async throws {
        for url in ["http://github.com/owner/repo", "https://example.com/owner/repo", "https://github.com@evil.test/owner/repo",
                    "https://user@github.com/owner/repo", "https://github.com:443/owner/repo", "https://github.com/owner",
                    "https://github.com/owner/repo?redirect=evil", "https://github.com/owner/repo/%2e%2e/file"] {
            XCTAssertFalse(plugin(url).isValid, url)
        }
        var item = release("1.1.0", .stable); item.pluginUpdates = [plugin(), plugin()]
        let (service, _) = try fixture([item])
        do { _ = try await service.check(currentVersion: "1.0.0", channel: .stable); XCTFail("Duplicate IDs") }
        catch UpdateError.invalidFeed { }
    }
    func testPluginCatalogChannelVersionAndPostInstallLinks() throws {
        let suite = "plugin-update-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var item = release("1.1.0", .stable); item.pluginUpdates = [plugin()]
        PluginUpdateCatalog.save(.available(item), channel: .stable, defaults: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: "updatePluginCatalog"))
        XCTAssertEqual(PluginUpdateCatalog.displayed(data: data, availableVersion: "1.1.0", channel: .stable, bundled: []), [plugin()])
        XCTAssertEqual(PluginUpdateCatalog.displayed(data: data, availableVersion: "1.1.0", channel: .beta, bundled: []), [])
        XCTAssertEqual(PluginUpdateCatalog.displayed(data: data, availableVersion: "1.2.0", channel: .stable, bundled: []), [])
        PluginUpdateCatalog.save(.upToDate, channel: .stable, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "updateAvailableVersion"))
        XCTAssertNil(defaults.object(forKey: "updatePluginCatalog"))
        XCTAssertEqual(PluginUpdateCatalog.displayed(data: Data(), availableVersion: "", channel: .stable, bundled: [plugin()]), [plugin()])
    }

    func testSemVerPrereleaseOrdering() {
        XCTAssertLessThan(UpdateVersion("1.2.0-beta.2")!, UpdateVersion("1.2.0-beta.10")!)
        XCTAssertLessThan(UpdateVersion("1.2.0-beta.10")!, UpdateVersion("1.2.0")!)
        XCTAssertNil(UpdateVersion("1.02.0"))
        XCTAssertNil(UpdateVersion("1.2"))
    }

    func testMissingConfigurationIsExplicit() async throws {
        let result = try await UpdateService(configuration: nil).check(currentVersion: "0.2.0", channel: .beta)
        XCTAssertEqual(result, .unconfigured)
    }

    func testStableAndBetaSelectionUseVerifiedFeed() async throws {
        let stable = release("1.1.0", .stable)
        let beta = release("1.2.0-beta.1", .beta)
        let (service, _) = try fixture([stable, beta])
        let stableResult = try await service.check(currentVersion: "1.0.0", channel: .stable)
        let betaResult = try await service.check(currentVersion: "1.0.0", channel: .beta)
        let currentResult = try await service.check(currentVersion: "1.2.0", channel: .beta)
        XCTAssertEqual(stableResult, .available(stable))
        XCTAssertEqual(betaResult, .available(beta))
        XCTAssertEqual(currentResult, .upToDate)
    }

    func testTamperedPayloadFailsSignature() async throws {
        let (service, _) = try fixture([release("1.1.0", .stable)])
        let tampered = SignedUpdateFeed(payload: Data("{}".utf8).base64EncodedString(),
                                        signature: Data(repeating: 0, count: 64).base64EncodedString())
        UpdateURLProtocol.responses[feedURL.absoluteString] = (200, [:], try JSONEncoder().encode(tampered))
        do {
            _ = try await service.check(currentVersion: "1.0.0", channel: .stable)
            XCTFail("A tampered feed must be rejected")
        } catch UpdateError.invalidSignature { }
    }

    func testArchiveHashMismatchIsRejectedBeforeExtraction() async throws {
        let archive = Data("invalid archive".utf8)
        let item = release("1.1.0", .stable, size: Int64(archive.count))
        let (service, _) = try fixture([item])
        UpdateURLProtocol.responses[archiveURL.absoluteString] = (200, [:], archive)
        do {
            _ = try await service.downloadVerified(item)
            XCTFail("A mismatched archive must not be staged")
        } catch UpdateError.hashMismatch { }
    }

    func testUnsignedReleaseCannotBeDownloaded() async throws {
        let signed = release("1.1.0", .stable)
        let (service, _) = try fixture([signed])
        do {
            _ = try await service.downloadVerified(release("9.0.0", .beta))
            XCTFail("A release absent from the signed feed must be rejected")
        } catch UpdateError.invalidFeed { }
    }

    func testSignedBundleVersionAndBuildMustMatchExtractedApp() throws {
        let item = release("1.2.0-beta.1", .beta)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-update-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        func makeBundle(_ name: String, version: String, build: String) throws -> Bundle {
            let app = directory.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "io.github.eugeneb1ack.si-notch",
                                        "CFBundleShortVersionString": version, "CFBundleVersion": build]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            return try XCTUnwrap(Bundle(url: app))
        }
        let wrongVersion = try makeBundle("old-version", version: "1.1.0", build: "1")
        XCTAssertFalse(UpdateService.matchesSignedBundle(item, bundle: wrongVersion, bundleID: "io.github.eugeneb1ack.si-notch"))
        let wrongBuild = try makeBundle("old-build", version: "1.2.0", build: "2")
        XCTAssertFalse(UpdateService.matchesSignedBundle(item, bundle: wrongBuild, bundleID: "io.github.eugeneb1ack.si-notch"))
        let matching = try makeBundle("matching", version: "1.2.0", build: "1")
        XCTAssertTrue(UpdateService.matchesSignedBundle(item, bundle: matching, bundleID: "io.github.eugeneb1ack.si-notch"))
    }

    private func githubFixture() throws -> (UpdateService, UpdateRelease, UpdateRelease) {
        let key = Curve25519.Signing.PrivateKey()
        let repository = "test-owner/si-notch"
        var metadata: [[String: Any]] = []
        var items: [UpdateRelease] = []
        for (version, channel) in [("1.1.0", UpdateChannel.stable), ("1.2.0-beta.1", .beta)] {
            let base = "https://github.com/\(repository)/releases/download/v\(version)/"
            let item = UpdateRelease(version: version, bundleVersion: String(version.split(separator: "-")[0]), bundleBuild: "5",
                channel: channel, notes: "Notes", url: URL(string: base + "si-notch.zip")!, sha256: String(repeating: "a", count: 64), size: 100)
            let payload = try JSONEncoder().encode(UpdateFeed(feedVersion: 1, releases: [item]))
            let envelope = SignedUpdateFeed(payload: payload.base64EncodedString(), signature: try key.signature(for: payload).base64EncodedString())
            UpdateURLProtocol.responses[base + "update.json"] = (200, [:], try JSONEncoder().encode(envelope))
            metadata.append(["tag_name": "v\(version)", "draft": false, "prerelease": channel == .beta,
                             "assets": [["name": "update.json", "browser_download_url": base + "update.json"]]])
            items.append(item)
        }
        // Drafts must never be advertised, even if their version is newer.
        metadata.append(["tag_name": "v99.0.0", "draft": true, "prerelease": false, "assets": []])
        UpdateURLProtocol.responses["https://api.github.com/repos/\(repository)/releases?per_page=100"] = (200, [:], try JSONSerialization.data(withJSONObject: metadata))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [UpdateURLProtocol.self]
        return (UpdateService(configuration: UpdateConfiguration(feedURL: feedURL, publicKey: key.publicKey,
            teamID: "", bundleID: "io.github.eugeneb1ack.si-notch", repository: repository), session: URLSession(configuration: session)), items[0], items[1])
    }

    func testGitHubStableBetaAndDraftSelection() async throws {
        let (service, stable, beta) = try githubFixture()
        let stableResult = try await service.check(currentVersion: "1.0.0", channel: .stable)
        let betaResult = try await service.check(currentVersion: "1.0.0", channel: .beta)
        let currentResult = try await service.check(currentVersion: "1.2.0", channel: .beta)
        XCTAssertEqual(stableResult, .available(stable))
        XCTAssertEqual(betaResult, .available(beta))
        XCTAssertEqual(currentResult, .upToDate)
    }

    func testGitHubUnavailableRepositoryIsNotReportedAsUpToDate() async throws {
        let (service, _, _) = try githubFixture()
        UpdateURLProtocol.responses["https://api.github.com/repos/test-owner/si-notch/releases?per_page=100"] = (404, [:], Data())
        do {
            _ = try await service.check(currentVersion: "1.0.0", channel: .stable)
            XCTFail("Private/missing releases are unavailable, not up to date")
        } catch UpdateError.unavailable { }
    }

    func testGitHubRejectsTamperedManifest() async throws {
        let (service, _, _) = try githubFixture()
        UpdateURLProtocol.responses["https://github.com/test-owner/si-notch/releases/download/v1.1.0/update.json"] = (200, [:], try JSONEncoder().encode(
            SignedUpdateFeed(payload: Data("{}".utf8).base64EncodedString(), signature: Data(repeating: 0, count: 64).base64EncodedString())))
        do {
            _ = try await service.check(currentVersion: "1.0.0", channel: .stable)
            XCTFail("Untrusted manifest")
        } catch UpdateError.invalidSignature { }
    }
}
