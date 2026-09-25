// What a gesture feels like under the fingers.
//
// A Force Touch trackpad can tap back. disktree uses that where the mosaic
// behaves like a physical control: the zoom coming to rest against a stop,
// like a detent on a dial; going through it, into a directory or out of
// one; a mark going on or coming off under a ⌘-click. The state never plays
// any of it — it cannot tell a trackpad from a key — and says instead what
// happened (`ZoomOutcome`, `ClickOutcome`); the view, which knows a finger
// was on the pad, turns that into a feel here.
//
// `NSHapticFeedbackManager.defaultPerformer` honours the system's own
// "Force Click and haptic feedback" setting and does nothing without a Force
// Touch trackpad, so nothing here asks about either. Tests put a recorder
// in its place: a test must never tap anyone's trackpad, and the recorder
// is what proves which gesture plays which feel.

import AppKit
import SwiftUI

/// A feel the trackpad can give.
public enum Haptic: Sendable, Hashable, CaseIterable {
    /// The zoom came to rest against a stop: once per arrival.
    case alignment
    /// The directory on screen changed: into one, or out of it.
    case levelChange
    /// Something was done: a mark toggled, a width reached its limit, a
    /// smart-zoom tap landed without changing level.
    case generic

    /// The system's pattern for it.
    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .alignment: .alignment
        case .levelChange: .levelChange
        case .generic: .generic
        }
    }

    /// What a zoom that a finger made feels like: a click as it comes to
    /// rest against a stop, a firmer one as it goes through. Moving within
    /// the level is felt as the motion itself, and needs nothing.
    static func zoom(_ outcome: ZoomOutcome) -> Self? {
        switch outcome {
        case .reachedEdge: .alignment
        case .changedLevel: .levelChange
        case .none, .zoomed: nil
        }
    }

    /// What a two-finger scroll feels like. The wheel goes straight through
    /// a stop with somewhere to go, so the click there is the level
    /// change's, on the next event; an arrival click a frame before it
    /// would blur the two into one muddy pulse. Only a `wall` — nothing to
    /// go into under the pointer, nothing above the scanned root — holds
    /// the wheel, and that is felt as a stop.
    static func scroll(_ outcome: ZoomOutcome, wall: Bool) -> Self? {
        outcome == .reachedEdge && !wall ? nil : zoom(outcome)
    }

    /// What a smart-zoom tap feels like: going in or out a level, as a
    /// pinch through a stop does; otherwise, where it only brought the
    /// whole level back, the tap landing.
    static func smartZoom(_ outcome: ZoomOutcome) -> Self? {
        switch outcome {
        case .changedLevel: .levelChange
        case .zoomed, .reachedEdge: .generic
        case .none: nil
        }
    }

    /// What a click felt, over and above the click itself: a mark made or
    /// taken away. Selecting and opening are what a click always does, and
    /// the trackpad's own click already says so.
    static func click(_ outcome: ClickOutcome) -> Self? {
        outcome == .toggledMark ? .generic : nil
    }
}

/// What one pinch feels like, event by event.
///
/// Going through a stop lands the new level at a stop of its own: out
/// through the floor, the parent appears whole, which is its floor. The
/// pinch's next event arrives there without moving, and its click, a frame
/// after the level change's firmer one, would blur the two into one muddy
/// pulse. So the stop a level change landed on was felt as the level
/// change; once the zoom moves in the new level, the next stop it reaches
/// clicks again.
struct PinchFeel: Sendable, Hashable {
    /// The last level change landed here, and the zoom has not moved since.
    private var landed = false

    /// A new pinch: nothing of the last one is under the fingers.
    mutating func begin() {
        landed = false
    }

    /// What `outcome`, this pinch's latest, feels like.
    mutating func haptic(for outcome: ZoomOutcome) -> Haptic? {
        switch outcome {
        case .changedLevel:
            landed = true
        case .zoomed:
            landed = false
        case .reachedEdge where landed:
            return nil
        case .reachedEdge, .none:
            break
        }
        return Haptic.zoom(outcome)
    }
}

/// Plays haptics: the trackpad in the app, a recorder in tests.
public protocol HapticPerformer: Sendable {
    @MainActor func perform(_ haptic: Haptic)
}

/// The trackpad's own performer.
public struct TrackpadHaptics: HapticPerformer {
    public init() {}

    @MainActor public func perform(_ haptic: Haptic) {
        // Now, not after the next frame: the feel answers the fingers, and
        // a frame may never come — the window can be covered, and a stop
        // that holds the zoom still draws nothing new.
        NSHapticFeedbackManager.defaultPerformer.perform(
            haptic.pattern,
            performanceTime: .now
        )
    }
}

extension EnvironmentValues {
    /// Where a view plays its haptics: the trackpad, unless a test put a
    /// recorder here. The treemap reads it from its host, and a SwiftUI
    /// control that answers a drag — the panel's resize handle at its
    /// limits — plays through it too.
    @Entry public var haptics: any HapticPerformer = TrackpadHaptics()
}

/// Whether macOS lets apps tap the trackpad at all.
///
/// System Settings › Trackpad › "Force Click and haptic feedback" gates
/// `NSHapticFeedbackManager`: with it off, every app's feedback is dropped
/// without a word, disktree's detents included, and nothing an app does
/// changes that. So the app can only say so, and offer the way there.
public enum TrackpadSetting {
    /// The global default behind the switch.
    static let key = "com.apple.trackpad.forceClick"

    /// Whether the switch is on. Absent is the system's default, on.
    public static var allowsHaptics: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Trackpad settings, where the switch is.
    public static let settings = URL(
        string:
            "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
    )
}
