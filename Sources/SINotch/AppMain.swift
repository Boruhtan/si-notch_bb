import AppKit
import Combine
import SwiftUI
import Carbon
import ServiceManagement
import SINotchCore
import SINotchTransport

@main
struct SINotchMain {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install-update" {
            exit(UpdateInstaller.run(receipt: URL(fileURLWithPath: CommandLine.arguments[2])))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var store = SessionStore()
    @Published var expanded = false
    @Published var paused = false
    @Published var serverError: AppDisplayError?
    @Published var receivedCount = 0
    @Published var providerReceipts: [String: Date] = [:]
    @Published var connectionReceipts: [String: AgentConnection.Observation] = [:]
    @Published var activity: [String: [SessionActivity]] = [:]
    @Published var selectedID: String?
    @Published var pending: [String: PendingRequest] = [:]
    @Published var navigationErrorID: String?
    var sessionNavigator: any SessionNavigating = SessionNavigator()
    private var navigationGeneration = 0
    @Published var settingsError: AppDisplayError?
    @Published var activeFilter = "Все" {
        didSet { if oldValue != activeFilter { sessionQueryChanged() } }
    }
    @Published var search = "" {
        didSet { if oldValue != search { sessionQueryChanged() } }
    }
    @Published var showAgents = false
    @Published var detectedHarnesses: [HarnessDetection] = []
    @Published var runningAgentProviders: Set<String> = []
    @Published var presenceNow = Date()
    var appOwnedTitles: [String: String] = [:]
    var appOwnedMessages: [String: String] = [:]
    var measuredSessionHeights: [String: CGFloat] = [:]
    @Published var revision = 0
    @Published var cameraWidth: CGFloat = 190
    @Published var headerHeight: CGFloat = 36
    @Published var expandedPanelWidth: CGFloat = 680
    @Published var expandedPanelHeight: CGFloat = 210
    var server: IPCServer?
    var codexObserver: CodexSessionObserver?
    var piObserver: PiSessionObserver?
    let remoteConnections: RemoteConnectionManager
    private var remoteSubscription: AnyCancellable?
    var onLayout: (() -> Void)?
    var openSettings: (() -> Void)?
    var openIntegrations: (() -> Void)?
    var openRemoteConnections: (() -> Void)?
    var closeSettings: (() -> Void)?
    var focusPanel: (() -> Void)?
    var timer: Timer?
    var expansionTimer: Timer?
    var revealTimer: Timer?
    private var hoverIntent: HoverIntent?
    var hoverLocation: () -> CGPoint = { NSEvent.mouseLocation }
    var hoverRegion: CGRect?
    var compactHoverRegion: CGRect?
    private var hoverCooldownUntil: TimeInterval = 0
    private(set) var expansionHistory: [[String: Any]] = []
    private var expansionGeneration: UInt64 = 0
    private var revealGeneration: UInt64 = 0
    private var expansionOrigin: IslandExpansionOrigin = .manual
    private var expandedHeightFloor: CGFloat = 0
    private var codexServiceSessions = CodexServiceSessionFilter()
    private var observedAttention: [String: (id: String, seenAt: TimeInterval)] = [:]
    var pointerInside = false
    var reminders = FollowUpReminders()
    var presentationPolicy: PresentationPolicy?
    var transientMessage: String?
    let defaults: UserDefaults
    let soundPlayer: EventSoundPlayer
    private var sessionSounds = SessionSoundPolicy()
    private var presenceObservers: [NSObjectProtocol] = []

    struct PendingRequest {
        let token = UUID().uuidString
        let expiresAt: TimeInterval
        let sessionID: String
        let requestID: String
        let message: String
        let messageIsAppOwned: Bool
        let question: Bool
        let receivedAt: Date
        let reply: (Data) -> Void
    }

    var sessionFilter: SessionFilter { SessionFilter(directories: defaults.string(forKey: "blockedDirectories") ?? "", promptPrefixes: defaults.string(forKey: "blockedPromptPrefixes") ?? "") }
    var sessions: [AgentSession] { store.orderedSessions.filter { AgentConnection.isTask($0) && !sessionFilter.hides(path: $0.projectPath, firstPrompt: $0.firstPrompt) } }
    var agents: [AgentConnection] {
        AgentConnection.project(detected: detectedHarnesses, sessions: store.orderedSessions,
            receipts: providerReceipts, running: runningAgentProviders, now: presenceNow, connections: connectionReceipts, configurations: remoteConnections.agentConfigurations)
    }
    var agentsSectionHeight: CGFloat { 40 }
    func displayTitle(_ session: AgentSession) -> String {
        guard let key = appOwnedTitles[session.id], session.title == key else { return session.title }
        return L10n.tr(key)
    }
    func displayMessage(_ session: AgentSession, _ message: String) -> String {
        guard let key = appOwnedMessages[session.id], message == key else { return message }
        return L10n.tr(key)
    }
    var filtered: [AgentSession] {
        sessions.filter { s in
            let matchesFilter = activeFilter == "Все" || (activeFilter == "В работе" && s.status == .working) || (activeFilter == "Внимание" && [.approval, .waiting, .failed].contains(s.status)) || (activeFilter == "Готово" && s.status == .completed)
            let matchesSearch = search.isEmpty || "\(s.title) \(s.provider) \(s.projectPath ?? "")".localizedCaseInsensitiveContains(search)
            return matchesFilter && matchesSearch
        }
    }
    var dominantStatus: AgentStatus {
        if serverError != nil { return .failed }
        for status: AgentStatus in [.approval, .waiting, .failed, .working, .completed] {
            if sessions.contains(where: { $0.status == status }) { return status }
        }
        return .idle
    }
    let compactWingWidth: CGFloat = 26
    let compactStatusWidth: CGFloat = 18
    let compactShoulderWidth: CGFloat = 3
    var desiredPanelHeight: CGFloat {
        if showAgents {
            let groups = remoteConnections.connections.filter(\.showInAgents).count
            return headerHeight + 92 + CGFloat(min(5, max(2, agents.count + groups))) * 32
        }
        if sessions.isEmpty { return headerHeight + (quiet ? 166 : 142) + agentsSectionHeight }
        let filters: CGFloat = 38
        let searchHeight: CGFloat = sessions.count > 3 || !search.isEmpty ? 44 : 0
        let footer: CGFloat = quiet || sessions.contains(where: { $0.status == .completed || $0.status == .failed }) ? 32 : 0
        let cards = filtered.prefix(4).reduce(0.0) { height, session in
            let estimate = SessionCardContent(session: session, displayTitle: displayTitle(session),
                displayMessage: session.lastMessage.map { displayMessage(session, $0) })
                .estimatedCollapsedHeight(fontSize: defaults.double(forKey: "fontSize"),
                                          showActivity: defaults.bool(forKey: "showActivity"),
                                          showModel: defaults.bool(forKey: "showModel"),
                                          showReasoning: defaults.bool(forKey: "showReasoning"))
            return height + (measuredSessionHeights[session.id] ??
                            (estimate + (selectedID == session.id || pending[session.id] != nil ? 100 : 0))) + 2
        }
        return headerHeight + 14 + filters + searchHeight + footer + agentsSectionHeight + (filtered.isEmpty ? 78 : cards)
    }

