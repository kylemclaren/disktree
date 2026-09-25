// Zooming by hand: the wheel, a pinch and the smart-zoom tap, and the stops
// they meet.
//
// Zoom magnifies the level on screen until the directory under the pointer
// fills the view — its ceiling — and past that goes inside it; at the
// bottom, where the level is whole again, it goes up. Those two stops are
// where a trackpad makes the gesture feel physical: the zoom comes to rest
// against them with a click under the fingers, and a pinch has to squeeze a
// little further to go through, like a detent on a dial. A wheel notch is a
// deliberate step already, and goes straight through.
//
// The state plays no haptic itself: it cannot tell a trackpad from a wheel,
// and a key has no finger on the pad. It says what happened (`ZoomOutcome`)
// and the view decides what that feels like. The view transform is still
// the only thing a zoom within a level changes (Invariant 8).

import CoreGraphics
import DisktreeCore
import Foundation

/// A stop the zoom rests against.
struct ZoomDetent: Equatable {
    enum Stop: Equatable {
        /// The directory under the pointer fills the view: further goes in.
        case ceiling
        /// The level is whole: further goes up.
        case floor
    }

    var stop: Stop
    /// The directory drawn when it was reached.
    var level: [Int]
    /// The directory whose ceiling it is. `nil` for the floor, which is the
    /// same wherever the fingers are.
    var target: [Int]?
    /// The scale it rests at.
    var scale: Double
    /// How far a pinch has squeezed past it, as a factor: above 1 into a
    /// ceiling, below 1 out through the floor.
    var push = 1.0

    /// The same stop, however hard it is being pressed.
    func isSame(as other: Self) -> Bool {
        stop == other.stop && level == other.level && target == other.target
    }

    /// Whether a pinch pressing on it by `push` goes through.
    static func goesThrough(_ stop: Stop, push: Double) -> Bool {
        switch stop {
        case .ceiling: push >= AppState.detentPush
        case .floor: push <= 1 / AppState.detentPush
        }
    }
}

/// Where a smart zoom went, and where from.
struct SmartZoom: Equatable {
    var entered: [Int]
    var from: [Int]
}

/// Who asks for a zoom: each meets the stops its own way.
enum ZoomInput: Equatable {
    /// `=` and `-`: magnification only, never through a level.
    case key
    /// A wheel notch, or a two-finger scroll: straight through a stop.
    case wheel
    /// A pinch: through a stop only with a squeeze past it.
    case pinch
}

extension AppState {
    /// How far past a stop a pinch must squeeze to go through: 12%, more
    /// than a hand resting on the pad drifts, and well short of a second
    /// deliberate pinch. A wheel notch is 15%, and needs no squeeze at all.
    nonisolated static let detentPush = 1.12

    /// How far the zoom must move back off a stop before reaching it again
    /// is a new arrival: fingers trembling at the edge are felt once, not
    /// as a click per event.
    static let detentRelease = 1.03

    /// A scroll of `lines` notches (positive zooms in) at a treemap-local
    /// point; `shift` pans instead.
    ///
    /// A wheel notch goes straight through a stop. After `.changedLevel`,
    /// the view lets the rest of that scroll go (momentum included), or it
    /// would tunnel through several levels in one flick.
    @discardableResult
    public func scroll(
        at point: CGPoint,
        lines: Double,
        shift: Bool
    ) -> ZoomOutcome {
        if abs(lines) < Self.scaleEpsilon {
            return .none
        }
        if shift {
            // A mouse wheel, turned horizontal by shift before the app sees
            // it: up and down, the one way a wheel can pan.
            return pan(lines: 0, lines)
        }
        // A wheel notch is one line, exactly the Rust port's 1.15 step; a
        // trackpad's fractions of a line zoom by fractions of a step, so a
        // swipe is smooth rather than a burst of whole notches.
        return zoom(
            atX: Double(point.x),
            y: Double(point.y),
            factor: pow(1.15, lines),
            input: .wheel
        )
    }

    /// Pan a magnified view by wheel lines along each axis: a shifted swipe
    /// on a trackpad goes whichever way the fingers go. Positive moves the
    /// view's content right and down, as the fingers do. Held inside the
    /// layout at both ends, so no empty band opens up.
    @discardableResult
    public func pan(lines across: Double, _ down: Double) -> ZoomOutcome {
        var panned = view
        panned.originX -= across * 40 / view.scale
        panned.originY -= down * 40 / view.scale
        let before = view
        assign(\.view, panned.clamped(treemapSize))
        guard view != before else {
            return .none
        }
        rehover()
        return .zoomed
    }

