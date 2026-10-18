import CoreGraphics
import Foundation

/// Reuse tiny native-resolution pixel frames instead of rebuilding and drawing
/// hundreds of vector rectangles on every animation tick. Layout and opacity
/// stay in the view. Pixels are replicated to the backing grid so enlarged
/// previews stay sharp even when a hosting view ignores image interpolation.
@MainActor
enum CompanionRaster {
    private struct Key: Hashable {
        let sprite: PixelCompanion
        let red: Double
        let green: Double
        let blue: Double
        let pixelsPerCell: Int
    }
    private static var images: [Key: CGImage] = [:]
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func image(sprite: PixelCompanion, pose: CompanionPose, pixelsPerCell: Int = 1) -> CGImage? {
        let scale = max(1, pixelsPerCell)
        let key = Key(sprite: sprite, red: pose.red, green: pose.green, blue: pose.blue, pixelsPerCell: scale)
        if let image = images[key] { return image }
        let soft = 0.20
        let red = pose.red * (1 - soft) + soft
        let green = pose.green * (1 - soft) + soft
        let blue = pose.blue * (1 - soft) + soft
        let palette: [Character: (Double, Double, Double)] = [
            "#": (red, green, blue),
            "H": (red * 0.55 + 0.45, green * 0.55 + 0.45, blue * 0.55 + 0.45),
            "S": (red * 0.55, green * 0.55, blue * 0.55),
            "D": (red * 0.28, green * 0.28, blue * 0.28),
            "E": (0.035, 0.06, 0.055), "T": (0.98, 0.98, 0.94),
            "M": (0.98, 0.92, 0.79), "P": (0.95, 0.64, 0.60),
            "F": (0.91, 0.68, 0.51), "B": (0.39, 0.26, 0.22),
            "C": (red * 0.35 + 0.65, green * 0.35 + 0.65, blue * 0.35 + 0.65),
            "K": (0.16, 0.19, 0.22), "W": (0.49, 0.55, 0.57)
        ]
        func byte(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        let colors = palette.mapValues { [byte($0.0), byte($0.1), byte($0.2), UInt8(255)] }
        var pixels = [UInt8]()
        let side = sprite.dimension * scale
        pixels.reserveCapacity(side * side * 4)
        for y in 0..<sprite.dimension {
            var row = [UInt8]()
            row.reserveCapacity(side * 4)
            for x in 0..<sprite.dimension {
                let pixel = colors[sprite[x, y]] ?? [0, 0, 0, 0]
                for _ in 0..<scale { row.append(contentsOf: pixel) }
            }
            for _ in 0..<scale { pixels.append(contentsOf: row) }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: side, height: side,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        // Bound transient color-transition frames as well as settled poses.
        if images.count >= 64 || images.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) + pixels.count > 2 * 1024 * 1024 {
            images.removeAll(keepingCapacity: true)
        }
        images[key] = image
        return image
    }
}
