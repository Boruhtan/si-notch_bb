import AppKit
import Foundation

// Use the exact companion source pixels, including its typing pose.
let catSource = try String(contentsOfFile: "Sources/SINotch/PixelCat.swift", encoding: .utf8)
let companionSource = try String(contentsOfFile: "Sources/SINotch/PixelCompanion.swift", encoding: .utf8)
func section(_ source: String, after marker: String, before end: String) -> String {
    precondition(source.contains(marker))
    return source.components(separatedBy: marker)[1].components(separatedBy: end)[0]
}
let portrait = section(catSource, after: "private static let portrait = \"\"\"", before: "\"\"\"")
let keyboard = section(companionSource, after: "mutating func stampKeyboard() {\n        stamp(\"\"\"", before: "\"\"\"")
let hand = section(companionSource, after: "case .cat:\n            hand = \"", before: "\"").replacingOccurrences(of: "\\n", with: "\n")
let tail = section(catSource, after: "let tails = [\n            \"", before: "\"").replacingOccurrences(of: "\\n", with: "\n")
var pixels = Array(repeating: Character("."), count: 1600)
func stamp(_ art: String, x: Int = 0, y: Int = 0) {
    let rows = art.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    for (dy, row) in rows.enumerated() {
        for (dx, char) in row.enumerated() where char != "." {
            precondition((0..<40).contains(x + dx) && (0..<40).contains(y + dy))
            pixels[(y + dy) * 40 + x + dx] = char
        }
    }
}
stamp(tail, x: 31, y: 22)
stamp(portrait)
stamp(keyboard, x: 6, y: 34)
stamp(hand, x: 9, y: 28)
stamp(hand, x: 23, y: 29)
func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, alpha: 1)
}
let palette: [Character: NSColor] = ["#": rgb(0x6ED6A6), "H": rgb(0xB3F0C9), "S": rgb(0x40966E),
    "D": rgb(0x214D3B), "E": rgb(0x090F0E), "T": rgb(0xFAFAF0), "M": rgb(0xFAEBC9),
    "P": rgb(0xF2A399), "K": rgb(0x293138), "W": rgb(0x7D8C91)]
func bitmap(width: Int, height: Int, drawing: () -> Void) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    drawing()
    NSGraphicsContext.restoreGraphicsState()
    return image
}
func icon(size: Int, path: String) throws {
    let scale = CGFloat(size) / 1024
    let image = bitmap(width: size, height: size) {
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: scale, y: scale)
        // Flat ink tile; the cat provides the detail and color.
        rgb(0x111D1B).setFill()
        NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 208, yRadius: 208).fill()
        context.setShouldAntialias(false)
        for y in 0..<40 {
            for x in 0..<40 {
                guard let color = palette[pixels[y * 40 + x]] else { continue }
                color.setFill()
                NSRect(x: 112 + x * 20, y: 912 - (y + 1) * 20, width: 20, height: 20).fill()
            }
        }
    }
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try icon(size: 1024, path: "Assets/AppIcon.png")
if CommandLine.arguments.count == 2 {
    let folder = CommandLine.arguments[1]
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for dimension in [16, 32, 128, 256, 512] {
        try icon(size: dimension, path: "\(folder)/icon_\(dimension)x\(dimension).png")
        try icon(size: dimension * 2, path: "\(folder)/icon_\(dimension)x\(dimension)@2x.png")
    }
}
