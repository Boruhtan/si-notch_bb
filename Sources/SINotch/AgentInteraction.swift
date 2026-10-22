import Foundation

/// Provider-independent presentation contract. Adapters own wire payloads and
/// reply channels; the UI receives only the exact capabilities of this request.
struct AgentInteraction: Identifiable, Equatable {
    struct Question: Identifiable, Equatable {
        let id: String
        let title: String
        let options: [String]
        let optionDescriptions: [String]
        let secret: Bool
    }
    struct Action: Identifiable, Equatable {
        let id: String
        let label: String
        let destructive: Bool
    }
    let id: String
    let sessionID: String
    let detail: String
    let questions: [Question]
    let actions: [Action]
    let expiresAt: TimeInterval
    var isApproval: Bool { questions.isEmpty }

    func accepts(answers: [String: String]) -> Bool {
        !questions.isEmpty && Set(answers.keys) == Set(questions.map(\.id)) && questions.allSatisfy {
            guard let answer = answers[$0.id] else { return false }
            return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answer.utf8.count <= 12000
        }
    }
}
