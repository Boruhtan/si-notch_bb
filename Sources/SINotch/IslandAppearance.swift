import SwiftUI

/// Older saved translucent choices migrate to a solid black camera surface.
/// Glass belongs to Settings controls, never to the island body.
enum IslandAppearance: String, CaseIterable, Identifiable {
    case opaque
    var id: String { rawValue }
    var label: String { L10n.tr("appearance.opaque") }
    static func resolve(_ rawValue: String) -> IslandAppearance { .opaque }
    func effective(reduceTransparency: Bool) -> IslandAppearance { .opaque }
}

struct IslandAppearanceSurface: View {
    var body: some View { Color.black }
}

/// Native glass buttons keep system interaction, keyboard and accessibility behavior.
/// Older systems and Reduce Transparency use the native bordered button styles.
struct IslandGlassButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent {
                Button(configuration).buttonStyle(.glassProminent)
                    .tint(NotchDesign.accent).foregroundStyle(NotchDesign.ink)
            } else {
                Button(configuration).buttonStyle(.glass)
                    .foregroundStyle(destructive ? Color(red: 1, green: 0.68, blue: 0.66) : .white.opacity(0.9))
            }
        } else if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
                .tint(NotchDesign.accent).foregroundStyle(NotchDesign.ink)
        } else {
            Button(configuration).buttonStyle(.bordered)
                .foregroundStyle(destructive ? Color(red: 1, green: 0.68, blue: 0.66) : .white.opacity(0.9))
        }
    }
}
