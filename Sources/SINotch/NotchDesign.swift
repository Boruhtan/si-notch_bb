import SwiftUI
import AppKit

enum NotchDesign {
    static let accent = Color(red: 0.57, green: 0.90, blue: 0.79)
    static let ink = Color(red: 0.055, green: 0.067, blue: 0.065)
    static let secondary = Color.white.opacity(0.72)
    static let muted = Color.white.opacity(0.56)
}

struct BrandMark: View {
    var size: CGFloat = 24
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct NotchActionButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .font(.system(size: 12, weight: .medium))
            .controlSize(.regular)
            .buttonStyle(IslandGlassButtonStyle(prominent: prominent, destructive: destructive))
    }
}
