import XCTest
@testable import SINotchCore

final class IslandPresentationPolicyTests: XCTestCase {
    private var options: IslandPresentationOptions {
        var value = IslandPresentationOptions()
        value.hideWhenIdle = true
        value.dismissAutoRevealOnOutsideClick = true
        return value
    }

    func testReferenceDefaultsKeepIdleAndOutsideClickHidingOff() {
        let defaults = IslandPresentationOptions()
        XCTAssertFalse(defaults.showOnlyWithSessions)
        XCTAssertFalse(defaults.hideWhenIdle)
        XCTAssertFalse(defaults.dismissAutoRevealOnOutsideClick)
        XCTAssertTrue(defaults.hideInFullScreen)
        XCTAssertTrue(defaults.suppressWhenTargetAppFrontmost)
        XCTAssertTrue(defaults.collapseOnMouseLeave)
        XCTAssertFalse(defaults.disableClickJump)
    }

    func testSessionOnlyVisibilityFollowsTheTaskListImmediately() {
        var policy = IslandPresentationPolicy(now: 0)
        var options = IslandPresentationOptions()
        options.showOnlyWithSessions = true
        XCTAssertEqual(policy.decision(options: options, state: .init(), at: 0).hiddenReason, .noSessions)
        policy.noteActivity(at: 1)
        XCTAssertEqual(policy.decision(options: options, state: .init(pointerInside: true), at: 1).hiddenReason, .noSessions)
        XCTAssertTrue(policy.decision(options: options, state: .init(hasSessions: true), at: 2).isVisible)
        XCTAssertTrue(policy.decision(options: options, state: .init(hasSessions: true, hasWorkingSessions: true), at: 3).isVisible)
        XCTAssertEqual(policy.decision(options: options, state: .init(keepOpen: true), at: 4).hiddenReason, .noSessions)
        options.showOnlyWithSessions = false
        XCTAssertTrue(policy.decision(options: options, state: .init(), at: 4).isVisible)
    }

    func testSessionOnlyModePreservesSettingsRequestsAndExplicitManualOpening() {
        var policy = IslandPresentationPolicy(now: 0)
        var options = IslandPresentationOptions()
        options.showOnlyWithSessions = true
        XCTAssertEqual(policy.decision(options: options, state: .init(isSettingsVisible: true), at: 0).hiddenReason, .noSessions)
        XCTAssertTrue(policy.decision(options: options, state: .init(hasPendingRequest: true), at: 0).isVisible)
        policy.expansionChanged(true, origin: .hover, at: 1)
        XCTAssertEqual(policy.decision(options: options, state: .init(isExpanded: true), at: 1).hiddenReason, .noSessions)
        policy.expansionChanged(true, origin: .manual, at: 2)
        XCTAssertTrue(policy.decision(options: options, state: .init(isExpanded: true), at: 2).isVisible)
        XCTAssertTrue(policy.decision(options: options, state: .init(isExpanded: true, isNativeFullScreen: true), at: 2).isVisible)
        policy.expansionChanged(false, origin: .manual, at: 3)
        XCTAssertEqual(policy.decision(options: options, state: .init(), at: 3).hiddenReason, .noSessions)
        policy.expansionChanged(true, origin: .automatic, at: 4)
        XCTAssertEqual(policy.decision(options: options, state: .init(isExpanded: true), at: 4).hiddenReason, .noSessions)
    }

    func testSessionOnlyModeStillRespectsIdleAndFullScreenPreferences() {
        var policy = IslandPresentationPolicy(now: 0)
        var options = self.options
        options.showOnlyWithSessions = true
        XCTAssertEqual(policy.decision(options: options, state: .init(hasSessions: true), at: 30).hiddenReason, .idle)
        XCTAssertTrue(policy.decision(options: options, state: .init(hasSessions: true, hasWorkingSessions: true), at: 31).isVisible)
        XCTAssertEqual(policy.decision(options: options, state: .init(hasSessions: true, isNativeFullScreen: true), at: 32).hiddenReason, .fullScreen)
    }

    func testIdleHidesAtThirtySecondsAndAcceptedActivityWakes() {
        var policy = IslandPresentationPolicy(now: 100)
        let idle = IslandPresentationState()
        XCTAssertTrue(policy.decision(options: options, state: idle, at: 129.999).isVisible)
        XCTAssertEqual(policy.decision(options: options, state: idle, at: 130).hiddenReason, .idle)
        policy.noteActivity(at: 140)
        XCTAssertTrue(policy.decision(options: options, state: idle, at: 140).isVisible)
        XCTAssertEqual(policy.decision(options: options, state: idle, at: 169).idleDeadline, 170)
    }

