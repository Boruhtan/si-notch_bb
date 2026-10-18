import Foundation
import Darwin
import SINotchCore
import SINotchTransport

private enum CLIError: Error, LocalizedError {
    case usage(String)
    case deliveryRejected(String)
    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .deliveryRejected(let message): return "Event was not accepted: \(message)"
        }
    }
}

private let help = """
si-notchctl — local agent bridge for si-notch

Usage:
  si-notchctl emit [JSON]                     Send an event; otherwise read stdin
  si-notchctl hook --agent claude             Read Claude hook JSON from stdin
  si-notchctl harness-hook --agent NAME --event EVENT
                                             Read Gemini, Copilot or Cursor hook JSON
  si-notchctl notify 'CODEX_JSON'             Read Codex notify JSON (last argument)
  si-notchctl request [JSON] [--timeout 60]    Ask for one explicit UI decision
  si-notchctl demo [--agent codex] [--session ID] [--delay 0.8]
  si-notchctl run --agent NAME [--session ID] [--title TITLE] -- command [args...]
  si-notchctl paths                           Print local IPC information as JSON
  si-notchctl status                          Read live receipt and session metadata
  si-notchctl --help

Global option: --socket /absolute/private/directory/events.sock (before run's --)
Default: $SI_NOTCH_SOCKET, otherwise ~/.si-notch/run/events.sock

emit accepts a JSON object with event, session_id and provider, or a supported
Claude hook / Codex notify payload. Maximum input: 128 KiB. It waits up to one
second for the app to acknowledge delivery.

request accepts the same envelope and sets event=approval.request and
await_response=true. It prints the app's JSON decision. Exit: 0 allow/answer, 1 deny,
2 invalid input / disconnected / timeout. A decision applies to this request only.
The calling integration must enforce the decision; si-notch never executes tools.

hook and notify are silent; harness-hook returns the harness's neutral JSON response.
All three are observation-only and fail open when disconnected.
They do not change agent settings or approve permission requests.
run forwards stdio, runs an executable directly (without a shell), reports its
exit status, and returns the child's exit code. Use --agent codex/claude/custom.
"""

private struct Arguments {
    var values: [String]
    mutating func option(_ name: String) throws -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard index + 1 < values.count else { throw CLIError.usage("Missing value for \(name)") }
        let value = values[index + 1]
        values.removeSubrange(index...index + 1)
        return value
    }
    mutating func requireNoOptions() throws {
        if let unknown = values.first(where: { $0.hasPrefix("--") }) {
            throw CLIError.usage("Unknown option \(unknown). See --help.")
        }
    }
}

private func readInput(_ argument: String?) throws -> Data {
    if let argument {
        let data = Data(argument.utf8)
        guard data.count <= IPCPaths.maximumMessageBytes else { throw IPCError.messageTooLarge }
        return data
    }
    guard isatty(STDIN_FILENO) == 0 else { throw CLIError.usage("Provide a JSON argument or pipe JSON into stdin.") }
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(8192, IPCPaths.maximumMessageBytes + 1 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        if data.count > IPCPaths.maximumMessageBytes { throw IPCError.messageTooLarge }
    }
    guard !data.isEmpty else { throw CLIError.usage("No JSON input received.") }
    return data
}

private func dictionary(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IPCError.invalidMessage }
    return value
}

