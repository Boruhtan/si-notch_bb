import AppKit
import CoreServices
import Darwin
import Foundation
import SINotchCore

struct PiSessionTarget: Equatable {
    struct TerminalTab: Equatable {
        let tty: String
        let pid: Int
    }

    let id: String
    let file: URL?
    let terminal: TerminalTab?
    let rex: RexTerminal.Block?

    init?(_ session: AgentSession) {
        guard session.provider == "pi" else { return nil }
        id = session.id
        if let rexSession = session.rexSessionID, let block = session.rexBlockID,
           session.terminalBundleID == RexTerminal.bundleID {
            rex = RexTerminal.Block(session: rexSession, block: block)
        } else {
            rex = nil
        }
        file = session.targetURL.flatMap { SessionRoute($0, scheme: "pi-session", host: "file") }
            .flatMap { Self.file(at: $0.path) }
        if let tty = session.terminalTTY, let pid = session.terminalPID, (1...Int(Int32.max)).contains(pid),
           session.terminalBundleID == SessionTerminal.bundleID,
           tty.range(of: #"\A/dev/ttys[0-9]{1,8}\z"#, options: .regularExpression) != nil {
            terminal = TerminalTab(tty: tty, pid: pid)
        } else {
            terminal = nil
        }
        guard file != nil || terminal != nil || rex != nil else { return nil }
    }

    static func route(for file: URL) -> String? {
        guard Self.file(at: file.path) != nil else { return nil }
        var parts = URLComponents()
        parts.scheme = "pi-session"
        parts.host = "file"
        parts.path = file.path
        return parts.string.flatMap { $0.utf8.count <= 4096 ? $0 : nil }
    }

    private static func file(at path: String) -> URL? {
        guard SessionTerminal.absolutePath(path) else { return nil }
        let file = URL(fileURLWithPath: path)
        return file.pathExtension == "jsonl" ? file : nil
    }

    // Read only the bounded header. A missing session file would otherwise make
    // Pi create a new session, and another file could belong to a different Pi run.
    func verifiedSessionFile() -> (url: URL, cwd: String?)? {
        guard let file else { return nil }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              let data = try? handle.read(upToCount: 16 * 1024), let newline = data.firstIndex(of: 10),
              let header = (try? JSONSerialization.jsonObject(with: Data(data[..<newline]))) as? [String: Any],
              header["type"] as? String == "session", header["id"] as? String == id else { return nil }
        let cwd = (header["cwd"] as? String).flatMap { SessionTerminal.absolutePath($0) ? $0 : nil }
        return (file, cwd)
    }

    func command() -> SessionTerminal.Command? {
        guard let file = verifiedSessionFile(),
              let pi = SessionTerminal.executable("pi") else { return nil }
        var directory: ObjCBool = false
        let cwd = file.cwd.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &directory) && directory.boolValue ? $0 : nil }
        return .init(program: pi, arguments: ["--session", file.url.path], workingDirectory: cwd)
    }
}

struct SessionRoute {
    let url: URL
    let path: String

    init?(_ raw: String, scheme: String, host: String) {
        guard let parts = URLComponents(string: raw), parts.scheme == scheme, parts.host == host,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              !parts.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = parts.url else { return nil }
        self.url = url
        path = parts.path
    }
}

enum SessionTerminal {
    static let bundleID = "com.apple.Terminal"

    struct Command: Equatable {
        let program: String
        let arguments: [String]
        var workingDirectory: String? = nil

        var shellLine: String { "exec " + ([program] + arguments).map(SessionTerminal.quote).joined(separator: " ") }
    }

    static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func executable(_ name: String) -> String? {
        HarnessDiscoveryService().scan().results.first { $0.id == name }?.primaryExecutablePath
    }

    @MainActor
    static func focus(_ terminal: PiSessionTarget.TerminalTab) -> Bool {
        let application = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              AEDeterminePermissionToAutomateTarget(application.aeDesc, typeWildCard, typeWildCard, false) == noErr,
              matchesRunningProcess(terminal) else { return false }
        // The validated TTY contains digits and cannot change this script.
        let source = """
        tell application id "com.apple.Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is "\(terminal.tty)" then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        let script = NSAppleScript(source: source)
        return script?.executeAndReturnError(nil).booleanValue == true
    }

    private static func matchesRunningProcess(_ terminal: PiSessionTarget.TerminalTab) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(terminal.pid), "-o", "uid=", "-o", "tty="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let fields = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
        guard process.terminationStatus == 0, fields.count == 2, fields[0] == String(getuid()) else { return false }
        return fields[1] == terminal.tty.dropFirst(5) || fields[1] == terminal.tty.dropFirst(8)
    }

    @MainActor
    static func launch(_ command: Command, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: bundleID),
              let directory = temporaryDirectory() else { completion(false); return }
        let file = directory.appendingPathComponent("Open agent session.command")
        let enterProject = command.workingDirectory.map { "cd -- " + quote($0) + " || exit\n" } ?? ""
        // The file is private, executable only by this user, and removed when
        // Terminal reads it. All command arguments are individually quoted.
        let script = """
        #!/bin/sh
        /bin/rm -f -- "$0"
        /bin/rmdir -- "${0%/*}" 2>/dev/null
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        \(enterProject)\(command.shellLine)
        """ + "\n"
        do {
            try Data(script.utf8).write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open([file], withApplicationAt: terminal, configuration: configuration) { app, error in
            let success = app != nil && error == nil
            if !success { try? FileManager.default.removeItem(at: directory) }
            Task { @MainActor in completion(success) }
        }
    }

    private static func temporaryDirectory() -> URL? {
        var name = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-open.XXXXXX").path.utf8CString
        return name.withUnsafeMutableBufferPointer { buffer in
            guard let path = buffer.baseAddress, mkdtemp(path) != nil else { return nil }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
    }
}
