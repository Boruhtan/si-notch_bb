import Foundation

struct CodexQuotaWindow: Decodable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }

    var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }
}

struct CodexRateLimitBucket: Decodable, Equatable, Identifiable {
    let limitId: String
    let limitName: String?
    let primary: CodexQuotaWindow?
    let secondary: CodexQuotaWindow?

    var id: String { limitId }
}

struct CodexUsageSnapshot: Equatable {
    let planType: String?
    let buckets: [CodexRateLimitBucket]
    let checkedAt: Date
}

enum CodexUsageStatus: Equatable {
    case signedOut
    case unsupportedAccount
    case limits(CodexUsageSnapshot)
}

enum CodexUsageError: Error, LocalizedError {
    case binaryMissing, binaryInvalid, launchFailed, timedOut, protocolError, serverError, limitsUnavailable

    var errorDescription: String? {
        switch self {
        case .binaryMissing: return L10n.tr("usage.error.binaryMissing")
        case .binaryInvalid: return L10n.tr("usage.error.binaryInvalid")
        case .launchFailed: return L10n.tr("usage.error.launchFailed")
        case .timedOut: return L10n.tr("usage.error.timedOut")
        case .protocolError: return L10n.tr("usage.error.protocolError")
        case .serverError: return L10n.tr("usage.error.serverError")
        case .limitsUnavailable: return L10n.tr("usage.error.limitsUnavailable")
        }
    }
}

enum CodexBinaryLocator {
    static let preferenceKey = "codexUsageCLIPath"
    private static let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    static func detected(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [String] = []
        if let selected = defaults.string(forKey: preferenceKey), !selected.isEmpty {
            let url = URL(fileURLWithPath: selected)
            return isExecutable(url) ? url : nil
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path)
        candidates.append("/opt/homebrew/bin/codex")
        candidates.append("/usr/local/bin/codex")
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/codex" }
        }
        candidates.append(bundled)
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first(where: isExecutable)
    }

    static func isExecutable(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: url.path)
    }

    // An app selection uses its declared bundle ID and known CLI location.
    // Code-signature trust is not inferred from these metadata checks.
    static func executable(in selected: URL) -> URL? {
        if selected.pathExtension.lowercased() != "app" { return isExecutable(selected) ? selected : nil }
        guard let bundle = Bundle(url: selected),
              ["com.openai.codex", "codex"].contains(bundle.bundleIdentifier ?? "") else { return nil }
        let paths = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                     "Contents/MacOS/codex"]
        return paths.map { selected.appendingPathComponent($0) }.first(where: isExecutable)
    }
}

struct CodexUsageService {
    private struct RateLimitsResult: Decodable {
        let rateLimits: CodexRateLimitBucket?
        let rateLimitsByLimitId: [String: CodexRateLimitBucket]?
    }

    static func parseRateLimits(_ result: Data, planType: String? = nil, checkedAt: Date = Date()) throws -> CodexUsageSnapshot {
        let decoded = try JSONDecoder().decode(RateLimitsResult.self, from: result)
        let buckets: [CodexRateLimitBucket]
        if let byID = decoded.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.values.sorted { $0.limitId < $1.limitId }
        } else if let legacy = decoded.rateLimits {
            buckets = [legacy]
        } else { throw CodexUsageError.limitsUnavailable }
        return CodexUsageSnapshot(planType: planType, buckets: buckets, checkedAt: checkedAt)
    }

    func refresh(binary: URL) async throws -> CodexUsageStatus {
        guard CodexBinaryLocator.isExecutable(binary) else { throw CodexUsageError.binaryInvalid }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.readFromAppServer(binary: binary)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func readFromAppServer(binary: URL) throws -> CodexUsageStatus {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CodexUsageError.launchFailed }
        let started = Date()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var reader = JSONLineReader(handle: output.fileHandleForReading)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
        try write(["method": "initialize", "id": 1,
                   "params": ["clientInfo": ["name": "si_notch", "title": "si-notch", "version": version]]], to: input.fileHandleForWriting)
        _ = try reader.result(for: 1, started: started)
        try write(["method": "initialized", "params": [:] as [String: String]], to: input.fileHandleForWriting)
        try write(["method": "account/read", "id": 2, "params": ["refreshToken": false]], to: input.fileHandleForWriting)
        let accountResult = try reader.result(for: 2, started: started)
        guard let account = accountResult["account"] as? [String: Any] else { return .signedOut }
        let type = account["type"] as? String
        if type == "apiKey" || type == "amazonBedrock" { return .unsupportedAccount }
        let planType = account["planType"] as? String
        try write(["method": "account/rateLimits/read", "id": 3], to: input.fileHandleForWriting)
        let limitsResult = try reader.result(for: 3, started: started)
        let data = try JSONSerialization.data(withJSONObject: limitsResult)
        return .limits(try parseRateLimits(data, planType: planType))
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private struct JSONLineReader {
    let handle: FileHandle
    private var buffer = Data()
    private var lines = 0

    init(handle: FileHandle) { self.handle = handle }

    mutating func result(for id: Int, started: Date) throws -> [String: Any] {
        while true {
            if Date().timeIntervalSince(started) > 10 { throw CodexUsageError.timedOut }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                lines += 1
                guard lines <= 1000, line.count <= 1_048_576,
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexUsageError.protocolError
                }
                guard (object["id"] as? Int) == id else { continue }
                if object["error"] != nil { throw CodexUsageError.serverError }
                guard let result = object["result"] as? [String: Any] else { throw CodexUsageError.protocolError }
                return result
            }
            guard buffer.count < 1_048_576 else { throw CodexUsageError.protocolError }
            let chunk = handle.availableData
            if chunk.isEmpty {
                throw Date().timeIntervalSince(started) >= 9 ? CodexUsageError.timedOut : CodexUsageError.protocolError
            }
            buffer.append(chunk)
        }
    }
}