    func testWorkingAndPendingProtectThePanelAndThenGiveAFullGracePeriod() {
        for protectedState in [IslandPresentationState(hasWorkingSessions: true),
                               IslandPresentationState(hasPendingRequest: true)] {
            var policy = IslandPresentationPolicy(now: 0)
            XCTAssertTrue(policy.decision(options: options, state: protectedState, at: 900).isVisible)
            let released = policy.decision(options: options, state: .init(), at: 910)
            XCTAssertEqual(released.idleDeadline, 940)
            XCTAssertTrue(policy.decision(options: options, state: .init(), at: 939.999).isVisible)
            XCTAssertEqual(policy.decision(options: options, state: .init(), at: 940).hiddenReason, .idle)
        }
    }

    func testPointerAndPinnedExpandedPanelProtectFromIdleButPinDoesNotHoldCompact() {
        for protectedState in [IslandPresentationState(pointerInside: true),
                               IslandPresentationState(isExpanded: true, keepOpen: true)] {
            var policy = IslandPresentationPolicy(now: 0)
            XCTAssertTrue(policy.decision(options: options, state: protectedState, at: 900).isVisible)
        }
        var policy = IslandPresentationPolicy(now: 0)
        XCTAssertEqual(policy.decision(options: options, state: .init(keepOpen: true), at: 30).hiddenReason, .idle)
    }

    func testSettingsKeepsCompactIslandVisibleWhileSuppressingAutomaticReveal() {
        var policy = IslandPresentationPolicy(now: 0)
        var state = IslandPresentationState(hasPendingRequest: true, isNativeFullScreen: true)
        XCTAssertEqual(policy.decision(options: options, state: state, at: 90).hiddenReason, .fullScreen)
        state.isSettingsVisible = true
        XCTAssertTrue(policy.decision(options: options, state: state, at: 91).isVisible)
        state.isSettingsVisible = false
        state.isNativeFullScreen = false
        XCTAssertTrue(policy.decision(options: options, state: state, at: 92).isVisible)
        var disabled = options
        disabled.hideWhenIdle = false
        disabled.hideInFullScreen = false
        XCTAssertTrue(policy.decision(options: disabled, state: .init(isNativeFullScreen: true), at: 1_000).isVisible)
        XCTAssertNil(policy.decision(options: disabled, state: .init(), at: 1_000).idleDeadline)
    }

    func testManualExpansionWakesWithoutTakingOverAnUnrelatedNativeWindow() {
        var policy = IslandPresentationPolicy(now: 0)
        XCTAssertFalse(policy.decision(options: options, state: .init(), at: 60).isVisible)
        policy.expansionChanged(true, origin: .manual, at: 60)
        XCTAssertTrue(policy.decision(options: options, state: .init(isExpanded: true), at: 60).isVisible)
        XCTAssertEqual(policy.expansionOrigin, .manual)
        policy.expansionChanged(true, origin: .automatic, at: 61)
        XCTAssertEqual(policy.expansionOrigin, .manual)
    }

    func testTargetAppSuppressionRequiresAKnownMatchingApplication() {
        let policy = IslandPresentationPolicy(now: 0)
        XCTAssertFalse(policy.canAutomaticallyReveal(options: options, state: .init(),
            targetBundleID: "com.example.Terminal", frontmostBundleID: "com.example.terminal"))
        XCTAssertTrue(policy.canAutomaticallyReveal(options: options, state: .init(),
            targetBundleID: "com.example.Terminal", frontmostBundleID: "com.example.Editor"))
        XCTAssertTrue(policy.canAutomaticallyReveal(options: options, state: .init(),
            targetBundleID: nil, frontmostBundleID: "com.example.Terminal"))
        XCTAssertTrue(policy.canAutomaticallyReveal(options: options, state: .init(),
            targetBundleID: "", frontmostBundleID: ""))
        var disabled = options
        disabled.suppressWhenTargetAppFrontmost = false
        XCTAssertTrue(policy.canAutomaticallyReveal(options: disabled, state: .init(),
            targetBundleID: "com.example.Terminal", frontmostBundleID: "com.example.Terminal"))
        XCTAssertFalse(policy.canAutomaticallyReveal(options: disabled, state: .init(isNativeFullScreen: true),
            targetBundleID: nil, frontmostBundleID: nil))
        XCTAssertFalse(policy.canAutomaticallyReveal(options: disabled, state: .init(isSettingsVisible: true),
            targetBundleID: nil, frontmostBundleID: nil))
    }

