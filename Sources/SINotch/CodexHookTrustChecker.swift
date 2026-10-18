import Foundation

enum CodexHookTrustStatus: Equatable {
    case notInstalled
    case needsReview(trusted: Int, total: Int)
    case trusted
}

/// Reads the installed CLI's hooks/list result. This never writes trust state.
struct CodexHookTrustChecker {
    enum CheckError: Error { case invalidBinary, launchFailed, timedOut, protocolError, serverError }

    func check(binary: URL, command: String, cwd: String = FileManager.default.homeDirectoryForCurrentUser.path) async throws -> CodexHookTrustStatus {
        guard CodexBinaryLocator.isExecutable(binary) else { throw CheckError.invalidBinary }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.read(binary: binary, command: command, cwd: cwd)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func status(from result: [String: Any], command: String) throws -> CodexHookTrustStatus {
        guard let entries = result["data"] as? [[String: Any]] else { throw CheckError.protocolError }
        let expected = Set(CodexHookSetup.events.map { $0.prefix(1).lowercased() + $0.dropFirst() })
        var statuses: [String: Bool] = [:]
        for entry in entries {
            guard let hooks = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in hooks {
                guard hook["command"] as? String == command,
                      let event = hook["eventName"] as? String, expected.contains(event) else { continue }
                let trusted = hook["trustStatus"] as? String == "trusted" && hook["enabled"] as? Bool == true
                statuses[event] = (statuses[event] ?? false) || trusted
            }
        }
        if statuses.isEmpty { return .notInstalled }
        let trusted = expected.filter { statuses[$0] == true }.count
        return trusted == expected.count ? .trusted : .needsReview(trusted: trusted, total: expected.count)
    }

    private static func read(binary: URL, command: String, cwd: String) throws -> CodexHookTrustStatus {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CheckError.launchFailed }
        let started = Date()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        var reader = HookJSONLineReader(handle: output.fileHandleForReading)
        try write(["method": "initialize", "id": 1,
                   "params": ["clientInfo": ["name": "si_notch", "title": "si-notch", "version": "0.3.0"]]],
                  to: input.fileHandleForWriting)
        _ = try reader.result(for: 1, started: started)
        try write(["method": "initialized", "params": [:] as [String: String]], to: input.fileHandleForWriting)
        try write(["method": "hooks/list", "id": 2, "params": ["cwds": [cwd]]], to: input.fileHandleForWriting)
        return try status(from: reader.result(for: 2, started: started), command: command)
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private struct HookJSONLineReader {
    let handle: FileHandle
    private var buffer = Data()
    private var lines = 0

    init(handle: FileHandle) { self.handle = handle }

    mutating func result(for id: Int, started: Date) throws -> [String: Any] {
        while true {
            if Date().timeIntervalSince(started) > 8 { throw CodexHookTrustChecker.CheckError.timedOut }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                lines += 1
                guard lines <= 1000, line.count <= 1_048_576,
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexHookTrustChecker.CheckError.protocolError
                }
                guard object["id"] as? Int == id else { continue }
                if object["error"] != nil { throw CodexHookTrustChecker.CheckError.serverError }
                guard let result = object["result"] as? [String: Any] else { throw CodexHookTrustChecker.CheckError.protocolError }
                return result
            }
            guard buffer.count < 1_048_576 else { throw CodexHookTrustChecker.CheckError.protocolError }
            let chunk = handle.availableData
            if chunk.isEmpty { throw Date().timeIntervalSince(started) >= 7 ? CodexHookTrustChecker.CheckError.timedOut : CodexHookTrustChecker.CheckError.protocolError }
            buffer.append(chunk)
        }
    }
}
