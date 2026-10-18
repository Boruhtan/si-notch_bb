import Foundation
import SINotchCore

/// ASCII-authored sprites. Each character is one pixel; animation changes cells
/// without scaling or rotating the artwork.
struct PixelCompanion: Hashable {
    static let side = 20
    let dimension: Int
    private(set) var cells: [Character]

    init(dimension: Int = Self.side) {
        self.dimension = dimension
        cells = Array(repeating: Character("."), count: dimension * dimension)
    }

    subscript(x: Int, y: Int) -> Character { cells[y * dimension + x] }

    mutating func stamp(_ art: String, x: Int, y: Int) {
        for (dy, row) in art.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for (dx, pixel) in row.enumerated() where pixel != "." {
                let px = x + dx, py = y + dy
                guard (0..<dimension).contains(px), (0..<dimension).contains(py) else { continue }
                cells[py * dimension + px] = pixel
            }
        }
    }

    mutating func stampKeyboard() {
        stamp("""
        DKKKKKKKKKKKKKKKKKKKKKKKKKKD
        DKWWKWWKWWKWWKWWKWWKWWKWWKKD
        DKKKKKKKKKKKKKKKKKKKKKKKKKKD
        DDDDDDDDDDDDDDDDDDDDDDDDDDDD
        """, x: 6, y: 34)
    }

    mutating func stampTypingHands(style: CompanionStyle, phase: Int, jump: Int) {
        let hand: String
        switch style {
        case .cat:
            hand = "..DDDD..\n.DHH##D.\nDH#####D\nD##S#S#D\n.D#####D\n..DDDDD."
        case .robot:
            // Flat wrist, metal palm, and two square jointed fingers.
            hand = ".DDDDDD.\n.DHHHHD.\n.DKKKKD.\n.DHKHKD.\n.D#K#KD.\n.DDDDDD."
        case .sprout:
            // A pointed leaf with one diagonal vein.
            hand = ".D......\n.DHD....\n..DSHD..\n..DHSHD.\n...DHSD.\n....DD.."
        case .ghost:
            // Smooth sheet-like flippers: no digits or paw markings.
            hand = "..DD....\n.DCCD...\nDCMMCD..\nDCCCCCD.\n.DCCCCD.\n..DDDD.."
        }
        let right = style == .cat ? hand : hand.split(separator: "\n")
            .map { String($0.reversed()) }.joined(separator: "\n")
        stamp(hand, x: 9, y: 28 + jump + (phase % 2 == 0 ? 0 : 1))
        stamp(right, x: 23, y: 28 + jump + (phase % 2 == 1 ? 0 : 1))
    }

    static func frame(style: CompanionStyle, status: AgentStatus, time: TimeInterval,
                      stateAge: TimeInterval = 1, greetingAge: TimeInterval? = nil,
                      reduceMotion: Bool = false, detailed: Bool = true) -> PixelCompanion {
        if detailed {
            return PixelFriends.frame(style: style, status: status, time: time, stateAge: stateAge,
                                      greetingAge: greetingAge, reduceMotion: reduceMotion)
        }
        let time = time.isFinite ? max(0, time) : 0
        let phase = reduceMotion ? 0 : Int((time.truncatingRemainder(dividingBy: 2.0 / 3) * 6).rounded(.down)) % 4
        let working = status == .working
        let greeting = greetingAge.map { $0 >= 0 && $0 < 0.8 } ?? false
        let celebrating = status == .completed && stateAge >= 0 && stateAge < 0.7
        let jump = !reduceMotion && (greeting || celebrating) && phase % 2 == 1 ? -1 : 0
        let blink = !reduceMotion && time.truncatingRemainder(dividingBy: 5.6) > 5.43
        var sprite = PixelCompanion()
        var eyeX = 6, eyeY = 8 + jump, eyeDistance = 6
        switch style {
        case .cat:
            sprite.stamp("""
            ##..........##
            #H#........#H#
            #HH########HH#
            .############.
            .#HH#########.
            ##############
            ##############
            ##############
            .S##########S.
            ..SS######SS..
            ...##HH##S#...
            ...##HH##S#...
            ...##SSSS##...
            """, x: 3, y: 3 + jump)
            let tails = [".##\n..#\n..#\n.##\n##.", "..#\n..#\n.##\n##.\n#..",
                         "##.\n.##\n..#\n..#\n###", ".##\n..#\n..#\n.##\n##."]
            sprite.stamp(tails[working ? phase : 0], x: 16, y: 10 + jump)
            if working {
                sprite.stamp("KKKKKKKKKKKK\nKWWKWWKWWKWK", x: 4, y: 17)
                sprite.stamp("HHH", x: 6, y: phase % 2 == 0 ? 16 : 15)
                sprite.stamp("HHH", x: 11, y: phase % 2 == 0 ? 15 : 16)
                sprite.stamp("H", x: phase % 2 == 0 ? 7 : 12, y: 17)
            } else {
                sprite.stamp("HH...HH", x: 5, y: 16 + jump)
            }
        case .robot:
            sprite.stamp(working && phase >= 2 ? "HH" : "##", x: 9, y: 2 + jump)
            sprite.stamp("SS\nSS", x: 9, y: 3 + jump)
            sprite.stamp("""
            .##########.
            #HH#########
            #EEEEEEEEEE#
            #EEEEEEEEEE#
            #EEEEEEEEEE#
            #EEEEEEEEEE#
            .##########.
            ..SSSSSSSS..
            ..########..
            ..###HH###..
            ..SSSSSSSS..
            """, x: 4, y: 5 + jump)
            if !working { sprite.stamp("HHH..HHH", x: 6, y: 16 + jump) }
            eyeX = 7; eyeDistance = 4
        case .sprout:
            let sway = working && phase >= 2 ? 1 : 0
            sprite.stamp("""
            .HHH....HHH.
            H###H..H###H
            .S########S.
            ..SS####SS..
            .....##.....
            .....SS.....
            """, x: 4 + sway, y: 2 + jump)
            sprite.stamp("##", x: 9, y: 8 + jump)
            sprite.stamp("""
            HHHHHHHHHHHHHH
            ##############
            .#H#########S.
            .#H#########S.
            ..##########..
            ..##########..
            ...########...
            ...SSSSSSSS...
            """, x: 3, y: 9 + jump)
            eyeX = 7; eyeY = 11 + jump; eyeDistance = 4
            if working { sprite.stamp("H", x: phase < 2 ? 2 : 17, y: phase % 2 == 0 ? 6 : 5) }
        case .ghost:
            sprite.stamp("""
            ....######....
            ..##HH######..
            .############.
            ##############
            ##############
            ##############
            ##############
            ##H###########
            ##H###########
            .############.
            .S##########S.
            """, x: 3, y: 4 + jump)
            sprite.stamp(working && phase >= 2 ? ".###..###.\n..#....#.." : "###.##.###\n.#......#.", x: 5, y: 15 + jump)
            eyeX = 6; eyeDistance = 6
        }
        // Robot eyes light up in its dark display; the other faces use dark ink.
        let ink = style == .robot ? "H" : "E"
        let happy = status == .completed || greeting
        let eyes: String
        if happy { eyes = ".\(ink).\n\(ink).\(ink)" }
        else if blink || status == .ended { eyes = "..\n\(ink)\(ink)" }
        else { eyes = "\(ink)\(ink)\n\(ink)\(ink)" }
        sprite.stamp(eyes, x: eyeX - (happy ? 1 : 0), y: eyeY)
        sprite.stamp(eyes, x: eyeX + eyeDistance, y: eyeY)
        // Every face is centered between columns 9 and 10. Even-width mouths
        // avoid the off-center expression of a three-pixel mouth on this grid.
        let mouthY = style == .robot ? eyeY + 2 : eyeY + 3
        if style == .robot {
            sprite.stamp(status == .failed ? "HHHH" : ".HH.", x: 8, y: mouthY)
        } else if style == .cat {
            sprite.stamp(".MMMMMM.\nMMMMMMMM\n.MMMMMM.", x: 6, y: eyeY + 2)
            sprite.stamp("PP", x: 9, y: eyeY + 2)
            sprite.stamp(status == .failed ? ".EE.\nE..E" : "E..E\n.EE.", x: 8, y: eyeY + 3)
        } else if status == .failed {
            sprite.stamp(".EE.\nE..E", x: 8, y: mouthY)
        } else if status == .waiting || status == .approval {
            sprite.stamp("EE\nEE", x: 9, y: mouthY)
        } else {
            sprite.stamp("E..E\n.EE.", x: 8, y: mouthY)
        }
        if style != .cat && working {
            sprite.stamp("KKKKKKKKKKKK\nKWWKWWKWWKWK", x: 4, y: 17)
            let hand: String
            switch style {
            case .robot: hand = "HHH\nHKH"
            case .sprout: hand = "H#S\n.#."
            case .ghost: hand = ".C.\nCCC"
            case .cat: hand = "HHH"
            }
            sprite.stamp(hand, x: 5, y: 15 + jump - (phase % 2 == 0 ? 1 : 0))
            sprite.stamp(hand.split(separator: "\n").map { String($0.reversed()) }.joined(separator: "\n"),
                         x: 12, y: 15 + jump - (phase % 2 == 1 ? 1 : 0))
        }
        if (greeting || celebrating) && !reduceMotion {
            sprite.stamp(phase < 2 ? ".H.\nHHH\n.H." : "H.H\n.H.\nH.H", x: 16, y: 1)
        }
        if status == .approval { sprite.stamp("H\nH\n.\nH", x: 18, y: 2) }
        return sprite
    }
}

/// The same integer pixel grid on Retina, non-Retina, and fractional-sized previews.
struct PixelCompanionLayout {
    let cell: Double
    let originX: Double
    let originY: Double

    init(width: Double, height: Double, displayScale: Double, side: Int = PixelCompanion.side) {
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        let side = Double(side)
        cell = max(1, floor(min(width, height) * scale / side)) / scale
        originX = floor((width - side * cell) * scale / 2) / scale
        originY = floor((height - side * cell) * scale / 2) / scale
    }
}
