import Foundation
import Combine
import AppKit
import SINotchCore

@MainActor
final class UsageController: ObservableObject {
    @Published private(set) var sessions: [UsageSession] = []
    @Published private(set) var tasks: [UsageTask] = []
    @Published private(set) var catchingUp = false
    @Published private(set) var error = false
    @Published var selectedID: String?
    private let worker = UsageWorker()
    private var started = false
    init() {
        worker.onChange = { [weak self] rows, tasks, incomplete, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.sessions != rows { self.sessions = rows }
                if self.tasks != tasks { self.tasks = tasks }
                self.catchingUp = incomplete; self.error = error
            }
        }
    }
    func start(directory: URL? = nil, roots: [(String, URL)]? = nil) {
        guard !started else { return }; started = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let codex = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let pi = env["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".pi/agent")
        let piSessions = env["PI_CODING_AGENT_SESSION_DIR"].map { URL(fileURLWithPath: $0) } ?? pi.appendingPathComponent("sessions")
        worker.start(directory: directory ?? HistoryController.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Usage"),
                     roots: roots ?? [("codex", codex.appendingPathComponent("sessions")), ("codex", codex.appendingPathComponent("archived_sessions")), ("pi", piSessions)])
    }
    func record(_ event: AgentEvent) { if started { worker.record(event) } }
    func commit(_ event: AgentEvent, completion: @escaping (Bool) -> Void) {
        guard started else { completion(false); return }
        worker.record(event, completion: completion)
    }
    func task(session: String, turn: String?) -> UsageTask? {
        guard let turn else { return nil }
        let id = UsageTask.key(session: session, turn: turn)
        return tasks.first { $0.memberIDs.contains(id) }
    }
    func latestTask(session: String) -> UsageTask? { tasks.first { $0.sessionKey == session && !$0.unassigned } }
    func mergeTasks(_ ids: [String]) { worker.changeGroups(ids: ids) }
    func ungroup(_ id: String) { worker.changeGroups(remove: id) }
    func refresh() { if started { worker.refresh() } }
    func shutdown() { worker.shutdown() }
    func session(_ session: AgentSession) -> UsageSession? {
        let key = UsageSession.key(provider: session.provider, connection: session.connectionID, session: session.id)
        return sessions.first { $0.id == key }
    }
    func family(_ id: String) -> [UsageSession] {
        var ids: Set<String> = [id]
        for _ in 0..<32 {
            let children = sessions.filter { $0.parentID.map(ids.contains) == true }.map(\.id)
            let before = ids.count; ids.formUnion(children)
            if before == ids.count { break }
        }
        return sessions.filter { ids.contains($0.id) }
    }
    func total(_ rows: [UsageSession]) -> TokenCounts? {
        let counts = rows.compactMap(\.counts)
        return counts.isEmpty ? nil : counts.reduce(.zero) { $0.adding($1) }
    }
}

private final class UsageWorker {
    var onChange: (([UsageSession], [UsageTask], Bool, Bool) -> Void)?
    private let queue = DispatchQueue(label: "si-notch.usage", qos: .utility)
    private var store: UsageStore?
    private var scheduled: DispatchWorkItem?
    private var stopped = false
    func start(directory: URL, roots: [(String, URL)]) {
        queue.async { [self] in
            do { store = try UsageStore(directory: directory, roots: roots); publish(); run() }
            catch { publish(error: true) }
        }
    }
    func record(_ event: AgentEvent, completion: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            guard let store else { DispatchQueue.main.async { completion?(false) }; return }
            store.accept(event)
            guard let completion else { return }
            do { try store.flush(); DispatchQueue.main.async { completion(true) } }
            catch { store.restoreLastSaved(); publish(error: true); DispatchQueue.main.async { completion(false) } }
        }
    }
    func changeGroups(ids: [String]? = nil, remove: String? = nil) {
        queue.async { [self] in
            guard let store else { return }
            do {
                if let ids { try store.group(ids) }
                if let remove { try store.ungroup(remove) }
                publish()
            } catch { store.restoreLastSaved(); publish(error: true) }
        }
    }
    func refresh() { queue.async { [self] in scheduled?.cancel(); run() } }
    private func run() {
        guard !stopped, let store else { return }
        store.scan()
        do { try store.flush(); publish() } catch { store.restoreLastSaved(); publish(error: true) }
        let next = DispatchWorkItem { [weak self] in self?.run() }
        scheduled = next
        queue.asyncAfter(deadline: .now() + (store.incomplete ? 2 : 15), execute: next)
    }
    func shutdown() {
        queue.sync { [self] in stopped = true; scheduled?.cancel(); try? store?.flush() }
    }
    private func publish(error: Bool = false) {
        let rows = store?.sessions ?? []
        onChange?(rows, TaskUsageIndex(sessions: rows, groups: store?.state.groups ?? [:]).tasks,
                  store?.incomplete ?? false, error || (store?.sourceUnavailable ?? false))
    }
}
