import Foundation
import Combine
import SINotchCore

@MainActor
final class HistoryController: ObservableObject {
    @Published private(set) var records: [HistorySummary] = []
    @Published private(set) var selected: HistoryEntry?
    @Published private(set) var bytes = 0
    @Published private(set) var error = false
    @Published private(set) var loading = false
    @Published var search = ""
    @Published var visibleCount = 50
    private(set) var policy: HistoryPolicy
    private let worker = HistoryWorker()
    private var started = false
    private var selectionGeneration = 0
    init(policy: HistoryPolicy) {
        self.policy = policy
        worker.onChange = { [weak self] records, bytes, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.records = records; self.bytes = bytes; self.error = error; self.loading = false
                if let id = self.selected?.id {
                    if let summary = records.first(where: { $0.id == id }) { self.selected?.summary = summary }
                    else { self.back() }
                }
            }
        }
    }
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("si-notch/History", isDirectory: true)
    }
    var matching: [HistorySummary] {
        records.filter { search.isEmpty || "\($0.title) \($0.historyTitle) \($0.project ?? "") \($0.provider)".localizedCaseInsensitiveContains(search) }
    }
    func start(directory: URL = HistoryController.defaultDirectory, codexSessionsRoot: URL? = nil) {
        guard !started else { return }; started = true; loading = true
        worker.start(directory: directory, policy: policy, codexSessionsRoot: codexSessionsRoot)
    }
    func record(_ event: AgentEvent, session: AgentSession) {
        guard started, policy.enabled else { return }; worker.record(event, session: session)
    }
    func finish(_ event: AgentEvent) {
        guard started, policy.enabled else { return }; worker.finish(event)
    }
    func open(_ id: UUID) {
        selectionGeneration += 1; let generation = selectionGeneration
        selected = nil; loading = true
        worker.read(id) { [weak self] entry, error in
            DispatchQueue.main.async {
                guard let self, self.selectionGeneration == generation else { return }
                self.selected = entry; self.error = error; self.loading = false
            }
        }
    }
    func back() { selectionGeneration += 1; selected = nil; loading = false }
    func configure(_ value: HistoryPolicy) { policy = value; worker.configure(value) }
    func clear() { back(); worker.clear() }
    func shutdown() { worker.shutdown() }
}

/// All mutable storage state and scheduled writes are confined to one utility
/// queue. Main-actor objects receive immutable snapshots asynchronously.
private final class HistoryWorker {
    var onChange: (([HistorySummary], Int, Bool) -> Void)?
    private let queue = DispatchQueue(label: "si-notch.history", qos: .utility)
    private var store: HistoryStore?
    private var scheduled: DispatchWorkItem?
    private var snapshots: [String: (AgentEvent, AgentSession)] = [:]
    private var goalScanner: CodexGoalHistoryScanner?
    private var goalScanScheduled: DispatchWorkItem?
    private var stopped = false
    func start(directory: URL, policy: HistoryPolicy, codexSessionsRoot: URL?) {
        queue.async { [self] in
            do {
                let archive = try HistoryStore(directory: directory, policy: policy)
                store = archive
                publish()
                if policy.enabled, let codexSessionsRoot {
                    goalScanner = CodexGoalHistoryScanner(sessionsRoot: codexSessionsRoot)
                    let keys = Set(archive.ordered.filter {
                        $0.provider.lowercased() == "codex" && $0.turnID != nil &&
                            ![.completed, .failed, .ended].contains($0.status)
                    }.map(\.sessionKey))
                    if !keys.isEmpty {
                        // One utility-queue pass over only the affected sessions,
                        // reusing the scanner's bounded tails and file checks.
                        var scanner = CodexRolloutScanner(sessionsRoot: codexSessionsRoot,
                            includeContent: true, historySessionKeys: keys)
                        var changed = false
                        for observation in scanner.poll() where observation.isHistoryOnly {
                            if try archive.finish(observation.event) { changed = true }
                        }
                        if changed { try archive.flush(); publish() }
                    }
                    try reconcileGoals()
                }
            }
            catch { publish(error: true) }
        }
    }
    func record(_ event: AgentEvent, session: AgentSession) {
        queue.async { [self] in
            do {
                if event.id?.hasPrefix("desktop-stream:") == true {
                    // A Desktop delta carries the current turn, not an extra
                    // transcript item. Keep only its latest snapshot per turn.
                    if snapshots.count >= 16 { try drainSnapshots() }
                    let key = "\(event.connectionID ?? ""):\(event.sessionID):\(event.turnID ?? "")"
                    snapshots[key] = (event, session)
                } else {
                    guard try store?.accept(event, session: session) == true else { return }
                }
                if [.completed, .failed, .sessionEnded].contains(event.kind) { try flush(); return }
                guard scheduled == nil else { return }
                let work = DispatchWorkItem { [self] in
                    scheduled = nil
                    do { try flush() } catch { publish(error: true) }
                }
                scheduled = work; queue.asyncAfter(deadline: .now() + 2, execute: work)
            } catch { publish(error: true) }
        }
    }
    func read(_ id: UUID, completion: @escaping (HistoryEntry?, Bool) -> Void) {
        queue.async { [self] in
            do { completion(try store?.entry(id), false) } catch { completion(nil, true) }
        }
    }
    func finish(_ event: AgentEvent) {
        queue.async { [self] in
            do {
                try drainSnapshots()
                guard try store?.finish(event) == true else { return }
                try flush()
            } catch { publish(error: true) }
        }
    }
    func configure(_ value: HistoryPolicy) {
        queue.async { [self] in
            do { try drainSnapshots(); try store?.setPolicy(value); publish() } catch { publish(error: true) }
        }
    }
    func clear() {
        queue.async { [self] in
            scheduled?.cancel(); scheduled = nil
            goalScanScheduled?.cancel(); goalScanScheduled = nil
            do { try drainSnapshots(); try store?.clear(); publish() } catch { publish(error: true) }
        }
    }
    func shutdown() {
        // No synchronous worker→main hop exists. Drain buffered text on quit.
        queue.sync { [self] in
            stopped = true
            goalScanScheduled?.cancel(); goalScanScheduled = nil
            scheduled?.cancel(); scheduled = nil
            do { try drainSnapshots(); try store?.flush() } catch { publish(error: true) }
        }
    }
    private func drainSnapshots() throws {
        let pending = snapshots.values.sorted { $0.0.timestamp < $1.0.timestamp }
        snapshots.removeAll(keepingCapacity: true)
        for (event, session) in pending { _ = try store?.accept(event, session: session) }
    }
    private func flush() throws {
        scheduled?.cancel(); scheduled = nil
        try drainSnapshots(); try store?.flush(); publish()
        if goalScanScheduled == nil { try reconcileGoals() }
    }
    private func reconcileGoals() throws {
        guard !stopped, let store, store.policy.enabled, var scanner = goalScanner else { return }
        let completions = scanner.poll(targets: store.ordered)
        goalScanner = scanner
        var changed = false
        for completion in completions {
            if try store.finishGoal(completion) { changed = true }
        }
        if changed { try store.flush(); publish() }
        if scanner.hasPendingBytes {
            // Yield between bounded chunks so long goal transcripts cannot
            // monopolize history writes or delay shutdown.
            let work = DispatchWorkItem { [self] in
                goalScanScheduled = nil
                do { try reconcileGoals() } catch { publish(error: true) }
            }
            goalScanScheduled = work
            queue.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }
    private func publish(error: Bool = false) { onChange?(store?.ordered ?? [], store?.bytes ?? 0, error) }
}
