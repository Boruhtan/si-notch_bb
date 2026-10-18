import SwiftUI
import SINotchCore

/// Stable preference identifiers. An unknown saved value falls back to the original robot.
enum CompanionStyle: String, CaseIterable, Identifiable {
    case robot, cat, sprout, ghost

    var id: String { rawValue }
    var displayNameKey: String { "companion.style.\(rawValue)" }
}

/// Crisp ASCII-authored sprites with discrete motion and smooth status colors.
struct CompanionView: View {
    var status: AgentStatus
    @AppStorage("appLanguage") private var appLanguage = "auto"
    @AppStorage("companionStyle") private var storedStyle = CompanionStyle.robot.rawValue
    var size: CGFloat = 32
    var interactive = true
    var style: CompanionStyle? = nil
    var animated = true
    /// A fixed clock for deterministic previews and animation contact sheets.
    var previewTime: TimeInterval? = nil
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || !animated }
    @State private var greetingStartedAt: Date?
    @State private var motion: CompanionPoseTransition

    init(status: AgentStatus, size: CGFloat = 32, interactive: Bool = true,
         style: CompanionStyle? = nil, animated: Bool = true, previewTime: TimeInterval? = nil) {
        self.status = status
        self.size = size
        self.interactive = interactive
        self.style = style
        self.animated = animated
        self.previewTime = previewTime
        _motion = State(initialValue: CompanionPoseTransition(status: status, at: Date().timeIntervalSinceReferenceDate))
    }

    var body: some View {
        let _ = appLanguage
        let selectedStyle = style ?? CompanionStyle(rawValue: storedStyle) ?? .robot
        CompanionArtwork(configuration: .init(status: status, style: selectedStyle, motion: motion,
            greetingStartedAt: greetingStartedAt, reduceMotion: reduceMotion,
            previewTime: previewTime, displayScale: displayScale))
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onAppear { motion = CompanionPoseTransition(status: status, at: Date().timeIntervalSinceReferenceDate) }
        .onChange(of: status) { _, newStatus in
            motion.retarget(to: newStatus, at: Date().timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
        }
        .onTapGesture { greet() }
        .task(id: greetingStartedAt) {
            guard greetingStartedAt != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            greetingStartedAt = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("Спутник: %@", status.label))
        .accessibilityHint(interactive ? L10n.tr("Нажмите, чтобы поздороваться") : "")
        .accessibilityAddTraits(interactive ? .isButton : [])
        .accessibilityAction { greet() }
    }
    private func greet() { if interactive { greetingStartedAt = Date() } }
}

struct ActivityBars: View {
    var color: Color = .mint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0.4 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4) { index in
                    Capsule().fill(color).frame(width: 2, height: 5 + (0.5 + 0.5 * sin(t * 4 + Double(index) * 1.2)) * 6)
                }
            }.frame(width: 14, height: 15)
        }.accessibilityHidden(true)
    }
}
