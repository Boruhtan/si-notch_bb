import Foundation

/// Where expansion began. Automatic events must not take ownership of a panel
/// that the user has already opened.
public enum IslandExpansionOrigin: Equatable, Sendable {
    case manual, hover, automatic
}

public struct IslandPresentationOptions: Equatable, Sendable {
    public var showOnlyWithSessions = false
    public var hideWhenIdle = false
    public var hideInFullScreen = true
    public var suppressWhenTargetAppFrontmost = true
    public var dismissAutoRevealOnOutsideClick = false
    public var disableClickJump = false
    public var collapseOnMouseLeave = true

    public init() {}
}

/// AppKit supplies these facts; the policy itself performs no OS queries.
public struct IslandPresentationState: Equatable, Sendable {
    public var hasSessions: Bool
    public var hasWorkingSessions: Bool
    public var hasPendingRequest: Bool
    public var pointerInside: Bool
    public var isExpanded: Bool
    public var keepOpen: Bool
    public var isSettingsVisible: Bool
    public var isNativeFullScreen: Bool

    public init(hasSessions: Bool = false, hasWorkingSessions: Bool = false, hasPendingRequest: Bool = false,
                pointerInside: Bool = false, isExpanded: Bool = false,
                keepOpen: Bool = false, isSettingsVisible: Bool = false,
                isNativeFullScreen: Bool = false) {
        self.hasSessions = hasSessions
        self.hasWorkingSessions = hasWorkingSessions
        self.hasPendingRequest = hasPendingRequest
        self.pointerInside = pointerInside
        self.isExpanded = isExpanded
        self.keepOpen = keepOpen
        self.isSettingsVisible = isSettingsVisible
        self.isNativeFullScreen = isNativeFullScreen
    }
}

public enum IslandHiddenReason: Equatable, Sendable {
    case settings, fullScreen, noSessions, idle
}

public struct IslandPresentationDecision: Equatable, Sendable {
    public let hiddenReason: IslandHiddenReason?
    public var isVisible: Bool { hiddenReason == nil }
    /// Monotonic deadline, available for inspection and deterministic tests.
    public let idleDeadline: TimeInterval?
}

/// Native panel behavior, with time supplied by the caller. Session retention
/// and agent request deadlines are deliberately separate from this UI policy.
public struct IslandPresentationPolicy: Sendable {
    public static let idleDelay: TimeInterval = 30
    public private(set) var expansionOrigin: IslandExpansionOrigin?
    private var lastActivity: TimeInterval
    private var wasProtectedFromIdle = false

    public init(now: TimeInterval) {
        lastActivity = now.isFinite ? now : 0
    }

    /// Call only for accepted visible activity or a direct user interaction;
    /// duplicate/out-of-order events and routine layout are not activity.
    public mutating func noteActivity(at now: TimeInterval) {
        guard now.isFinite else { return }
        lastActivity = max(lastActivity, now)
    }

    public mutating func expansionChanged(_ expanded: Bool, origin: IslandExpansionOrigin,
                                          at now: TimeInterval) {
        if !expanded {
            expansionOrigin = nil
        } else {
            if expansionOrigin == nil || origin == .manual { expansionOrigin = origin }
            noteActivity(at: now)
        }
    }

    public mutating func decision(options: IslandPresentationOptions,
                                  state: IslandPresentationState,
                                  at now: TimeInterval) -> IslandPresentationDecision {
        // Working sessions and live requests must not disappear from inactivity.
        // Leaving these states starts a new grace period, even after a long task.
        let protectedFromIdle = state.hasWorkingSessions || state.hasPendingRequest || state.pointerInside ||
            (state.isExpanded && state.keepOpen) || state.isSettingsVisible
        if protectedFromIdle || wasProtectedFromIdle {
            noteActivity(at: now)
        }
        wasProtectedFromIdle = protectedFromIdle
        let deadline = options.hideWhenIdle ? lastActivity + Self.idleDelay : nil
        let reason: IslandHiddenReason?
        if options.hideInFullScreen && state.isNativeFullScreen && !state.isSettingsVisible {
            // Fullscreen is quiet until an intentional hover or manual action.
            // The OS adapter clears expansions when entering a fullscreen Space.
            let userOpened = state.isExpanded && (expansionOrigin == .hover || expansionOrigin == .manual)
            reason = userOpened ? nil : .fullScreen
        }
        else if options.showOnlyWithSessions && !state.hasSessions && !state.hasPendingRequest &&
                    !(state.isExpanded && expansionOrigin == .manual) { reason = .noSessions }
        else if let deadline, now.isFinite, now >= deadline { reason = .idle }
        else { reason = nil }
        return IslandPresentationDecision(hiddenReason: reason, idleDeadline: deadline)
    }

    public func canAutomaticallyReveal(options: IslandPresentationOptions,
                                       state: IslandPresentationState,
                                       targetBundleID: String?, frontmostBundleID: String?) -> Bool {
        guard !state.isSettingsVisible,
              !(options.hideInFullScreen && state.isNativeFullScreen) else { return false }
        guard options.suppressWhenTargetAppFrontmost,
              let targetBundleID, !targetBundleID.isEmpty,
              let frontmostBundleID, !frontmostBundleID.isEmpty else { return true }
        return targetBundleID.caseInsensitiveCompare(frontmostBundleID) != .orderedSame
    }

    public func shouldDismissForOutsideClick(options: IslandPresentationOptions,
                                            state: IslandPresentationState) -> Bool {
        if options.hideInFullScreen && state.isNativeFullScreen { return state.isExpanded }
        return options.dismissAutoRevealOnOutsideClick && expansionOrigin == .automatic &&
            state.isExpanded && !state.hasPendingRequest && !state.keepOpen
    }

    public func canCollapseOnMouseLeave(options: IslandPresentationOptions,
                                       state: IslandPresentationState) -> Bool {
        if options.hideInFullScreen && state.isNativeFullScreen { return state.isExpanded && !state.pointerInside }
        return options.collapseOnMouseLeave && state.isExpanded && !state.pointerInside &&
            !state.hasPendingRequest && !state.keepOpen
    }

    public func canJump(options: IslandPresentationOptions) -> Bool { !options.disableClickJump }
}
