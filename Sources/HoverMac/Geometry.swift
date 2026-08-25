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
    static func mappedX(midi: Double, axisLeft: Double, axisRight: Double, screenL: Double, screenR: Double) -> Double {
        let span = axisRight - axisLeft
        if abs(span) < 1e-6 { return 0.5 }
        let t = clamp((midi - axisLeft) / span, 0, 1)
        var l = clamp(screenL, 0, 1)
        var r = clamp(screenR, 0, 1)
        if r < l { swap(&l, &r) }
        return l + t * (r - l)
    }

    /// Linear hand span → yellow corridor. Self-clamped — never overshoots the bars,
    /// no smoothing on top (no "gravity"): direct hard stop at either wall.
    static func corridorMappedX(midi: Double, motionMin: Double, motionMax: Double, screenL: Double, screenR: Double) -> Double {
        let handSpan = motionMax - motionMin
        if handSpan < 6 { return (screenL + screenR) / 2 }
        let t = clamp((midi - motionMin) / handSpan, 0, 1)
        let l = min(screenL, screenR)
        let r = max(screenL, screenR)
        return l + t * (r - l)
    }
}
