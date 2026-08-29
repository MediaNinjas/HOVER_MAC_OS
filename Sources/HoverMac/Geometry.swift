import Foundation

/// Pure hand→screen math. Deliberately minimal — just the one function AUTO's
/// locked range actually needs. No forgiveness margin, no smoothing, no dead
/// zone curve: raw MIDI extreme maps to true screen edge, exactly, always.
enum Geometry {
    /// Hand MIDI axisLeft...axisRight → screen screenL...screenR, linear, hard
    /// clamped. `axisLeft` can be greater than `axisRight` on purpose
    /// (unsorted, assigned as-aimed) — direction is preserved exactly via
    /// `span`'s own sign, never sorted away.
    static func mappedX(midi: Double, axisLeft: Double, axisRight: Double, screenL: Double, screenR: Double) -> Double {
        let span = axisRight - axisLeft
        if abs(span) < 1e-6 { return 0.5 }
        let t = clamp((midi - axisLeft) / span, 0, 1)
        var l = clamp(screenL, 0, 1)
        var r = clamp(screenR, 0, 1)
        if r < l { swap(&l, &r) }
        return l + t * (r - l)
    }
}