    func panelHeight(limitedTo maximum: CGFloat) -> CGFloat {
        // Keep the bottom navigation under the pointer while content changes.
        // A new expansion starts at the current content's natural height.
        let height = min(maximum, max(desiredPanelHeight, expanded ? expandedHeightFloor : 0))
        expandedHeightFloor = expanded ? height : 0
        return height
    }

    func selectAgents(_ value: Bool) {
        showAgents = value
        setExpanded(true)
        onLayout?()
    }

    private func sessionQueryChanged() {
        // Filters sit at the top, so their hit targets stay put while the panel
        // resizes. Do not wait for a card measurement or the next agent event.
        expandedHeightFloor = 0
        cancelExpansionTimer()
        cancelRevealTimer()
        onLayout?()
    }

    func measureSessionCards(_ values: [String: CGFloat]) {
        let valid = values.filter { store.sessions[$0.key] != nil && $0.value.isFinite && (30...10000).contains($0.value) }
        guard valid.contains(where: { abs((measuredSessionHeights[$0.key] ?? 0) - $0.value) > 0.5 }) else { return }
        measuredSessionHeights = measuredSessionHeights.filter { store.sessions[$0.key] != nil }
        measuredSessionHeights.merge(valid) { _, new in new }
        onLayout?()
    }
    var attentionCount: Int { sessions.filter { [.approval, .waiting, .failed].contains($0.status) }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var presentationState: IslandPresentationState {
        IslandPresentationState(hasSessions: !sessions.isEmpty, hasWorkingSessions: workingCount > 0,
            hasPendingRequest: !pending.isEmpty, pointerInside: pointerInside,
            isExpanded: expanded, keepOpen: defaults.bool(forKey: "keepOpen"))
    }
    var showHover: Bool { defaults.object(forKey: "hoverExpand") as? Bool ?? true }
    var quiet: Bool { defaults.bool(forKey: "quiet") }
    var socketPath: String { ProcessInfo.processInfo.environment["SI_NOTCH_SOCKET"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".si-notch/run/events.sock").path }

    init(defaults: UserDefaults = .standard, soundPlayer: EventSoundPlayer? = nil) {
        self.defaults = defaults
        self.remoteConnections = RemoteConnectionManager(defaults: defaults)
        self.soundPlayer = soundPlayer ?? EventSoundPlayer(defaults: defaults)
        remoteSubscription = remoteConnections.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.revision += 1; self?.onLayout?() }
        }
        defaults.register(defaults: ["codexAutoDetect": true, "updateBackgroundChecks": true])
        defaults.register(defaults: PresentationPolicy.registeredDefaults)
        defaults.register(defaults: DisplayPreferences.defaults)
        defaults.register(defaults: ["hoverExpand": true, "autoExpand": true, "sound": false, "soundVolume": 0.3, "soundWorking": false, "idleMinutes": 120, "showCompanion": true, "hoverDelay": IslandTiming.hoverEnter, "revealDwell": 5.0, "completionReveal": false, "attentionReveal": true, "shortcutEnabled": true, "shortcutModifier": "ctrlAlt"])
    }

    func start() {
        detectedHarnesses = HarnessDiscoveryService().scan().detected
        refreshAgentPresence()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            presenceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAgentPresence() }
            })
        }
        do {
            let ipc = IPCServer(socketPath: socketPath, onMessage: { [weak self] data, reply in
                DispatchQueue.main.async { self?.receive(data, reply: { reply($0) }) }
            })
            try ipc.start()
            server = ipc
            serverError = nil
            remoteConnections.restoreConnections(localSocketPath: socketPath)
        } catch { serverError = .channel(error.localizedDescription) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.2
        refreshCodexObserver()
        piObserver = PiSessionObserver { [weak self] event, bootstrap in
            Task { @MainActor in
                guard let self, self.pending[event.sessionID] == nil,
                      !bootstrap || self.store.sessions[event.sessionID] == nil,
                      let data = try? JSONEncoder().encode(event) else { return }
                self.receive(data, suppressPresentation: bootstrap, reply: { _ in })
            }
        }
        piObserver?.start()
    }

    func refreshCodexObserver() {
        guard defaults.bool(forKey: "codexAutoDetect") else { codexObserver?.stop(); return }
        if codexObserver == nil {
            codexObserver = CodexSessionObserver { [weak self] event, bootstrap in
                Task { @MainActor in
                    self?.receiveCodexObservation(event, bootstrap: bootstrap)
                }
            }
        }
        codexObserver?.start()
    }

    func receiveCodexObservation(_ event: AgentEvent, bootstrap: Bool) {
        guard defaults.bool(forKey: "codexAutoDetect"), pending[event.sessionID] == nil else { return }
        let previous = store.sessions[event.sessionID]
        let nativeSnapshot = event.id?.hasPrefix("desktop-stream:") == true
        let rolloutStart = event.turnID.map { turn in
            event.id == "rollout:\(turn):start" || event.id == "rollout:\(turn):bootstrap"
        } ?? false
        // SessionEnd from a CLI process closes that process, not the durable
        // conversation. Only a fresh, identified turn may reopen it. Keep the
        // reducer's terminal-state protection for arbitrary late tool events.
        let reopens = previous?.status == .ended && event.turnID != nil &&
            [.working, .waiting].contains(event.kind) && (nativeSnapshot || rolloutStart) &&
            event.timestamp >= (previous?.lastEventAt ?? .distantFuture)
        let freshRolloutTurn = rolloutStart && event.kind == .working &&
            event.timestamp >= (previous?.lastEventAt ?? .distantFuture)
        guard !bootstrap || previous == nil || nativeSnapshot || freshRolloutTurn else { return }
        if reopens {
            var start = event
            start.kind = .sessionStarted; start.id = event.id.map { $0 + ":reopen" }
            start.title = nil; start.message = nil; start.firstPrompt = nil
            start.attentionRequestID = nil
            if let data = try? JSONEncoder().encode(start) { receive(data, suppressPresentation: true, reply: { _ in }) }
        }
        var update = event
        if update.id?.hasPrefix("desktop:") == true, previous != nil { update.title = nil }
        guard let data = try? JSONEncoder().encode(update) else { return }
        receive(data, suppressPresentation: bootstrap, reply: { _ in })
    }

    func receive(_ data: Data, suppressPresentation: Bool = false, reply: @escaping (Data) -> Void) {
        if let control = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           control.count == 2, control["command"] as? String == "status",
           control["protocol_version"] as? Int == 1 {
            reply(json(["ok": true, "protocol_version": 1, "received_count": receivedCount,
                        "paused": paused, "session_count": sessions.count,
                        "visible_session_count": showAgents ? 0 : filtered.count, "active_filter": activeFilter, "tab": showAgents ? "agents" : "sessions",
                        "agents": agents.map { ["id": $0.id, "provider": $0.provider, "name": $0.name, "state": $0.state.rawValue,
                            "activity": $0.activity.rawValue, "active_task_count": $0.activeTaskCount,
                            "last_seen": $0.lastSeen.map { $0.timeIntervalSince1970 as Any } ?? NSNull()] as [String: Any] },
                        "remote_connections": remoteConnections.connections.map { ["id": $0.id.uuidString, "name": $0.displayName,
                            "status": remoteConnections.state($0.id).statusName] },
                        "expanded": expanded, "expansion_history": expansionHistory,
                        "providers": providerReceipts.mapValues { $0.timeIntervalSince1970 },
                        "sessions": sessions.map { ["id": $0.id, "provider": $0.provider, "status": $0.status.rawValue] }]))
            return
        }
        guard !paused else { reply(json(["ok": false, "error": "paused"])); return }
        do {
            let event = try AgentEvent.parse(data: data)
            if event.provider.lowercased() == "pi", event.id?.hasPrefix("pi-file:") != true {
                piObserver?.markHookObserved(sessionID: event.sessionID)
            }
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let waitingForReply = raw["await_response"] as? Bool == true
            if event.kind == .agentPresence {
                guard !waitingForReply else { reply(json(["ok": false, "error": "invalid_presence"])); return }
                presenceNow = Date()
                let applied = noteConnection(event, at: presenceNow)
                receivedCount += 1
                if applied {
                    providerReceipts[event.provider.lowercased()] = presenceNow
                    revision += 1
                    onLayout?()
                }
                reply(json(["ok": true, "disposition": applied ? "applied" : "duplicate"]))
                return
            }
            let previous = store.sessions[event.sessionID]
            if waitingForReply {
                let rid = raw["request_id"] as? String ?? ""
                let timeout = raw["response_timeout"] as? Double ?? 60
                guard [.approvalRequested, .waiting].contains(event.kind),
                      !rid.isEmpty, rid.count <= 160,
                      rid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0) }),
                      timeout.isFinite, (0.1...110).contains(timeout) else {
                    reply(json(["ok": false, "decision": "invalid_request", "request_id": rid])); return
                }
                guard pending[event.sessionID] != nil || pending.count < 8 else {
                    reply(json(["ok": false, "decision": "busy", "request_id": rid])); return
                }
            }
            let oldStatus = store.sessions[event.sessionID]?.status
            let oldAttention = attentionIdentity(event.sessionID)
            let previousObservedAttention = observedAttention[event.sessionID]?.id
            var nextStore = store
            let disposition = nextStore.apply(event)
            receivedCount += 1
            guard disposition != .invalid else { reply(json(["ok": false, "error": "session_provider_conflict"])); return }
            if disposition == .applied, codexServiceSessions.hides(event) {
                // Native source classifies the whole session, including a card
                // discovered before provenance arrived. Prompt-only suggestions
                // can instead be a background turn reusing a genuine user task.
                let hasUserTask = event.isInternalSession != true &&
                    (previous?.firstPrompt.map { !CodexServiceSessionFilter.isSuggestionRequest($0) } ?? false)
                if !hasUserTask {
                    dismiss(event.sessionID)
                    activity[event.sessionID] = nil
                    measuredSessionHeights[event.sessionID] = nil
                }
                reply(json(["ok": !waitingForReply, "disposition": "filtered", "decision": "filtered",
                            "request_id": raw["request_id"] as? String ?? ""]))
                return
            }
            if disposition == .applied, sessionFilter.hides(path: event.projectPath ?? previous?.projectPath, firstPrompt: previous?.firstPrompt ?? event.firstPrompt) {
                dismiss(event.sessionID)
                reply(json(["ok": !waitingForReply, "disposition": "filtered", "decision": "filtered", "request_id": raw["request_id"] as? String ?? ""]))
                return
            }
            store = nextStore
            if disposition == .applied {
                if !suppressPresentation {
                    presenceNow = Date()
                    providerReceipts[event.provider.lowercased()] = presenceNow
                    _ = noteConnection(event, at: presenceNow)
                }
                if let item = SessionActivity(event) {
                    var history = activity[event.sessionID] ?? []
                    if history.last?.kind != item.kind || history.last?.tool != item.tool || history.last?.message != item.message {
                        history.append(item)
                        activity[event.sessionID] = Array(history.suffix(12))
                    }
                }
                activity = activity.filter { store.sessions[$0.key] != nil }
            }
            if raw["title"] != nil { appOwnedTitles[event.sessionID] = nil }
            if raw["message"] != nil { appOwnedMessages[event.sessionID] = nil }
            let supersedesDecision: Set<AgentEventKind> = [.sessionStarted, .working, .toolStarted, .toolFinished, .toolFailed, .waiting, .approvalRequested, .completed, .failed, .sessionEnded]
            if disposition == .applied && supersedesDecision.contains(event.kind) { cancelRequest(event.sessionID) }
            if waitingForReply && disposition == .applied && [.approval, .waiting].contains(store.sessions[event.sessionID]?.status ?? .idle), let rid = raw["request_id"] as? String, !rid.isEmpty, rid.count <= 160 {
                guard pending.count < 8 else { reply(json(["ok": false, "decision": "busy", "request_id": rid])); return }
                let requestedTimeout = raw["response_timeout"] as? Double ?? 60
                guard requestedTimeout.isFinite, (0.1...110).contains(requestedTimeout) else { reply(json(["ok": false, "decision": "invalid_timeout", "request_id": rid])); return }
                pending[event.sessionID] = PendingRequest(expiresAt: ProcessInfo.processInfo.systemUptime + requestedTimeout, sessionID: event.sessionID, requestID: rid, message: raw["message"] as? String ?? raw["prompt"] as? String ?? "Агент ожидает ответа", messageIsAppOwned: raw["message"] == nil && raw["prompt"] == nil, question: raw["question"] as? Bool == true, receivedAt: Date(), reply: reply)
            } else { reply(json(["ok": true, "disposition": String(describing: disposition)])) }
            if disposition == .applied, let status = store.sessions[event.sessionID]?.status, ![.approval, .waiting].contains(status) { cancelRequest(event.sessionID) }
            if disposition == .applied { presentationPolicy?.noteActivity() }
            let newStatus = store.sessions[event.sessionID]?.status
            if disposition == .applied {
                if let id = event.attentionRequestID {
                    observedAttention[event.sessionID] = (id, ProcessInfo.processInfo.systemUptime)
                } else if event.id?.hasPrefix("desktop-stream:") == true ||
                            [.sessionStarted, .working, .completed, .failed, .sessionEnded].contains(event.kind) {
                    observedAttention[event.sessionID] = nil
                }
                let newAttention = attentionIdentity(event.sessionID)
                if !suppressPresentation, let status = newStatus,
                   oldStatus != newStatus || oldAttention != newAttention {
                    reminders.update(id: event.sessionID, status: status, now: ProcessInfo.processInfo.systemUptime,
                        delay: defaults.double(forKey: "followupMinutes") * 60, includeCompleted: defaults.bool(forKey: "followupCompleted"))
                    let repeatedObservation = event.attentionRequestID != nil && event.attentionRequestID == previousObservedAttention
                    let needsAnswer = newAttention != nil && newAttention != oldAttention && !repeatedObservation && defaults.bool(forKey: "attentionReveal")
                    let completed = status == .completed && oldStatus != status && defaults.bool(forKey: "completionReveal")
                    if (needsAnswer || completed), !quiet, defaults.bool(forKey: "autoExpand"),
                       presentationPolicy?.canAutomaticallyReveal(for: store.sessions[event.sessionID]) ?? true { reveal(reason: needsAnswer ? "response-needed" : "completed") }
                }
                if oldAttention != nil, newAttention == nil { resumeAutoDismiss() }
            }
            if disposition == .applied, let status = newStatus,
               let cue = sessionSounds.consume(event, status: status, restoring: suppressPresentation) {
                soundPlayer.play(cue: cue, sessionID: event.sessionID,
                    enabled: defaults.bool(forKey: "sound"), quiet: quiet,
                    volume: defaults.double(forKey: "soundVolume"),
                    workingEnabled: defaults.bool(forKey: "soundWorking"))
            }
            revision += 1
            onLayout?()
        } catch { reply(json(["ok": false, "error": "invalid_event", "message": L10n.eventError(error)])) }
    }

    private func noteConnection(_ event: AgentEvent, at receivedAt: Date) -> Bool {
        guard let connectionID = event.connectionID else { return false }
        let provider = event.provider.lowercased()
        let key = provider + "/" + connectionID
        if let previous = connectionReceipts[key] {
            guard event.timestamp >= previous.eventAt,
                  event.id == nil || event.id != previous.eventID else { return false }
        }
        if connectionReceipts[key] == nil, connectionReceipts.count >= 256,
           let oldest = connectionReceipts.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            connectionReceipts.removeValue(forKey: oldest)
        }
        let name = event.connectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionReceipts[key] = AgentConnection.Observation(provider: provider, connectionID: connectionID,
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? provider, lastSeen: receivedAt,
            eventAt: event.timestamp, eventID: event.id)
        return true
    }

    func tick(at monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        var changed = false
        let visibleBefore = sessions.map { $0.id }
        let now = Date()
        let currentAgents = AgentConnection.project(detected: detectedHarnesses, sessions: store.orderedSessions,
            receipts: providerReceipts, running: runningAgentProviders, now: now, connections: connectionReceipts, configurations: remoteConnections.agentConfigurations)
        if currentAgents != agents { presenceNow = now }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let foreground = Set(sessions.filter { $0.terminalBundleID != nil && $0.terminalBundleID == frontBundle }.map(\.id))
        let due = reminders.due(now: monotonicNow, states: Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) }), foregroundIDs: defaults.bool(forKey: "suppressWhenTargetAppFrontmost") ? foreground : [])
        let eligibleReminder = due.contains { id in
            guard let session = store.sessions[id] else { return false }
            let enabled = session.status == .completed
                ? defaults.bool(forKey: "followupCompleted") && defaults.bool(forKey: "completionReveal")
                : defaults.bool(forKey: "attentionReveal")
            let actionable = session.status == .completed || attentionIdentity(id, at: monotonicNow) != nil
            return enabled && actionable && (presentationPolicy?.canAutomaticallyReveal(for: session) ?? true)
        }
        if !quiet && !expanded && defaults.bool(forKey: "autoExpand") && defaults.double(forKey: "followupMinutes") > 0 && eligibleReminder { presentationPolicy?.noteActivity(); reveal(reason: "reminder") }
        for (id, request) in pending where monotonicNow >= request.expiresAt {
            request.reply(json(["ok": false, "decision": "timeout", "request_id": request.requestID]))
            pending.removeValue(forKey: id)
            changed = true
        }
        // Retain identity after its freshness lease so a delayed heartbeat of
        // the same unresolved question cannot become a new reveal. Eligibility
        // still expires after 45 s; terminal events and removal clear identity.
        observedAttention = observedAttention.filter { store.sessions[$0.key] != nil }
        if changed { resumeAutoDismiss() }
        let timeout = defaults.integer(forKey: "idleMinutes")
        // A mutating call on @Published sends objectWillChange even if the
        // reducer leaves every session untouched. Publish actual changes only.
        var nextStore = store
        let expired = timeout > 0 ? nextStore.expireStaleSessions(now: now, timeout: Double(timeout) * 60) : []
        let pruned = nextStore.pruneSessions(now: now, retention: 24 * 60 * 60)
        if !expired.isEmpty || !pruned.isEmpty {
            store = nextStore
            for id in expired { cancelRequest(id) }
        }
        if let selectedID, !sessions.contains(where: { $0.id == selectedID }) { self.selectedID = nil; changed = true }
        if changed || visibleBefore != sessions.map({ $0.id }) { revision += 1; onLayout?() }
    }

    private func refreshAgentPresence() {
        let applications = NSWorkspace.shared.runningApplications
        let running = AgentConnection.runningProviders(detected: detectedHarnesses,
            applicationPaths: Set(applications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }),
            bundleIdentifiers: Set(applications.compactMap(\.bundleIdentifier)))
        if running != runningAgentProviders { runningAgentProviders = running; onLayout?() }
    }

    func respond(_ id: String, expectedToken: String, decision: String, answer: String? = nil) {
        guard let request = pending[id], request.token == expectedToken else { return }
        guard ProcessInfo.processInfo.systemUptime < request.expiresAt else { cancelRequest(id); return }
        guard [.approval, .waiting].contains(store.sessions[id]?.status ?? .idle) else { cancelRequest(id); return }
        guard ["allow", "deny", "answer"].contains(decision) else { return }
        pending.removeValue(forKey: id)
        var response: [String: Any] = ["ok": true, "decision": decision, "request_id": request.requestID]
        if let answer { response["answer"] = answer }
        request.reply(json(response))
        let messageKey = decision == "deny" ? "Вы отклонили действие" : decision == "answer" ? "Вы выбрали ответ. Ожидаем событие агента." : "Вы разрешили этот запрос. Ожидаем событие агента."
        inject(["event": "waiting", "session_id": id, "provider": store.sessions[id]?.provider ?? "custom", "message": messageKey], appOwnedMessageKey: messageKey)
        resumeAutoDismiss()
    }
    func cancelRequest(_ id: String) {
        if let p = pending.removeValue(forKey: id) { p.reply(json(["ok": false, "decision": "cancelled", "request_id": p.requestID])) }
    }
    func attentionIdentity(_ id: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        if let request = pending[id], now < request.expiresAt { return "reply:\(request.requestID)" }
        guard let request = observedAttention[id], (0..<45).contains(now - request.seenAt),
              let status = store.sessions[id]?.status, ![.completed, .failed, .ended].contains(status) else { return nil }
        return request.id
    }
    private func resumeAutoDismiss() {
        guard expanded, expansionOrigin == .automatic, !pointerInside,
              pending.isEmpty, !sessions.contains(where: { attentionIdentity($0.id) != nil }) else { return }
        reveal()
    }
    func dismiss(_ id: String) { reminders.cancel(id); cancelRequest(id); observedAttention[id] = nil; store.removeSession(id: id); appOwnedTitles[id] = nil; appOwnedMessages[id] = nil; if selectedID == id { selectedID = nil }; revision += 1; onLayout?() }
    func reconcileFilters() {
        for session in store.orderedSessions where sessionFilter.hides(path: session.projectPath, firstPrompt: session.firstPrompt) {
            dismiss(session.id)
        }
    }
    func clearFinished() { for s in sessions where [.completed, .failed, .ended].contains(s.status) { dismiss(s.id) } }
    func inject(_ object: [String: Any], appOwnedTitleKey: String? = nil, appOwnedMessageKey: String? = nil) {
        receive(json(object), reply: { _ in })
        if let id = object["session_id"] as? String {
            if let appOwnedTitleKey { appOwnedTitles[id] = appOwnedTitleKey }
            if let appOwnedMessageKey { appOwnedMessages[id] = appOwnedMessageKey }
        }
    }
    func json(_ object: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) }
    func setExpanded(_ value: Bool, origin: IslandExpansionOrigin = .manual, reason: String? = nil) {
        cancelExpansionTimer()
        cancelRevealTimer()
        if !value { expandedHeightFloor = 0 }
        if value { expansionOrigin = origin }
        guard expanded != value else { presentationPolicy?.expansionChanged(value, origin: origin); return }
        if !value {
            let overPill = compactHoverRegion?.contains(hoverLocation()) ?? pointerInside
            hoverCooldownUntil = overPill ? ProcessInfo.processInfo.systemUptime + 0.6 : 0
        }
        expansionHistory.append(["time": Date().timeIntervalSince1970, "expanded": value,
                                 "origin": String(describing: origin), "reason": reason ?? String(describing: origin)])
        expansionHistory = Array(expansionHistory.suffix(24))
        // AppKit owns the outer geometry. Do not run a second SwiftUI layout
        // transition while the hosting view is being resized by its window.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { expanded = value }
        if origin != .automatic {
            soundPlayer.play(cue: value ? .expand : .collapse, sessionID: "island-ui",
                enabled: defaults.bool(forKey: "sound"), quiet: quiet,
                volume: defaults.double(forKey: "soundVolume"))
        }
        presentationPolicy?.expansionChanged(value, origin: origin)
        onLayout?()
        if value && origin == .manual { focusPanel?() }
    }
    private func cancelExpansionTimer() {
        expansionGeneration &+= 1
        expansionTimer?.invalidate()
        expansionTimer = nil
        hoverIntent = nil
    }
    private func cancelRevealTimer() {
        revealGeneration &+= 1
        revealTimer?.invalidate()
        revealTimer = nil
    }
    func reveal(reason: String = "response-needed") {
        if expanded, expansionOrigin != .automatic { return }
        setExpanded(true, origin: .automatic, reason: reason)
        guard pending.isEmpty else { return }
        let generation = revealGeneration
        revealTimer = Timer.scheduledTimer(withTimeInterval: max(2, defaults.double(forKey: "revealDwell")), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.revealGeneration == generation, self.expanded,
                      !self.pointerInside, self.pending.isEmpty,
                      !self.defaults.bool(forKey: "keepOpen") else { return }
                self.setExpanded(false, origin: .automatic, reason: "dwell-expired")
            }
        }
    }
    func hover(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        cancelExpansionTimer()
        if inside && !showHover { return }
        let generation = expansionGeneration
        if inside {
            guard !expanded else { return }
            guard ProcessInfo.processInfo.systemUptime >= hoverCooldownUntil else { return }
            hoverIntent = HoverIntent(location: hoverLocation(), at: ProcessInfo.processInfo.systemUptime)
            let timer = Timer(timeInterval: HoverIntent.sampleInterval, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self, self.expansionGeneration == generation else { timer.invalidate(); return }
                    guard self.showHover, self.pointerInside, !self.expanded else { self.cancelExpansionTimer(); return }
                    let location = self.hoverLocation()
                    guard self.hoverRegion?.contains(location) ?? true else { self.hover(false); return }
                    if self.hoverIntent?.sample(location: location, at: ProcessInfo.processInfo.systemUptime,
                                                delay: self.defaults.double(forKey: "hoverDelay")) == true {
                        self.setExpanded(true, origin: .hover)
                    }
                }
            }
            expansionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if expanded && pending.isEmpty && !defaults.bool(forKey: "keepOpen") && (presentationPolicy?.canCollapseOnMouseLeave ?? true) {
            expansionTimer = Timer.scheduledTimer(withTimeInterval: IslandTiming.hoverExit, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.expansionGeneration == generation,
                          self.expanded, !self.pointerInside, self.presentationPolicy?.canCollapseOnMouseLeave ?? true,
                          self.pending.isEmpty, !self.defaults.bool(forKey: "keepOpen") else { return }
                    self.setExpanded(false, origin: self.expansionOrigin == .automatic ? .automatic : .hover)
                }
            }
        }
    }
    func activateSession(_ session: AgentSession) {
        if defaults.bool(forKey: "disableClickJump") {
            selectSession(selectedID == session.id ? nil : session.id)
        } else { jump(session) }
    }
    func jump(_ session: AgentSession) {
        guard !defaults.bool(forKey: "disableClickJump") else { return }
        navigationGeneration += 1
        let generation = navigationGeneration
        navigationErrorID = nil
        guard let destination = SessionDestination.resolve(session) else {
            navigationErrorID = session.id
            onLayout?()
            return
        }
        sessionNavigator.open(destination) { [weak self] success in
            guard let self, self.navigationGeneration == generation else { return }
            if success {
                self.reminders.cancel(session.id)
            } else {
                self.navigationErrorID = session.id
                self.onLayout?()
            }
        }
    }
    func selectSession(_ id: String?) {
        presentationPolicy?.noteActivity()
        if expanded {
            expansionOrigin = .manual
            cancelRevealTimer()
            presentationPolicy?.expansionChanged(true, origin: .manual)
        }
        selectedID = id
        if let id { reminders.cancel(id) }
        onLayout?()
    }
    func moveSelection(_ delta: Int) {
        let items = filtered
        guard !items.isEmpty else { return }
        let index = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : items.count)
        selectSession(items[min(items.count - 1, max(0, index + delta))].id)
    }
    func shutdown() {
        remoteConnections.disconnectAll(); codexObserver?.stop(); piObserver?.stop(); timer?.invalidate()
        for observer in presenceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        presenceObservers.removeAll()
        cancelExpansionTimer(); cancelRevealTimer()
        for id in Array(pending.keys) { cancelRequest(id) }
        server?.stop()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var settingsPresented = false
    private var settingsTab = 0
    private var settingsProvider = "codex"
    var hotKey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var panelKeyMonitor: Any?
    var observers: [NSObjectProtocol] = []
    private var frameAnimation: IslandWindowAnimator?
    private var targetPanelFrame: NSRect?
    private var targetScreenID: String?
    private var targetBelowMenu = false
    private var shortcutConfiguration: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false; panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.animationBehavior = .none
        let host = TrackingHost(rootView: IslandView(model: model))
        // SwiftUI content must not impose a new window minimum/ideal size midway
        // through the AppKit frame animation.
        host.sizingOptions = []
        host.onHover = { [weak model] inside in model?.hover(inside) }
        panel.contentView = host
        model.onLayout = { [weak self] in
            self?.model.presentationPolicy?.refresh()
            self?.layout()
        }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openIntegrations = { [weak self] in
            guard let self else { return }
            self.showSettings()
            self.setSettingsContent(tab: 1, provider: "codex")
        }
        model.openRemoteConnections = { [weak self] in
            self?.showSettings()
            self?.setSettingsContent(tab: 10, provider: "hermes")
        }
        model.closeSettings = { [weak self] in self?.settingsWindow?.close() }
        model.focusPanel = { [weak self] in self?.panel.makeKey() }
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = StatusBarIcon.make()
            b.toolTip = "si-notch"
        }
        rebuildMenu()
        layout()
        if let i = CommandLine.arguments.firstIndex(of: "--qa-export"), CommandLine.arguments.indices.contains(i + 1) {
            panel.orderFrontRegardless()
            QAExporter.run(delegate: self, directory: URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true))
            return
        }
        model.presentationPolicy = PresentationPolicy(defaults: model.defaults,
            state: { [weak self] in
                guard let self else { return IslandPresentationState() }
                var state = self.model.presentationState
                state.isSettingsVisible = self.settingsPresented
                return state
            }, panel: { [weak self] in self?.panel },
            onVisibilityChange: { [weak self] in self?.applyIslandVisibility($0) },
            onAutoDismiss: { [weak model] in model?.setExpanded(false, origin: .automatic) })
        model.presentationPolicy?.start()
        model.start()
        UpdateBackgroundChecker.shared.start()
        installShortcut()
        panelKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, self.model.expanded,
                  !(self.panel.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 125: self.model.moveSelection(1)
            case 126: self.model.moveSelection(-1)
            case 53: self.model.setExpanded(false)
            case 36, 76:
                if let id = self.model.selectedID, let session = self.model.store.sessions[id] { self.model.jump(session) }
                else { return event }
            default:
                guard let chars = event.charactersIgnoringModifiers, let number = Int(chars), (1...9).contains(number),
                      self.model.filtered.indices.contains(number - 1) else { return event }
                self.model.selectSession(self.model.filtered[number - 1].id)
            }
            return nil
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.layout(allowAnimation: false) } })
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.layout(allowAnimation: false) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout(allowAnimation: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.model.reconcileFilters(); self?.model.refreshCodexObserver(); self?.layout(); self?.rebuildMenu(); self?.installMainMenu(); self?.installShortcut()
            self?.settingsWindow?.title = L10n.tr("si-notch · Настройки")
            self?.statusItem.button?.toolTip = "si-notch"
        } })
        if CommandLine.arguments.contains("--settings") { showSettings() }
        else if !model.defaults.bool(forKey: "agentDiscoveryPresented") {
            model.defaults.set(true, forKey: "agentDiscoveryPresented")
            model.openIntegrations?()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { frameAnimation?.stop(); model.presentationPolicy?.stop(); model.shutdown(); if let panelKeyMonitor { NSEvent.removeMonitor(panelKeyMonitor) }; if let hotKey { UnregisterEventHotKey(hotKey) }; if let eventHandler { RemoveEventHandler(eventHandler) } }
    func selectedScreen() -> NSScreen? {
        let preferred = model.defaults.string(forKey: "screenID")
        if let preferred, let screen = NSScreen.screens.first(where: { screenID($0) == preferred }) { return screen }
        if model.defaults.bool(forKey: "followFocus"), let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) { return screen }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }
    func layout(allowAnimation: Bool = true) {
        guard let screen = selectedScreen() else { return }
        let geometry = NotchGeometry(screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
                                     auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                                     auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
                                     backingScaleFactor: screen.backingScaleFactor)
        if model.cameraWidth != geometry.notchWidth { model.cameraWidth = geometry.notchWidth }
        let headerHeight = geometry.hasNotch ? geometry.topInset : 36
        if model.headerHeight != headerHeight { model.headerHeight = headerHeight }
        let width = min(screen.frame.width - 24, max(360, model.defaults.double(forKey: "panelWidth")))
        if model.expandedPanelWidth != width { model.expandedPanelWidth = width }
        let maxHeight = max(345, model.defaults.double(forKey: "panelHeight"))
        let height = model.panelHeight(limitedTo: min(screen.frame.height - 80, maxHeight))
        if model.expandedPanelHeight != height { model.expandedPanelHeight = height }
        let menuMode = model.defaults.string(forKey: "displayMode") == "belowMenu"
        let offset = menuMode ? max(geometry.topInset, NSStatusBar.system.thickness) + 8 : 0
        let compactFrame = geometry.compactFrame(leftWingWidth: model.compactWingWidth + model.compactShoulderWidth,
                                    rightWingWidth: model.compactStatusWidth + model.compactShoulderWidth,
                                    minimumHeight: 33, topOffset: offset)
        let contentFrame = model.expanded
            ? geometry.expandedFrame(width: width, height: height, topOffset: offset)
            : compactFrame
        let rect = menuMode ? contentFrame : geometry.coveringTopEdge(contentFrame)
        // Interaction follows the logical destination immediately. During a
        // collapse the departing large panel must not become a hover target.
        model.hoverRegion = HoverIntent.region(for: rect)
        model.compactHoverRegion = HoverIntent.region(for: menuMode ? compactFrame : geometry.coveringTopEdge(compactFrame))
        (panel.contentView as? TrackingHost<IslandView>)?.interactionFrame = rect
        let currentScreenID = screenID(screen)
        let animate = allowAnimation && targetPanelFrame != nil && panel.isVisible &&
            targetScreenID == currentScreenID && targetBelowMenu == menuMode &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Events and preferences may request the same destination while the
        // visible window is still travelling. Do not restart that animation.
        if targetPanelFrame == rect && animate && (panel.frame == rect || frameAnimation?.isRunning == true) { return }
        frameAnimation?.stop()
        frameAnimation = nil
        targetPanelFrame = rect
        targetScreenID = currentScreenID
        targetBelowMenu = menuMode
        guard panel.frame != rect else { return }
        // A system reposition is not an animation origin. Reattach first so the
        // next hover expands down from the screen edge rather than from a gap.
        guard animate, abs(panel.frame.maxY - rect.maxY) < 0.5 else {
            panel.setFrame(rect, display: true, animate: false)
            return
        }
        // Retain an explicitly cancellable animation so reversal, display changes,
        // and Reduce Motion start from the real current frame without a late snap.
        let animation = IslandWindowAnimator(window: panel, destination: rect,
            response: model.expanded ? IslandTiming.expandResponse : IslandTiming.collapseResponse,
            framesPerSecond: screen.maximumFramesPerSecond)
        frameAnimation = animation
        animation.start()
    }
    func applyIslandVisibility(_ visible: Bool) {
        if visible {
            layout(allowAnimation: false)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            model.hover(false)
            if model.presentationPolicy?.currentDecision?.hiddenReason == .noSessions {
                model.setExpanded(false, origin: .automatic)
            }
            layout(allowAnimation: false)
        }
    }
    func screenID(_ s: NSScreen) -> String { String(describing: s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "main") }
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? IslandPanel === panel, let targetPanelFrame,
              abs(panel.frame.maxY - targetPanelFrame.maxY) >= 0.5 else { return }
        // Show Desktop and focus transitions can reposition a nonactivating
        // panel. Keep the top anchor without ordering it above Exposé.
        layout(allowAnimation: false)
    }
    func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: L10n.tr("Открыть si-notch"), action: #selector(toggleIsland), keyEquivalent: "")
        m.addItem(withTitle: L10n.tr("Настройки…"), action: #selector(showSettings), keyEquivalent: ",")
        let available = model.defaults.string(forKey: "updateAvailableVersion") ?? ""
        m.addItem(withTitle: available.isEmpty ? L10n.tr("updates.menuCheck") : L10n.tr("updates.menuAvailable", available), action: #selector(showUpdates), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: model.paused ? L10n.tr("Возобновить события") : L10n.tr("Приостановить события"), action: #selector(togglePause), keyEquivalent: "")
        let quiet = m.addItem(withTitle: L10n.tr("Тихий режим"), action: #selector(toggleQuiet), keyEquivalent: "")
        quiet.state = model.quiet ? .on : .off
        m.addItem(withTitle: L10n.tr("Убрать завершённые"), action: #selector(clearFinished), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L10n.tr("Выйти из si-notch"), action: #selector(quit), keyEquivalent: "q")
        for i in m.items { i.target = self }
        statusItem.menu = m
    }
    @objc func showUpdates() {
        showSettings()
        setSettingsContent(tab: 9)
    }
    @objc func toggleIsland() { let hidden = !panel.isVisible; model.presentationPolicy?.noteActivity(); model.setExpanded(hidden || !model.expanded) }
    @objc func togglePause() { model.paused.toggle(); rebuildMenu() }
    @objc func toggleQuiet() { model.defaults.set(!model.quiet, forKey: "quiet"); rebuildMenu() }
    @objc func clearFinished() { model.clearFinished() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showSettings() {
        settingsPresented = true
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L10n.tr("si-notch · Настройки"); w.isReleasedWhenClosed = false
            w.delegate = self
            w.center(); settingsWindow = w
        }
        if !(settingsWindow?.contentView is NSHostingView<SettingsView>) { setSettingsContent() }
        model.setExpanded(false)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.presentationPolicy?.refresh(forceVisibilityUpdate: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsWindow else { return }
        settingsPresented = false
        // A retained NSHostingView keeps observing agent events and animating
        // companion previews after its window closes. Recreate it on demand.
        closing.contentView = nil
        model.setExpanded(false)
        model.presentationPolicy?.noteActivity()
        model.presentationPolicy?.refresh(forceVisibilityUpdate: true)
    }
    private func setSettingsContent(tab: Int? = nil, provider: String? = nil) {
        if let tab { settingsTab = tab }
        if let provider { settingsProvider = provider }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: model,
            tab: settingsTab, selectedProvider: settingsProvider, onSelectionChange: { [weak self] tab, provider in
                self?.settingsTab = tab
                self?.settingsProvider = provider
            }))
    }
    func installMainMenu() {
        let root = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: L10n.tr("Настройки…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let exit = appMenu.addItem(withTitle: L10n.tr("Выйти из si-notch"), action: #selector(quit), keyEquivalent: "q")
        exit.target = self
        appMenuItem.submenu = appMenu
        root.addItem(appMenuItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.tr("Окно"))
        windowMenu.addItem(withTitle: L10n.tr("Закрыть окно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        root.addItem(windowItem)
        NSApp.mainMenu = root
    }
    func installShortcut() {
        let configuration = "\(model.defaults.bool(forKey: "shortcutEnabled")):\(model.defaults.string(forKey: "shortcutModifier") ?? "ctrlAlt")"
        guard configuration != shortcutConfiguration else { return }
        shortcutConfiguration = configuration
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let eventHandler { RemoveEventHandler(eventHandler); self.eventHandler = nil }
        guard model.defaults.bool(forKey: "shortcutEnabled") else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleIsland() }
            return noErr
        }, 1, &spec, opaque, &eventHandler)
        let modifiers = controlKey | optionKey | (model.defaults.string(forKey: "shortcutModifier") == "ctrlShiftAlt" ? shiftKey : 0)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(modifiers), EventHotKeyID(signature: 0x53494E43, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.settingsError = .shortcut(Int(result)) }
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Layout already bounds the panel to its display. AppKit's usable-area
        // constraint must not move this borderless overlay below the menu bar.
        frameRect
    }
}
final class TrackingHost<Content: View>: NSHostingView<Content> {
    var area: NSTrackingArea?
    var onHover: ((Bool) -> Void)?
    var interactionFrame: CGRect? {
        didSet { if oldValue != interactionFrame { synchronizeHover() } }
    }
    private var pointerIsInside = false
    private var localMotionMonitor: Any?
    private var globalMotionMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, localMotionMonitor == nil {
            // Event-driven proximity tracking: no polling and no extra window
            // over the application's content below the notch.
            localMotionMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.synchronizeHover()
                return event
            }
            globalMotionMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.synchronizeHover()
            }
        } else if window == nil { removeMotionMonitors() }
    }
    private func removeMotionMonitors() {
        if let localMotionMonitor { NSEvent.removeMonitor(localMotionMonitor) }
        if let globalMotionMonitor { NSEvent.removeMonitor(globalMotionMonitor) }
        localMotionMonitor = nil
        globalMotionMonitor = nil
    }
    deinit {
        if let localMotionMonitor { NSEvent.removeMonitor(localMotionMonitor) }
        if let globalMotionMonitor { NSEvent.removeMonitor(globalMotionMonitor) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        if let area { addTrackingArea(area) }
        synchronizeHover()
    }
    private func synchronizeHover() {
        let inside: Bool
        if let window, window.isVisible, let interactionFrame {
            inside = HoverIntent.region(for: interactionFrame).contains(NSEvent.mouseLocation)
        } else { inside = false }
        guard inside != pointerIsInside else { return }
        pointerIsInside = inside
        onHover?(inside)
    }
    override func mouseEntered(with event: NSEvent) { synchronizeHover() }
    override func mouseExited(with event: NSEvent) { synchronizeHover() }
}
