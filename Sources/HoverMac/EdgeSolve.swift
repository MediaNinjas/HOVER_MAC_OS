import Foundation

/// Direct port of the Windows build's `EdgeSolve` — validates an AUTO sweep before
/// locking hand MIDI extremes to screen edges.
enum EdgeSolve {
    static let minMidiSpan = 6.0
    /// Y's physical range (wrist up/down) is naturally smaller than X's (arm
    /// left/right) for most people — a separate, looser threshold so a small
    /// but real Y sweep isn't rejected as "too close." Doesn't touch X's
    /// value or any X call site at all.
    static let minMidiSpanY = 3.0
    static let minPasses = 3

    /// Continuous edge-to-edge sweep. MIDI min/max become screen 0 and 1,
    /// scaled to the FULL screen regardless of how small that physical range
    /// is — a tiny confirmed sweep covers edge-to-edge exactly like a big
    /// one. Needs a real back-and-forth, not a twitch.
    static func trySweep(
        midiMin: Double,
        midiMax: Double,
        passes: Int,
        force: Bool,
        minSpan: Double = minMidiSpan
    ) -> (axisLeft: Double, axisRight: Double, range: Int, err: String?) {
        if abs(midiMax - midiMin) < minSpan {
            return (midiMin, midiMax, 100, "sweep farther — left and right too close")
        }
        let need = force ? 2 : minPasses
        if passes < need {
            return (midiMin, midiMax, 100, "keep going · \(passes)/\(minPasses) passes")
        }
        return (midiMin, midiMax, 100, nil)
    }
}