    /// A pinch: magnify by `factor` toward a treemap-local point.
    ///
    /// At a stop the zoom rests (`.reachedEdge`, once), and only a squeeze
    /// of `detentPush` beyond it goes in or out a level. After that, the
    /// same pinch goes on magnifying the new level but cannot change level
    /// again until `endMagnify()`: one level per pinch, never a tunnel.
    @discardableResult
    public func magnify(at point: CGPoint, factor: Double) -> ZoomOutcome {
        zoom(
            atX: Double(point.x),
            y: Double(point.y),
            factor: factor,
            input: .pinch
        )
    }

    /// The pinch ended (or was cancelled): the squeeze lets go, and the next
    /// pinch may change level again. Harmless to call when none is in
    /// progress, so the view may call it at a pinch's start as well.
    public func endMagnify() {
        pinchSpent = false
        detent?.push = 1
    }

    /// A two-finger double tap at a treemap-local point: go into the
    /// directory a pinch there would go into, with the same growing
    /// transition.
    ///
    /// The same tap again goes back where the last one came from, as smart
    /// zoom does everywhere on a Mac. With nothing under the pointer to go
    /// into, the view is already at the level a tap there would enter, so
    /// the tap goes back up: to the whole level when it is magnified,
    /// otherwise to the parent.
    @discardableResult
    public func smartZoom(at point: CGPoint) -> ZoomOutcome {
        let before = crumbs
        detent = nil
        if let back = smartZoomed, back.entered == crumbs,
            back.from.count < crumbs.count, crumbs.starts(with: back.from)
        {
            smartZoomed = nil
            leave(to: back.from)
            return crumbs != before ? .changedLevel : .none
        }
        smartZoomed = nil
        if let target = zoomTarget(x: Double(point.x), y: Double(point.y)) {
            enter(target, from: tileBody(target).map { view.project($0) })
            guard crumbs != before else {
                return .none
            }
            smartZoomed = SmartZoom(entered: crumbs, from: before)
            return .changedLevel
        }
        if view.scale > ViewTransform.minScale + Self.scaleEpsilon {
            zoomOutToWhole()
            return .zoomed
        }
        guard let parent = parentCrumbs else {
            return .none
        }
        leave(to: parent)
        return .changedLevel
    }

    /// Zoom toward a treemap-local point. With `descend`, as the wheel does:
    /// the zoom stops magnifying where the directory under the pointer fills
    /// the view, and the next notch goes inside it. Without, as the keys
    /// do: magnification alone.
    ///
    /// That ceiling is what keeps the two gestures continuous: at the
    /// moment the level changes, the tiles inside the directory are already
    /// as large as they will be, so entering makes them grow rather than
    /// shrink.
    @discardableResult
    public func zoom(
        atX x: Double,
        y: Double,
        factor: Double,
        descend: Bool
    ) -> ZoomOutcome {
        zoom(atX: x, y: y, factor: factor, input: descend ? .wheel : .key)
    }

    /// Every zoom, whoever asked: toward `(x, y)` by `factor`, meeting the
    /// stops as `input` does.
    func zoom(
        atX x: Double,
        y: Double,
        factor: Double,
        input: ZoomInput
    ) -> ZoomOutcome {
        guard factor.isFinite, factor > 0, factor != 1 else {
            return .none
        }
        let area = treemapSize
        let inward = factor > 1

        // One directory decides both how far the zoom magnifies and where it
        // then goes: the deepest one under the pointer. At the ceiling its
        // contents fill the view, so going inside continues the same
        // motion.
        let target = input == .key ? nil : zoomTarget(x: x, y: y)
        let body = target.flatMap { tileBody($0) }
        let fit =
            body.map { ViewTransform.fitScale($0, area: area) }
            ?? ViewTransform.maxScale
        let ceiling = min(
            max(fit, ViewTransform.minScale),
            ViewTransform.maxScale
        )

        // Far enough off the stop it rested against, or on another level,
        // reaching one again is a new arrival.
        if let held = detent,
            held.level != crumbs
                || Self.ratio(view.scale, held.scale) > Self.detentRelease
        {
            detent = nil
        }

        let stop = ZoomDetent(
            stop: inward ? .ceiling : .floor,
            level: crumbs,
            target: inward ? target : nil,
            scale: inward ? ceiling : ViewTransform.minScale
        )
        let resting =
            inward
            ? view.scale >= ceiling - Self.scaleEpsilon
            : view.scale <= ViewTransform.minScale + Self.scaleEpsilon
        if resting {
            return press(on: stop, factor: factor, input: input, body: body)
        }

        var factor = factor
        if input == .pinch, !unwind(&factor, inward: inward) {
            return .none
        }
        let before = view
        view = view.zoomed(atX: x, y: y, factor: factor, ceiling: ceiling)
            .clamped(area)
        let moved = view != before
        // Moving off a stop lets go of any squeeze on it.
        if moved {
            detent?.push = 1
        }
        let arrived =
            inward
            ? view.scale >= ceiling - Self.scaleEpsilon
            : view.scale <= ViewTransform.minScale + Self.scaleEpsilon
        guard arrived, input != .key else {
            return moved ? .zoomed : .none
        }
        // Whatever of this event reached past the stop is not a squeeze: the
        // zoom stops there, and going through takes a push of its own.
        if let held = detent, held.isSame(as: stop) {
            return moved ? .zoomed : .none
        }
        detent = stop
        return .reachedEdge
    }

