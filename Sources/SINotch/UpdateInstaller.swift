import AppKit
import CryptoKit
import Darwin
import Foundation

enum UpdateInstallError: Error, LocalizedError {
    case location, changedApplication, invalidRequest, parentRunning, launchFailed
    var errorDescription: String? {
        switch self {
        case .location: return L10n.tr("updates.installLocation")
        case .changedApplication: return L10n.tr("updates.appChanged")
        case .invalidRequest: return L10n.tr("updates.invalidInstall")
        case .parentRunning: return L10n.tr("updates.quitFailed")
        case .launchFailed: return L10n.tr("updates.launchFailed")
        }
    }
}

/// A short-lived copy of our executable replaces the bundle after the UI exits.
/// No login helper, privileged service or agent configuration is installed.
enum UpdateInstaller {
    struct Request: Codable {
        let destination: URL
        let archive: URL
        let release: UpdateRelease
        let originalVersion: String
        let originalBuild: String
        let parentPID: Int32
        let createdAt: Date
    }

    @MainActor
    static func start(archive: URL, release: UpdateRelease, bundle: Bundle = .main) throws {
        let destination = bundle.bundleURL.standardizedFileURL
        try validateDestination(destination)
        guard let executable = bundle.executableURL else { throw UpdateInstallError.location }
        let directory = archive.deletingLastPathComponent()
        try validatePrivateDirectory(directory)
        // Recheck the downloaded bytes immediately before handing off.
        try validateArchive(archive, release: release)
        let request = Request(destination: destination, archive: archive, release: release,
            originalVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            originalBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            parentPID: getpid(), createdAt: Date())
        let receipt = directory.appendingPathComponent("install.json")
        try JSONEncoder().encode(request).write(to: receipt, options: .atomic)
        let helper = directory.appendingPathComponent("si-notch-updater")
        if FileManager.default.fileExists(atPath: helper.path) { try FileManager.default.removeItem(at: helper) }
        try FileManager.default.copyItem(at: executable, to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--install-update", receipt.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    static func run(receipt: URL) -> Int32 {
        let directory = receipt.deletingLastPathComponent()
        var recovery: Request?
        do {
            try validatePrivateDirectory(directory)
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: receipt))
            guard receipt.lastPathComponent == "install.json", request.parentPID > 1,
                  request.parentPID != getpid(), (0...120).contains(Date().timeIntervalSince(request.createdAt)),
                  request.archive.deletingLastPathComponent() == directory else { throw UpdateInstallError.invalidRequest }
            try validateDestination(request.destination)
            guard let bundle = Bundle(url: request.destination), let configuration = UpdateConfiguration(bundle: bundle),
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == request.originalVersion,
                  bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == request.originalBuild,
                  let current = UpdateVersion(bundle.object(forInfoDictionaryKey: "SIReleaseVersion") as? String ?? request.originalVersion),
                  let next = UpdateVersion(request.release.version), next > current else { throw UpdateInstallError.changedApplication }
            recovery = request
            try validateArchive(request.archive, release: request.release)
            let expanded = directory.appendingPathComponent("install-expanded", isDirectory: true)
            try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
            try command("/usr/bin/ditto", ["-x", "-k", request.archive.path, expanded.path])
            let candidate = expanded.appendingPathComponent("si-notch.app")
            guard let nextBundle = Bundle(url: candidate),
                  UpdateService.matchesSignedBundle(request.release, bundle: nextBundle, bundleID: configuration.bundleID) else { throw UpdateError.invalidArchive }
            try UpdateService.verifyCodeSignature(candidate, teamID: configuration.teamID, bundleID: configuration.bundleID)
            let deadline = Date().addingTimeInterval(30)
            while kill(request.parentPID, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard kill(request.parentPID, 0) != 0 else { throw UpdateInstallError.parentRunning }
            try replace(candidate: candidate, destination: request.destination) { url in
                do { try command("/usr/bin/open", ["-n", url.path]); return true } catch { return false }
            }
            try? FileManager.default.removeItem(at: directory)
            return 0
        } catch {
            // Preserve the verified archive and failure report for a manual retry.
            try? String(describing: error).write(to: directory.appendingPathComponent("install-error.txt"), atomically: true, encoding: .utf8)
            if let request = recovery, kill(request.parentPID, 0) != 0,
               (try? validateDestination(request.destination)) != nil,
               let original = Bundle(url: request.destination),
               original.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == request.originalVersion,
               original.object(forInfoDictionaryKey: "CFBundleVersion") as? String == request.originalBuild {
                try? command("/usr/bin/open", ["-n", request.destination.path])
            }
            return 1
        }
    }

    static func validateDestination(_ destination: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app", destination.isFileURL,
              destination.resolvingSymlinksInPath() == destination.standardizedFileURL,
              fm.isWritableFile(atPath: parent.path),
              Bundle(url: destination)?.bundleIdentifier == "io.github.eugeneb1ack.si-notch" else { throw UpdateInstallError.location }
    }

    private static func validatePrivateDirectory(_ directory: URL) throws {
        var info = stat()
        guard directory.lastPathComponent.hasPrefix("si-notch-update-"),
              lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw UpdateInstallError.invalidRequest }
    }

    static func validateArchive(_ url: URL, release: UpdateRelease) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == release.size, data.count <= UpdateService.maxArchiveBytes else { throw UpdateError.invalidArchive }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UpdateError.hashMismatch }
    }

    /// Rename on one volume; keep the old bundle until Launch Services accepts
    /// the replacement. A failed replacement or launch restores the old bundle.
    static func replace(candidate: URL, destination: URL, launch: (URL) -> Bool) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".si-notch-install-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let incoming = staging.appendingPathComponent("incoming.app")
        let previous = staging.appendingPathComponent("previous.app")
        var movedOriginal = false
        var installed = false
        do {
            try command("/usr/bin/ditto", ["--norsrc", "--noextattr", candidate.path, incoming.path])
            try fm.moveItem(at: destination, to: previous)
            movedOriginal = true
            try fm.moveItem(at: incoming, to: destination)
            installed = true
            guard launch(destination) else { throw UpdateInstallError.launchFailed }
            try? fm.removeItem(at: staging)
        } catch {
            if installed { try? fm.removeItem(at: destination) }
            if movedOriginal {
                // Leave the backup in place if restoration itself fails.
                do { try fm.moveItem(at: previous, to: destination) }
                catch { throw error }
                _ = launch(destination)
            }
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func command(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidArchive }
    }
}