    func testOutsideClickOnlyDismissesAnAutomaticUnpinnedPanelWithoutPendingRequests() {
        var policy = IslandPresentationPolicy(now: 0)
        let expanded = IslandPresentationState(isExpanded: true)
        XCTAssertFalse(policy.shouldDismissForOutsideClick(options: options, state: expanded))
        policy.expansionChanged(true, origin: .automatic, at: 1)
        XCTAssertTrue(policy.shouldDismissForOutsideClick(options: options, state: expanded))
        XCTAssertFalse(policy.shouldDismissForOutsideClick(options: options, state: .init(hasPendingRequest: true, isExpanded: true)))
        XCTAssertFalse(policy.shouldDismissForOutsideClick(options: options, state: .init(isExpanded: true, keepOpen: true)))
        var disabled = options
        disabled.dismissAutoRevealOnOutsideClick = false
        XCTAssertFalse(policy.shouldDismissForOutsideClick(options: disabled, state: expanded))
        policy.expansionChanged(true, origin: .manual, at: 2)
        XCTAssertFalse(policy.shouldDismissForOutsideClick(options: options, state: expanded))
        policy.expansionChanged(false, origin: .manual, at: 3)
        XCTAssertNil(policy.expansionOrigin)
        policy.expansionChanged(true, origin: .hover, at: 4)
        policy.expansionChanged(true, origin: .automatic, at: 5)
        XCTAssertEqual(policy.expansionOrigin, .hover)
        XCTAssertFalse(policy.shouldDismissForOutsideClick(options: options, state: expanded))
    }

    func testMouseLeaveAndJumpAreIndependentlyControlled() {
        let policy = IslandPresentationPolicy(now: 0)
        let expanded = IslandPresentationState(isExpanded: true)
        XCTAssertTrue(policy.canCollapseOnMouseLeave(options: options, state: expanded))
        XCTAssertFalse(policy.canCollapseOnMouseLeave(options: options, state: .init(pointerInside: true, isExpanded: true)))
        XCTAssertFalse(policy.canCollapseOnMouseLeave(options: options, state: .init(hasPendingRequest: true, isExpanded: true)))
        XCTAssertFalse(policy.canCollapseOnMouseLeave(options: options, state: .init(isExpanded: true, keepOpen: true)))
        var disabled = options
        disabled.collapseOnMouseLeave = false
        XCTAssertFalse(policy.canCollapseOnMouseLeave(options: disabled, state: expanded))
        XCTAssertTrue(policy.canJump(options: disabled))
        disabled.disableClickJump = true
        XCTAssertFalse(policy.canJump(options: disabled))
    }

    func testNonFiniteAndBackwardActivityCannotPoisonTheMonotonicClock() {
        var policy = IslandPresentationPolicy(now: 100)
        for invalid in [TimeInterval.nan, .infinity, -.infinity, 90] { policy.noteActivity(at: invalid) }
        XCTAssertEqual(policy.decision(options: options, state: .init(), at: 129).idleDeadline, 130)
        XCTAssertEqual(policy.decision(options: options, state: .init(), at: 130).hiddenReason, .idle)
    }

    func testFullscreenStaysQuietForTasksAndRequestsButAllowsIntentionalReveal() {
        var policy = IslandPresentationPolicy(now: 0)
        var options = IslandPresentationOptions()
        options.showOnlyWithSessions = true
        var state = IslandPresentationState(hasWorkingSessions: true, hasPendingRequest: true,
                                             pointerInside: true, keepOpen: true, isNativeFullScreen: true)
        XCTAssertEqual(policy.decision(options: options, state: state, at: 1).hiddenReason, .fullScreen)
        policy.expansionChanged(true, origin: .automatic, at: 2)
        state.isExpanded = true
        XCTAssertEqual(policy.decision(options: options, state: state, at: 2).hiddenReason, .fullScreen)
        policy.expansionChanged(false, origin: .automatic, at: 3)
        policy.expansionChanged(true, origin: .hover, at: 3)
        XCTAssertTrue(policy.decision(options: options, state: state, at: 3).isVisible)
        XCTAssertFalse(policy.canAutomaticallyReveal(options: options, state: state, targetBundleID: nil, frontmostBundleID: nil))
        state.pointerInside = false
        options.collapseOnMouseLeave = false
        XCTAssertTrue(policy.canCollapseOnMouseLeave(options: options, state: state), "Fullscreen hover must dismiss even with a pending request or pin")
        XCTAssertTrue(policy.shouldDismissForOutsideClick(options: options, state: state))
        policy.expansionChanged(false, origin: .hover, at: 4)
        state.isExpanded = false
        XCTAssertEqual(policy.decision(options: options, state: state, at: 4).hiddenReason, .fullScreen)
    }
}
