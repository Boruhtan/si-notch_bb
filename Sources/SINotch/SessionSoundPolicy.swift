import Foundation
import SINotchCore

/// Sounds describe a session/turn, not the number of transports observing it.
struct SessionSoundPolicy {
    private struct Turn {
        var cues: Set<EventSoundPlayer.Cue> = []
        var requests: Set<String> = []
        var requestOrder: [String] = []
        var terminal = false

        mutating func rememberRequest(_ id: String) -> Bool {
            guard requests.insert(id).inserted else { return false }
            requestOrder.append(id)
            if requestOrder.count > 128 { requests.remove(requestOrder.removeFirst()) }
            return true
        }
    }
    private struct Session {
        var announced = false
        var beganWorking = false
        var currentTurn = "anonymous:0"
        var anonymousTurn = 0
        var turns: [String: Turn] = [:]
        var order: [String] = []
        var lastStatus: AgentStatus?
        var used: UInt64 = 0
    }
    private var sessions: [String: Session] = [:]
    private var revision: UInt64 = 0

    mutating func consume(_ event: AgentEvent, status: AgentStatus,
                          restoring: Bool = false) -> EventSoundPlayer.Cue? {
        let id = Self.canonical(event.sessionID)
        let key = event.provider.lowercased() + "\0" + id
        var session = sessions[key] ?? Session()
        revision &+= 1
        session.used = revision
        defer {
            session.lastStatus = status
            sessions[key] = session
            if sessions.count > 512, let oldest = sessions.min(by: { $0.value.used < $1.value.used })?.key {
                sessions.removeValue(forKey: oldest)
            }
        }

        if let turnID = event.turnID.map(Self.canonical) {
            let turn = "turn:" + turnID
            if session.turns[turn] == nil, session.currentTurn.hasPrefix("anonymous:"),
               let previous = session.turns[session.currentTurn], !previous.terminal {
                // A hook can arrive before the stream supplies its turn ID.
                session.turns[turn] = previous
            }
            session.currentTurn = turn
        } else if !restoring, event.kind == .working,
                  [.completed, .failed, .ended].contains(session.lastStatus ?? .idle),
                  session.currentTurn.hasPrefix("anonymous:") {
            session.anonymousTurn += 1
            session.currentTurn = "anonymous:\(session.anonymousTurn)"
        }
        let turnKey = session.currentTurn
        var turn = session.turns[turnKey] ?? Turn()
        if !session.order.contains(turnKey) { session.order.append(turnKey) }
        defer {
            session.turns[turnKey] = turn
            while session.order.count > 32 { session.turns.removeValue(forKey: session.order.removeFirst()) }
        }

        if restoring {
            session.announced = true
            session.beganWorking = true
            turn.cues.insert(.working)
            switch status {
            case .completed: turn.cues.insert(.completion); turn.terminal = true
            case .failed: turn.cues.insert(.failure); turn.terminal = true
            case .approval, .waiting:
                turn.cues.insert(.attention)
                if let request = event.approvalID { _ = turn.rememberRequest(request) }
            case .ended: turn.terminal = true
            default: break
            }
            return nil
        }

        switch event.kind {
        case .sessionStarted:
            guard !session.announced else { return nil }
            session.announced = true
            return .sessionStart
        case .working, .toolStarted, .toolFinished, .toolFailed, .subagentStarted:
            guard status == .working, !turn.terminal, !turn.cues.contains(.working) else { return nil }
            turn.cues.insert(.working)
            let firstWork = !session.beganWorking
            session.beganWorking = true
            if !session.announced { session.announced = true; return .sessionStart }
            return firstWork ? nil : .working
        case .completed, .failed:
            let cue: EventSoundPlayer.Cue = event.kind == .completed ? .completion : .failure
            session.announced = true
            session.beganWorking = true
            guard !turn.terminal else { return nil }
            turn.terminal = true
            guard turn.cues.insert(cue).inserted else { return nil }
            return cue
        case .approvalRequested, .waiting:
            session.announced = true
            if let request = event.approvalID {
                guard turn.rememberRequest(request) else { return nil }
                // A state-only observer may have announced the same pending request.
                if turn.cues.contains(.attention), turn.requests.count == 1 { return nil }
            } else if turn.cues.contains(.attention) { return nil }
            turn.cues.insert(.attention)
            return .attention
        case .sessionEnded:
            turn.terminal = true
            return nil
        default: return nil
        }
    }

    private static func canonical(_ id: String) -> String { UUID(uuidString: id)?.uuidString.lowercased() ?? id }
}
