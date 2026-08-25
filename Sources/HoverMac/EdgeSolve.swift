import Foundation

/// Direct port of the Windows build's `EdgeSolve` — validates an AUTO sweep before
/// locking hand MIDI extremes to screen edges.
enum EdgeSolve {
    static let minMidiSpan = 6.0
    static let minPasses = 3

    /// Continuous edge-to-edge sweep. MIDI min/max become screen 0 and 1, range 100.
    /// Needs a real back-and-forth, not a twitch.
    static func trySweep(
        midiMin: Double,
        midiMax: Double,
        passes: Int,
        force: Bool
    ) -> (axisLeft: Double, axisRight: Double, range: Int, err: String?) {
        if abs(midiMax - midiMin) < minMidiSpan {
            return (midiMin, midiMax, 100, "sweep farther — left and right too close")
        }
        let need = force ? 2 : minPasses
        if passes < need {
            return (midiMin, midiMax, 100, "keep going · \(passes)/\(minPasses) passes")
        }
        return (midiMin, midiMax, 100, nil)
    }
}
