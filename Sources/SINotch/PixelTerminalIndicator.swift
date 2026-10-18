import SwiftUI

/// Only the cursor changes; the baseline stays fixed.
struct PixelTerminalIndicator: View {
    var color: Color = .mint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: reduceMotion)) { timeline in
            let cursorVisible = reduceMotion || Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Canvas { context, _ in
                for (x, y) in [(1, 2), (2, 3), (3, 4), (2, 5), (1, 6)] {
                    context.fill(Path(CGRect(x: x * 2, y: y, width: 2, height: 2)), with: .color(color))
                }
                if cursorVisible {
                    context.fill(Path(CGRect(x: 10, y: 3, width: 3, height: 6)), with: .color(color))
                }
            }
        }
        .frame(width: 14, height: 12)
        .accessibilityHidden(true)
    }
}