private func json(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

private func writeJSON(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

private func sendObservation(_ data: Data, client: IPCClient) throws {
    // Observation events never ask for a permission decision. The ordinary app
    // acknowledgement proves the event reached receive() before this process exits.
    let outgoing = try json(SessionOrigin.enriching(dictionary(data), environment: ProcessInfo.processInfo.environment))
    guard let response = try client.send(outgoing, awaitReply: true, timeout: 1) else { throw IPCError.disconnected }
    let acknowledgement = try dictionary(response)
    guard acknowledgement["ok"] as? Bool == true else {
        throw CLIError.deliveryRejected(acknowledgement["error"] as? String ?? "the app rejected the event")
    }
}

private func sendEvent(_ object: [String: Any], client: IPCClient, silent: Bool = false) throws {
    let data = try json(object)
    _ = try AgentEvent.parse(data: data)
    if silent { try? sendObservation(data, client: client) } else { try sendObservation(data, client: client) }
}

/// A hook is an observer input, not an explicit content submission. Keep only
/// routing and lifecycle metadata before crossing the local IPC boundary.
private func hookObservation(_ raw: [String: Any], provider: String, timestamp: TimeInterval) -> [String: Any] {
    var observation: [String: Any] = ["provider": provider, "timestamp": timestamp]
    for key in ["hook_event_name", "session_id", "cwd", "notification_type", "tool_name",
                "tool_use_id", "agent_id", "agent_type", "subagent_id", "subagent_type",
                "model", "model_name", "reasoning_effort", "task_id", "task_subject", "task_description"] {
        if let value = raw[key] as? String { observation[key] = value }
    }
    return observation
}

private func event(_ kind: String, session: String, provider: String, title: String? = nil, message: String? = nil) -> [String: Any] {
    var value: [String: Any] = ["event": kind, "session_id": session, "provider": provider,
                              "id": UUID().uuidString, "timestamp": Date().timeIntervalSince1970,
                              "cwd": FileManager.default.currentDirectoryPath]
    if let title { value["title"] = title }
    if let message { value["message"] = message }
    return value
}

private func executable(_ command: String) throws -> URL {
    if command.contains("/") {
        let url = URL(fileURLWithPath: command, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/"))
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CLIError.usage("Executable not found: \(command)") }
        return url
    }
    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":", omittingEmptySubsequences: false) {
        let base = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
        let candidate = URL(fileURLWithPath: base).appendingPathComponent(command)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    throw CLIError.usage("Executable not found on PATH: \(command)")
}

private func runChild(_ values: [String], client: IPCClient) throws -> Int32 {
    guard let delimiter = values.firstIndex(of: "--"), delimiter + 1 < values.count else {
        throw CLIError.usage("run requires --agent NAME -- command [args...]")
    }
    var options = Arguments(values: Array(values[..<delimiter]))
    guard let provider = try options.option("--agent"), !provider.isEmpty else { throw CLIError.usage("run requires --agent NAME") }
    let session = try options.option("--session") ?? "run-" + UUID().uuidString
    let command = Array(values[(delimiter + 1)...])
    let title = try options.option("--title") ?? URL(fileURLWithPath: command[0]).lastPathComponent
    guard options.values.isEmpty else { throw CLIError.usage("Unknown run arguments: \(options.values.joined(separator: " "))") }
    // Validate before spawning even if the GUI is absent.
    _ = try AgentEvent.parse(data: json(event("session.start", session: session, provider: provider, title: title)))
    let process = Process()
    process.executableURL = try executable(command[0])
    process.arguments = Array(command.dropFirst())
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    process.environment = ProcessInfo.processInfo.environment.merging(["SI_NOTCH_SESSION_ID": session, "SI_NOTCH_PROVIDER": provider]) { _, new in new }
    try sendEvent(event("session.start", session: session, provider: provider, title: title), client: client, silent: true)
    do { try process.run() } catch {
        try? sendEvent(event("agent.failed", session: session, provider: provider, title: title, message: error.localizedDescription), client: client, silent: true)
        throw error
    }
    try? sendEvent(event("agent.working", session: session, provider: provider, title: title, message: "Process running"), client: client, silent: true)
    // Dispatch sources preserve forwarding while waitUntilExit blocks this thread.
    let signalQueue = DispatchQueue(label: "si-notchctl.signals")
    var sources = [DispatchSourceSignal]()
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler { if process.isRunning { kill(process.processIdentifier, number) } }
        source.resume()
        sources.append(source)
    }
    process.waitUntilExit()
    sources.forEach { $0.cancel() }
    let status = process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    try? sendEvent(event(status == 0 ? "agent.completed" : "agent.failed", session: session, provider: provider,
                         title: title, message: "Process exited with status \(status)"), client: client, silent: true)
    // Keep the final result visible; the user can dismiss the session in the island.
    return status
}

private func main() throws -> Int32 {
    let ingressTimestamp = Date().timeIntervalSince1970
    var values = Array(CommandLine.arguments.dropFirst())
    if values.isEmpty || values == ["--help"] || values == ["help"] || values == ["-h"] { print(help); return 0 }
    let command = values.removeFirst()
    // Global socket option never consumes arguments belonging to the wrapped executable.
    let delimiter = values.firstIndex(of: "--") ?? values.endIndex
    var options = Arguments(values: Array(values[..<delimiter]))
    let socketPath = try options.option("--socket") ?? IPCPaths.defaultSocketPath
    values = options.values + Array(values[delimiter...])
    let client = IPCClient(socketPath: socketPath)
    switch command {
    case "status":
        guard values.isEmpty else { throw CLIError.usage("status takes no arguments") }
        guard let response = try client.send(json(["command": "status", "protocol_version": 1]), awaitReply: true, timeout: 2) else { throw IPCError.disconnected }
        writeJSON(response)
    case "paths":
        guard values.isEmpty else { throw CLIError.usage("paths takes no arguments") }
        writeJSON(try json(["socket": socketPath, "protocol": "jsonl-v1", "max_message_bytes": IPCPaths.maximumMessageBytes]))
    case "emit":
        guard values.count <= 1 else { throw CLIError.usage("emit accepts one JSON argument, or stdin") }
        var object = try dictionary(readInput(values.first))
        if object["timestamp"] == nil { object["timestamp"] = ingressTimestamp }
        let data = try json(object)
        _ = try AgentEvent.parse(data: data)
        try sendObservation(data, client: client)
    case "hook":
        // Observation hooks always fail open and never write stdout or return a tool decision.
        do {
            var arguments = Arguments(values: values)
            let provider = try arguments.option("--agent") ?? "claude"
            guard arguments.values.isEmpty else { return 0 }
            let raw = try dictionary(readInput(nil))
            let object = hookObservation(raw, provider: provider, timestamp: ingressTimestamp)
            let data = try json(object)
            _ = try AgentEvent.parse(data: data)
            try? sendObservation(data, client: client)
        } catch { return 0 }
    case "harness-hook":
        var output = "{}"
        defer { print(output) }
        do {
            var arguments = Arguments(values: values)
            guard let provider = try arguments.option("--agent"),
                  let hook = try arguments.option("--event") else { return 0 }
            if provider == "cursor", hook == "beforeSubmitPrompt" { output = "{\"continue\":true}" }
            guard arguments.values.isEmpty else { return 0 }
            let raw = try dictionary(readInput(nil))
            if let event = try HarnessHook.observation(provider: provider, hook: hook, raw: raw,
                timestamp: Date(timeIntervalSince1970: ingressTimestamp)) {
                try? sendObservation(JSONEncoder().encode(event), client: client)
            }
        } catch { return 0 }
    case "notify":
        // Codex appends its JSON payload after configured command arguments.
        do {
            var object = try dictionary(readInput(values.last))
            if object["timestamp"] == nil { object["timestamp"] = ingressTimestamp }
            let data = try json(object)
            _ = try AgentEvent.parse(data: data)
            try? sendObservation(data, client: client)
        } catch { return 0 }
    case "request":
        var arguments = Arguments(values: values)
        let timeoutText = try arguments.option("--timeout") ?? "60"
        guard let timeout = Double(timeoutText), timeout >= 0.1, timeout <= 110 else {
            throw CLIError.usage("request --timeout must be between 0.1 and 110 seconds")
        }
        guard arguments.values.count <= 1 else { throw CLIError.usage("request accepts one JSON argument, or stdin") }
        var object = try dictionary(readInput(arguments.values.first))
        if object["timestamp"] == nil { object["timestamp"] = ingressTimestamp }
        object["event"] = "approval.request"
        object["approval_id"] = object["approval_id"] ?? UUID().uuidString
        object["request_id"] = object["request_id"] ?? object["approval_id"]
        guard let requestID = object["request_id"] as? String, !requestID.isEmpty, requestID.count <= 160 else {
            throw CLIError.usage("request_id must be a non-empty string of at most 160 characters")
        }
        object["await_response"] = true
        object["response_timeout"] = timeout
        object = SessionOrigin.enriching(object, environment: ProcessInfo.processInfo.environment)
        let data = try json(object)
        _ = try AgentEvent.parse(data: data)
        guard let response = try client.send(data, awaitReply: true, timeout: timeout) else { throw IPCError.disconnected }
        let decision = try dictionary(response)
        guard decision["request_id"] as? String == object["request_id"] as? String else {
            throw CLIError.usage("The app returned a decision for a different request.")
        }
        writeJSON(response)
        if decision["ok"] as? Bool == false { return 2 }
        if let value = decision["decision"] as? String {
            if value == "deny" { return 1 }
            if value == "answer" {
                let validAnswer = decision["ok"] as? Bool == true
                    && (decision["answer"] as? String).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
                return validAnswer ? 0 : 2
            }
            return value == "allow" || value == "allow-once" ? 0 : 2
        }
        return decision["allow"] as? Bool == true ? 0 : 2
    case "demo":
        var arguments = Arguments(values: values)
        let provider = try arguments.option("--agent") ?? "codex"
        let session = try arguments.option("--session") ?? "demo-" + UUID().uuidString
        let delayText = try arguments.option("--delay") ?? "0.8"
        guard let delay = Double(delayText), delay >= 0, delay <= 10, arguments.values.isEmpty else {
            throw CLIError.usage("demo accepts --agent NAME --session ID --delay SECONDS (0...10)")
        }
        let steps = [("session.start", "Demo session connected"), ("agent.working", "Planning a small change"),
                     ("tool.start", "Reading project files"), ("tool.finish", "Files inspected"),
                     ("agent.waiting", "Ready for your input"), ("agent.working", "Finishing the example"),
                     ("agent.completed", "Demo completed")]
        for (index, step) in steps.enumerated() {
            var value = event(step.0, session: session, provider: provider, title: "si-notch demo", message: step.1)
            if step.0.hasPrefix("tool.") { value["tool_name"] = "Read" }
            value["sequence"] = index
            try sendEvent(value, client: client)
            if index < steps.count - 1 && delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        print("Demo session: \(session)")
    case "run": return try runChild(values, client: client)
    default: throw CLIError.usage("Unknown command: \(command). See --help.")
    }
    return 0
}

do { exit(try main()) }
catch {
    if let command = CommandLine.arguments.dropFirst().first, command == "hook" || command == "notify" { exit(0) }
    FileHandle.standardError.write(Data("si-notchctl: \(error.localizedDescription)\n".utf8))
    exit(2)
}
