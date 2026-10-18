import SwiftUI

/// System glass supplies the edge; a dark scrim keeps arbitrary wallpaper from washing out text.
struct IslandMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 28
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.black), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.035).opacity(0.88)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.075), lineWidth: 0.5))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.035).opacity(0.92)))
        }
    }
}

extension View {
    func islandMaterial(radius: CGFloat = 28) -> some View { modifier(IslandMaterial(radius: radius)) }
}
