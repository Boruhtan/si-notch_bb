import Foundation
import Darwin

enum RemoteConnectionFailure: Equatable {
    case invalidHost
    case invalidPath
    case localSocketUnavailable
    case sshUnavailable
    case socketRecoveryFailed
    case connectionFailed(Int32)
}

enum RemoteConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case retrying
    case failed(RemoteConnectionFailure)
}

/// A user-started reverse Unix-socket forward. SSH owns authentication and host keys.
/// No SSH keys, passwords, or host configuration are written by si-notch.
struct RemoteSSHCommand {
    let host: String
    let remoteSocketPath: String
    let localSocketPath: String

    init(host: String, remoteSocketPath: String, localSocketPath: String) throws {
        try Self.validateHost(host)
        guard Self.validSocketPath(remoteSocketPath), Self.validSocketPath(localSocketPath) else {
            throw RemoteConnectionFailure.invalidPath
        }
        self.host = host
        self.remoteSocketPath = remoteSocketPath
        self.localSocketPath = localSocketPath
    }

    static func validateHost(_ host: String) throws {
        let parts = host.split(separator: "@", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 255, parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.first != "." &&
                  $0.utf8.allSatisfy(Self.validHostByte) }) else { throw RemoteConnectionFailure.invalidHost }
    }

    var arguments: [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         "-o", "ExitOnForwardFailure=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
         "-o", "RequestTTY=no", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
         "-o", "ControlPath=none", "-o", "ControlMaster=no", "-o", "ControlPersist=no",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
         "-o", "StreamLocalBindMask=0177", "-o", "StreamLocalBindUnlink=no",
         "-R", remoteSocketPath + ":" + localSocketPath, "--", host, "exec /bin/cat >/dev/null"]
    }

    private static func validHostByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
        (byte >= 48 && byte <= 57) || byte == 45 || byte == 46 || byte == 95
    }

    private static func validSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 100, !path.hasSuffix("/"),
              !path.contains(":"), !path.contains("\0"),
              !path.utf8.contains(where: { $0 < 32 || $0 == 127 }),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return true
    }
}

extension RemoteConnectionFailure: Error {}

enum RemoteSSHForwardConfirmation {
    static func matches(_ line: String, remoteSocketPath: String, localSocketPath: String) -> Bool {
        // OpenSSH -v prints this only after sshd acknowledges the -R request.
        // Its stream-local sentinel is -2 for both paths. Match both endpoints.
        line == "debug1: remote forward success for: listen \(remoteSocketPath):-2, connect \(localSocketPath):-2"
    }

    static func rejects(_ line: String, remoteSocketPath: String, localSocketPath: String) -> Bool {
        line == "debug1: remote forward failure for: listen \(remoteSocketPath):-2, connect \(localSocketPath):-2"
    }
}

@MainActor
final class RemoteConnectionController: ObservableObject {
    @Published var host: String { didSet { defaults?.set(host, forKey: "remoteSSHHost") } }
    @Published var remoteSocketPath: String { didSet { defaults?.set(remoteSocketPath, forKey: "remoteSSHSocketPath") } }
    @Published private(set) var state: RemoteConnectionState = .disconnected
    var pythonPath = "~/.hermes/hermes-agent/venv/bin/python"

    private let defaults: UserDefaults?
    private let sshExecutable: URL
    private let socketAvailable: (String) -> Bool
    private let retryDelays: [TimeInterval]
    private let recoverSocket: (RemoteSSHCommand, String) async throws -> Void
    private var process: Process?
    private var command: RemoteSSHCommand?
    private var generation: UInt64 = 0
    private var attempt = 0
    private var retryTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var forwardRejected = false
    private var recoveryAttempted = false
    private var errorPipe: Pipe?
    private var lifetimePipe: Pipe?
    private var diagnosticLine = Data()
    private var discardingLongLine = false

    init(defaults: UserDefaults? = .standard, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
         retryDelays: [TimeInterval] = [1, 2, 4], socketAvailable: @escaping (String) -> Bool = RemoteConnectionController.isSocketAvailable,
         recoverSocket: @escaping (RemoteSSHCommand, String) async throws -> Void = {
             try await RemoteHermesSetupClient(timeout: 15).recoverSocket($0, pythonPath: $1)
         }) {
        self.defaults = defaults
        self.sshExecutable = sshExecutable
        self.retryDelays = retryDelays
        self.socketAvailable = socketAvailable
        self.recoverSocket = recoverSocket
        host = defaults?.string(forKey: "remoteSSHHost") ?? ""
        remoteSocketPath = defaults?.string(forKey: "remoteSSHSocketPath") ?? ""
    }

