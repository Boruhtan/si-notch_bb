import XCTest
@testable import SINotch

final class AgentPanelLayoutTests: XCTestCase {
    func testKarabasAndPupsikProfilesFitTogetherInConfiguredPanel() {
        let content = AgentPanelLayout.Content(chromeHeight: 144, fullWidthRows: 6, profilesPerGroup: [2, 10, 2])
        let plan = AgentPanelLayout.fit(content, preferred: CGSize(width: 680, height: 560),
                                       available: CGSize(width: 1450, height: 818))
        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.size.width, 680)
        XCTAssertEqual(plan.size.height, 560)
        XCTAssertTrue(plan.fits)
    }

    func testLayoutCanExceedSessionHeightOrWidenToKeepProfilesVisible() {
        let content = AgentPanelLayout.Content(chromeHeight: 140, fullWidthRows: 5, profilesPerGroup: [2, 10, 2])
        let preferred = CGSize(width: 360, height: 360)
        let taller = AgentPanelLayout.fit(content, preferred: preferred, available: CGSize(width: 1000, height: 800))
        XCTAssertEqual(taller.columns, 1)
        XCTAssertEqual(taller.size.width, 360)
        XCTAssertEqual(taller.size.height, 748)
        XCTAssertTrue(taller.fits)

        let wider = AgentPanelLayout.fit(content, preferred: preferred, available: CGSize(width: 1000, height: 600))
        XCTAssertEqual(wider.columns, 2)
        XCTAssertGreaterThan(wider.size.width, preferred.width)
        XCTAssertEqual(wider.size.height, 524)
        XCTAssertTrue(wider.fits)
    }

    func testLargeProfileInventoryOnlyOverflowsWhenScreenIsTooSmall() {
        let content = AgentPanelLayout.Content(chromeHeight: 144, fullWidthRows: 4, profilesPerGroup: [10, 100, 2])
        let preferred = CGSize(width: 680, height: 560)
        let plan = AgentPanelLayout.fit(content, preferred: preferred, available: CGSize(width: 1450, height: 818))
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.columns, 8)
        XCTAssertLessThanOrEqual(plan.size.width, 1450)

        let overflow = AgentPanelLayout.fit(content, preferred: preferred, available: CGSize(width: 700, height: 500))
        XCTAssertFalse(overflow.fits)
        XCTAssertEqual(overflow.size.width, 700)
        XCTAssertEqual(overflow.size.height, 500)
    }
}
