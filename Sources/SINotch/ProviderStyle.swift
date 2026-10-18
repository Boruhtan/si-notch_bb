import AppKit
import SwiftUI

/// Provider identity stays constant while the separate status indicator changes.
struct ProviderStyle {
    let symbol: String
    private let darkRGB: UInt32
    private let lightRGB: UInt32

    init(provider: String) {
        let name = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let style: (String, UInt32, UInt32)
        switch name {
        case "codex": style = ("chevron.left.forwardslash.chevron.right", 0x70D8C2, 0x007961)
        case "pi": style = ("circle.grid.cross", 0xE8B95B, 0x996700)
        case "claude": style = ("sparkle", 0xF29B78, 0xB95025)
        case "opencode": style = ("terminal", 0x75C7F2, 0x006D98)
        case "hermes": style = ("paperplane", 0xBB9AF7, 0x7051AB)
        case "gemini": style = ("sparkles", 0x91A7FF, 0x445BC0)
        case "copilot": style = ("person.crop.circle", 0xBBDA79, 0x587623)
        case "cursor": style = ("cursorarrow", 0xEE9FC4, 0x9E3C72)
        case "custom", "": style = ("slider.horizontal.3", 0xB3BBC9, 0x596477)
        default:
            // Swift's Hasher is randomized per process. Keep custom-agent colors
            // stable across launches without writing any preferences.
            let palette: [(UInt32, UInt32)] = [
                (0x70D8C2, 0x007961), (0xE8B95B, 0x996700),
                (0xF29B78, 0xB95025), (0x75C7F2, 0x006D98),
                (0xBB9AF7, 0x7051AB), (0x91A7FF, 0x445BC0),
                (0xBBDA79, 0x587623), (0xEE9FC4, 0x9E3C72)
            ]
            let hash = name.utf8.prefix(128).reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
            let colors = palette[Int(hash % UInt32(palette.count))]
            style = ("slider.horizontal.3", colors.0, colors.1)
        }
        (symbol, darkRGB, lightRGB) = style
    }

    var color: Color {
        let dark = darkRGB, light = lightRGB
        return Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
}