    func connect(localSocketPath: String) {
        disconnect()
        do {
            let next = try RemoteSSHCommand(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                            remoteSocketPath: remoteSocketPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                            localSocketPath: localSocketPath)
            guard socketAvailable(localSocketPath) else { throw RemoteConnectionFailure.localSocketUnavailable }
            guard FileManager.default.isExecutableFile(atPath: sshExecutable.path) else { throw RemoteConnectionFailure.sshUnavailable }
            command = next
            attempt = 0
            launch()
        } catch let error as RemoteConnectionFailure {
            state = .failed(error)
        } catch {
            state = .failed(.sshUnavailable)
        }
    }

    func disconnect() {
        generation &+= 1
        retryTask?.cancel(); retryTask = nil
        readyTask?.cancel(); readyTask = nil
        diagnosticTask?.cancel(); diagnosticTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryAttempted = false
        try? lifetimePipe?.fileHandleForWriting.close()
        lifetimePipe = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        diagnosticLine.removeAll()
        discardingLongLine = false
        command = nil
        if let process, process.isRunning {
            process.terminate()
            // A host or wrapper that ignores SIGTERM must not leave a tunnel behind.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        state = .disconnected
    }

    private func launch() {
        guard let command else { return }
        generation &+= 1
        let token = generation
        forwardRejected = false
        let child = Process()
        child.executableURL = sshExecutable
        child.arguments = ["-v"] + command.arguments
        // EOF ends the remote command and SSH even if the application crashes.
        let lifetime = Pipe()
        lifetimePipe = lifetime
        child.standardInput = lifetime
        child.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        child.standardError = pipe
        let diagnostics = AsyncStream<Data> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; continuation.finish() }
                else { continuation.yield(data) }
            }
        }
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                await self.diagnosticTask?.value
                self.terminated(finished, token: token)
            }
        }
        state = attempt == 0 ? .connecting : .retrying
        do {
            try child.run()
            process = child
            errorPipe = pipe
            diagnosticLine.removeAll()
            discardingLongLine = false
            diagnosticTask = Task { [weak self] in
                for await data in diagnostics { self?.readDiagnostic(data, token: token) }
            }
            readyTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, !Task.isCancelled, self.generation == token,
                      self.state != .connected, child.isRunning else { return }
                child.terminate() // No forward confirmation within the bounded handshake window.
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? lifetime.fileHandleForWriting.close()
            lifetimePipe = nil
            scheduleRetry(status: -1, token: token)
        }
    }

    private func readDiagnostic(_ chunk: Data, token: UInt64) {
        guard generation == token, let command else { return }
        for byte in chunk {
            if byte == 10 {
                if !discardingLongLine {
                    let line = String(decoding: diagnosticLine, as: UTF8.self).trimmingCharacters(in: .newlines)
                    if process?.isRunning == true,
                       RemoteSSHForwardConfirmation.matches(line, remoteSocketPath: command.remoteSocketPath,
                                                            localSocketPath: command.localSocketPath) {
                        readyTask?.cancel(); readyTask = nil
                        state = .connected
                        recoveryAttempted = false
                    } else if RemoteSSHForwardConfirmation.rejects(line, remoteSocketPath: command.remoteSocketPath,
                                                                  localSocketPath: command.localSocketPath) {
                        forwardRejected = true
                    }
                }
                diagnosticLine.removeAll(keepingCapacity: true)
                discardingLongLine = false
            } else if !discardingLongLine {
                if diagnosticLine.count < 4096 { diagnosticLine.append(byte) }
                else {
                    diagnosticLine.removeAll(keepingCapacity: true)
                    discardingLongLine = true
                }
            }
        }
    }

    private func terminated(_ child: Process, token: UInt64) {
        guard generation == token else { return }
        if process === child { process = nil }
        try? lifetimePipe?.fileHandleForWriting.close()
        lifetimePipe = nil
        diagnosticTask?.cancel(); diagnosticTask = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        diagnosticLine.removeAll()
        discardingLongLine = false
        readyTask?.cancel(); readyTask = nil
        if child.terminationStatus == 255, forwardRejected, !recoveryAttempted, let command {
            recoveryAttempted = true
            state = .retrying
            let python = pythonPath
            recoveryTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.recoverSocket(command, python)
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.launch()
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.state = .failed(.socketRecoveryFailed)
                }
            }
            return
        }
        scheduleRetry(status: child.terminationStatus, token: token)
    }

    private func scheduleRetry(status: Int32, token: UInt64) {
        guard generation == token, command != nil else { return }
        guard attempt < retryDelays.count else { state = .failed(.connectionFailed(status)); return }
        let delay = retryDelays[attempt]
        attempt += 1
        state = .retrying
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.launch()
        }
    }

    nonisolated private static func isSocketAvailable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) && info.st_uid == getuid()
    }
}
