import XCTest
import SINotchCore
@testable import SINotch

final class PixelCompanionTests: XCTestCase {
    func testEveryStateAndFrameUsesPaletteAndStaysInsideCanvas() {
        let palette = Set(".#HSETDMPKWFCB")
        for style in CompanionStyle.allCases {
            for status in AgentStatus.allCases {
                for tick in 0..<40 {
                    let sprite = PixelCompanion.frame(style: style, status: status, time: Double(tick) / 6,
                                                      stateAge: 0.3, greetingAge: 0.3)
                    let side = 40
                    XCTAssertEqual(sprite.cells.count, side * side)
                    XCTAssertTrue(Set(sprite.cells).isSubset(of: palette))
                    XCTAssertGreaterThan(sprite.cells.filter { $0 != "." }.count, 70)
                    // One empty border pixel prevents clipping in the compact 20 pt view.
                    for i in 0..<side {
                        XCTAssertEqual(sprite[i, 0], ".")
                        XCTAssertEqual(sprite[i, side - 1], ".")
                        XCTAssertEqual(sprite[0, i], ".")
                        XCTAssertEqual(sprite[side - 1, i], ".")
                    }
                }
            }
        }
    }

    func testEachCompanionHasRealWorkingFramesAndDistinctSilhouette() {
        var firstFrames = Set<[Character]>()
        for style in CompanionStyle.allCases {
            let frames = (0..<4).map { PixelCompanion.frame(style: style, status: .working, time: Double($0) / 6 + 0.01) }
            XCTAssertGreaterThan(Set(frames.map(\.cells)).count, 1, style.rawValue)
            XCTAssertEqual(frames[0], PixelCompanion.frame(style: style, status: .working, time: 4.0 / 6 + 0.01))
            firstFrames.insert(frames[0].cells)
        }
        XCTAssertEqual(firstFrames.count, CompanionStyle.allCases.count)
    }

    func testReduceMotionFreezesAnimationButRetainsStateExpression() {
        for style in CompanionStyle.allCases {
            for status in AgentStatus.allCases {
                let first = PixelCompanion.frame(style: style, status: status, time: 0, reduceMotion: true)
                let later = PixelCompanion.frame(style: style, status: status, time: 5.5, reduceMotion: true)
                XCTAssertEqual(first, later)
            }
            XCTAssertNotEqual(PixelCompanion.frame(style: style, status: .idle, time: 1, reduceMotion: true),
                              PixelCompanion.frame(style: style, status: .completed, time: 1, reduceMotion: true))
        }
    }

    func testAllCompanionsTypeWithMovingHandsAndAStationaryKeyboard() {
        for style in CompanionStyle.allCases {
            let first = PixelCompanion.frame(style: style, status: .working, time: 0.01)
            let second = PixelCompanion.frame(style: style, status: .working, time: 1.0 / 6 + 0.01)
            let desk = (35..<38).flatMap { y in (6..<34).map { x in first[x, y] } }
            let nextDesk = (35..<38).flatMap { y in (6..<34).map { x in second[x, y] } }
            XCTAssertTrue(desk.contains("K"), style.rawValue)
            XCTAssertTrue(desk.contains("W"), style.rawValue)
            XCTAssertEqual(desk, nextDesk, style.rawValue)
            let hands = (28..<34).flatMap { y in (9..<31).map { x in first[x, y] } }
            let nextHands = (28..<34).flatMap { y in (9..<31).map { x in second[x, y] } }
            XCTAssertNotEqual(hands, nextHands, style.rawValue)
        }
    }

    func testKeyboardOnlyAppearsWhileWorkingAtBothResolutions() {
        for detailed in [false, true] {
            for style in CompanionStyle.allCases {
                for status in AgentStatus.allCases {
                    let sprite = PixelCompanion.frame(style: style, status: status, time: 0.2, detailed: detailed)
                    XCTAssertEqual(sprite.cells.contains("W"), status == .working, "\(style) / \(status)")
                    XCTAssertEqual(sprite.cells.contains("K"), status == .working, "\(style) / \(status)")
                }
            }
        }
    }

    func testTypingHandsHaveCharacterSpecificSilhouettes() {
        var silhouettes = Set<[Bool]>()
        for style in CompanionStyle.allCases {
            var sprite = PixelCompanion(dimension: 40)
            sprite.stampTypingHands(style: style, phase: 0, jump: 0)
            silhouettes.insert(sprite.cells.map { $0 != "." })
            if style == .ghost {
                XCTAssertTrue(Set(sprite.cells).isSubset(of: Set(".DCM")), "Ghost hands have no finger or paw marks")
            }
        }
        XCTAssertEqual(silhouettes.count, CompanionStyle.allCases.count)
    }

    func testDevicePixelAlignmentAtActualViewSizes() {
        for size in [20.0, 22, 32, 40, 46, 58, 94] {
            for scale in [1.0, 2.0] {
                for side in [20, 40] where Double(side) <= size * scale {
                    let layout = PixelCompanionLayout(width: size, height: size, displayScale: scale, side: side)
                    XCTAssertEqual((layout.cell * scale).rounded(), layout.cell * scale)
                    XCTAssertEqual((layout.originX * scale).rounded(), layout.originX * scale)
                    XCTAssertGreaterThanOrEqual(layout.originX, 0)
                    XCTAssertLessThanOrEqual(layout.originX + layout.cell * Double(side), size)
                }
            }
        }
    }

    func testInvalidClockDoesNotCrashSpriteSelection() {
        for time in [Double.nan, .infinity, -.infinity, -.greatestFiniteMagnitude, .greatestFiniteMagnitude] {
            XCTAssertEqual(PixelCompanion.frame(style: .cat, status: .working, time: time).cells.count, 1600)
        }
    }

    func testSmallNonRetinaCompanionsUseReadableFallbackWithoutClipping() {
        for style in CompanionStyle.allCases {
            for status in AgentStatus.allCases {
                for tick in 0..<40 {
                    let sprite = PixelCompanion.frame(style: style, status: status, time: Double(tick) / 6, detailed: false)
                    XCTAssertEqual(sprite.dimension, 20)
                    XCTAssertEqual(sprite.cells.count, 400)
                    if style == .cat {
                        XCTAssertTrue(sprite.cells.contains("P"))
                        XCTAssertTrue(sprite.cells.contains("M"))
                    } else if status == .working {
                        XCTAssertTrue(sprite.cells.contains("K"))
                        XCTAssertTrue(sprite.cells.contains("W"))
                    }
                    for i in 0..<20 {
                        XCTAssertEqual(sprite[i, 0], ".")
                        XCTAssertEqual(sprite[i, 19], ".")
                        XCTAssertEqual(sprite[0, i], ".")
                        XCTAssertEqual(sprite[19, i], ".")
                    }
                }
            }
        }
    }
}
