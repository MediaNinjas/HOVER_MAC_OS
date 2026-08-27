import Foundation

/// Pure hand→screen math — direct port of the Windows build's Axis/EdgeBand/MappedX/
/// CorridorMappedX. No smoothing lerp baked in here; smoothing (if any) is applied by
/// the caller, same split as the Windows code.
enum Geometry {
    static let deadZone = 5.0

    /// Curved dead-zoned axis response, same shape as Windows `Axis()`.
    static func axis(_ delta: Double, reach: Int) -> Double {
        let mag = abs(delta)
        if mag <= deadZone { return 0 }
        let span = max(1.0, Double(reach) - deadZone)
        let t = clamp((mag - deadZone) / span, 0, 1)
        return (delta < 0 ? -1.0 : 1.0) * pow(t, 1.25) * 0.5
    }

    /// Edge Range triangle (pre-map throw band), centered on 0.5 + pan.
    static func edgeBand(range: Int, panX: Double) -> (left: Double, right: Double) {
        let cover = clamp(Double(range) / 100.0, 0.05, 1.0)
        let mid = clamp(0.5 + panX, cover / 2.0, 1.0 - cover / 2.0)
        return (mid - cover / 2.0, mid + cover / 2.0)
    }

    /// Hand MIDI min/max → screen bounds (post-SAVE mapping).
    ///
    /// `marginMidi` — the "X Hand Motion Range" control, in raw MIDI units
    /// (0...127 scale), user-adjustable, default 0. This is how much narrower
    /// than the full axisLeft...axisRight span your wrist actually needs to
    /// rotate to reach the true screen edges — shrink it and less physical
    /// motion covers the same full screen width (more sensitive). At 0, the
    /// full 127-unit range is required, same as no adjustment at all. Sign
    /// doesn't change the effect (both directions shrink by the same amount);
    /// the control just allows reaching that shrink from either a positive or
    /// negative starting value, same idea as the Center Offset slider.
    static func mappedX(midi: Double, axisLeft: Double, axisRight: Double, screenL: Double, screenR: Double, marginMidi: Double = 0) -> Double {
        let span = axisRight - axisLeft
        if abs(span) < 1e-6 { return 0.5 }
        // axisLeft can be greater than axisRight on purpose (unsorted, assigned
        // as-aimed during MAP calibration) — shrink by `margin` in the direction
        // of `span`'s own sign so that direction is preserved exactly, not
        // sorted away.
        let signedMargin = span < 0 ? -abs(marginMidi) : abs(marginMidi)
        let effectiveLeft = axisLeft + signedMargin
        let effectiveSpan = span - 2 * signedMargin
        let t = abs(effectiveSpan) < 1e-6
            ? clamp((midi - axisLeft) / span, 0, 1)
            : clamp((midi - effectiveLeft) / effectiveSpan, 0, 1)
        var l = clamp(screenL, 0, 1)
        var r = clamp(screenR, 0, 1)
        if r < l { swap(&l, &r) }
        return l + t * (r - l)
    }

    /// Linear hand span → yellow corridor. Self-clamped — never overshoots the bars,
    /// no smoothing on top (no "gravity"): direct hard stop at either wall.
    /// Forgiveness margin on the recorded hand range: a human cannot reliably
    /// repeat the exact same physical extreme every time. Getting within this
    /// fraction of the recorded min/max still counts as reaching it — without
    /// this, the ball would require matching a single historical data point
    /// exactly, which reads as "never quite touches the edge" even though the
    /// math is otherwise correct.
    static let edgeForgiveness = 0.12

    static func corridorMappedX(midi: Double, motionMin: Double, motionMax: Double, screenL: Double, screenR: Double) -> Double {
        let handSpan = motionMax - motionMin
        if handSpan < 6 { return (screenL + screenR) / 2 }
        let margin = handSpan * edgeForgiveness
        let effectiveMin = motionMin + margin
        let effectiveMax = motionMax - margin
        let effectiveSpan = max(1, effectiveMax - effectiveMin)
        let t = clamp((midi - effectiveMin) / effectiveSpan, 0, 1)
        let l = min(screenL, screenR)
        let r = max(screenL, screenR)
        return l + t * (r - l)
    }
}