    /// The zoom rests against `stop` and is asked further into it.
    private func press(
        on stop: ZoomDetent,
        factor: Double,
        input: ZoomInput,
        body: Rect?
    ) -> ZoomOutcome {
        switch input {
        case .key:
            return .none
        case .wheel:
            if goThrough(stop, body: body) {
                detent = nil
                return .changedLevel
            }
            // Nowhere to go through to — a file at the ceiling, the scanned
            // root at the floor — so it is only a stop.
            if let held = detent, held.isSame(as: stop) {
                return .none
            }
            detent = stop
            return .reachedEdge
        case .pinch:
            guard var held = detent, held.isSame(as: stop) else {
                // Resting there already when the squeeze began, or the
                // fingers moved over another directory: the stop is felt,
                // and the push starts from here.
                detent = stop
                return .reachedEdge
            }
            if pinchSpent {
                return .none
            }
            held.push *= factor
            if ZoomDetent.goesThrough(held.stop, push: held.push),
                goThrough(stop, body: body)
            {
                detent = nil
                pinchSpent = true
                return .changedLevel
            }
            // Held at the threshold, not wound up past it where there is
            // nowhere to go: pinching back gives way at once.
            held.push =
                switch held.stop {
                case .ceiling: min(held.push, Self.detentPush)
                case .floor: max(held.push, 1 / Self.detentPush)
                }
            detent = held
            return .none
        }
    }

    /// A pinch back off a stop it was squeezing: the squeeze gives way
    /// first, and only what is left of `factor` moves the view. Returns
    /// whether anything is left.
    private func unwind(_ factor: inout Double, inward: Bool) -> Bool {
        guard var held = detent, held.level == crumbs, held.push != 1 else {
            return true
        }
        // Only against the squeeze: out from a ceiling, in from a floor.
        let against =
            switch held.stop {
            case .ceiling: !inward
            case .floor: inward
            }
        guard against else {
            return true
        }
        held.push *= factor
        let still =
            switch held.stop {
            case .ceiling: held.push > 1
            case .floor: held.push < 1
            }
        if still {
            detent = held
            return false
        }
        factor = held.push
        held.push = 1
        detent = held
        return factor != 1
    }

    /// Go in or out a level through `stop`. Returns whether the level
    /// changed: there may be nowhere to go.
    private func goThrough(_ stop: ZoomDetent, body: Rect?) -> Bool {
        let before = crumbs
        switch stop.stop {
        case .ceiling:
            guard let target = stop.target else {
                return false
            }
            enter(target, from: body.map { view.project($0) })
        case .floor:
            ascend()
        }
        return crumbs != before
    }

    /// Back to the whole level from a magnified view, as a motion: the same
    /// layout, so the region in view shrinks from the whole viewport into
    /// where it sits.
    private func zoomOutToWhole() {
        let area = treemapSize
        let whole = Rect(
            x: 0,
            y: 0,
            w: max(Double(area.width), 1),
            h: max(Double(area.height), 1)
        )
        transition = LayoutTransition(src: whole, dst: view.visibleBase(area))
        view = .identity
    }

    /// How far apart two scales are, as a factor of at least 1.
    private static func ratio(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else {
            return .infinity
        }
        return a > b ? a / b : b / a
    }
}
