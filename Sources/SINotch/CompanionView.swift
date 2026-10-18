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
        TimelineView(CompanionTimelineSchedule(status: status, motion: motion,
            greetingStartedAt: greetingStartedAt, paused: reduceMotion || previewTime != nil)) { timeline in
            let time = previewTime ?? timeline.date.timeIntervalSinceReferenceDate
            let pose = previewTime == nil ? motion.value(at: time, reduceMotion: reduceMotion) : CompanionPose.target(status)
            let age = previewTime ?? max(0, time - motion.startedAt)
            let greetingAge = greetingStartedAt.map { max(0, timeline.date.timeIntervalSince($0)) }
            Canvas { context, canvas in
                draw(context: context, canvas: canvas, time: time, pose: pose,
                     poseAge: age, greetingAge: greetingAge, selectedStyle: selectedStyle)
            }
        }
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

    private func draw(context originalContext: GraphicsContext, canvas: CGSize, time: TimeInterval,
                      pose: CompanionPose, poseAge: TimeInterval, greetingAge: TimeInterval?, selectedStyle: CompanionStyle) {
        let sprite = PixelCompanion.frame(style: selectedStyle, status: status, time: time,
                                          stateAge: poseAge, greetingAge: greetingAge,
                                          reduceMotion: reduceMotion,
                                          detailed: min(canvas.width, canvas.height) * displayScale >= 40)
        let layout = PixelCompanionLayout(width: canvas.width, height: canvas.height,
                                         displayScale: displayScale, side: sprite.dimension)
        let soft = 0.20
        let red = pose.red * (1 - soft) + soft
        let green = pose.green * (1 - soft) + soft
        let blue = pose.blue * (1 - soft) + soft
        let tint = Color(red: red, green: green, blue: blue)
        let colors: [Character: Color] = [
            "#": tint,
            "H": Color(red: red * 0.55 + 0.45, green: green * 0.55 + 0.45, blue: blue * 0.55 + 0.45),
            "S": Color(red: red * 0.55, green: green * 0.55, blue: blue * 0.55),
            "D": Color(red: red * 0.28, green: green * 0.28, blue: blue * 0.28),
            "E": Color(red: 0.035, green: 0.06, blue: 0.055),
            "T": Color(red: 0.98, green: 0.98, blue: 0.94),
            "M": Color(red: 0.98, green: 0.92, blue: 0.79),
            "P": Color(red: 0.95, green: 0.64, blue: 0.60),
            "F": Color(red: 0.91, green: 0.68, blue: 0.51),
            "B": Color(red: 0.39, green: 0.26, blue: 0.22),
            "C": Color(red: red * 0.35 + 0.65, green: green * 0.35 + 0.65, blue: blue * 0.35 + 0.65),
            "K": Color(red: 0.16, green: 0.19, blue: 0.22),
            "W": Color(red: 0.49, green: 0.55, blue: 0.57)
        ]
        var context = originalContext
        context.opacity = pose.opacity
        var paths: [Character: Path] = [:]
        for y in 0..<sprite.dimension {
            for x in 0..<sprite.dimension {
                let ink = sprite[x, y]
                guard colors[ink] != nil else { continue }
                let rect = CGRect(x: layout.originX + Double(x) * layout.cell,
                                  y: layout.originY + Double(y) * layout.cell,
                                  width: layout.cell, height: layout.cell)
                paths[ink, default: Path()].addRect(rect)
            }
        }
        // A detailed sprite has hundreds of cells but only a few palette colors.
        // Batch each color into one draw instead of submitting every pixel.
        for (ink, path) in paths {
            if let color = colors[ink] {
                context.fill(path, with: .color(color), style: FillStyle(antialiased: false))
            }
        }
    }

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
