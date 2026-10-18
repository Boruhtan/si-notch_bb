import Foundation
import SINotchCore

struct SessionActivity: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let kind: AgentEventKind
    let tool: String?
    let message: String?

    init?(_ event: AgentEvent) {
        guard [.working, .toolStarted, .toolFinished, .toolFailed, .waiting,
               .approvalRequested, .completed, .failed].contains(event.kind) ||
            (event.kind == .usageUpdated && event.message != nil) else { return nil }
        timestamp = event.timestamp
        kind = event.kind
        tool = SessionSnippet.text(event.toolName, limit: 100)
        message = SessionSnippet.text(event.message, limit: 600)
    }

    var label: String {
        switch kind {
        case .toolStarted: return tool ?? L10n.tr("session.activity.tool")
        case .toolFinished: return L10n.tr("session.activity.finished", tool ?? L10n.tr("session.activity.tool"))
        case .toolFailed: return L10n.tr("session.activity.failed", tool ?? L10n.tr("session.activity.tool"))
        case .waiting, .approvalRequested: return L10n.tr("Ждёт ответа")
        case .completed: return L10n.tr("Готово")
        case .failed: return L10n.tr("Ошибка")
        case .usageUpdated: return L10n.tr("session.latestUpdate")
        default: return tool ?? L10n.tr("В работе")
        }
    }
}
