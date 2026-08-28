import Foundation

/// Persisted config — mirrors the Windows build's `Settings` class field-for-field
/// (X-axis-only fields; Y stays muted here exactly like `EnableY = false` on Windows).
struct Settings: Codable {
    var smooth: Int = 80
    /// Only used BEFORE a calibration exists (mapCalibrateThrow) — irrelevant
    /// once axisMapped is true. But "irrelevant once mapped" isn't "irrelevant
    /// always": at the slider floor (8) this is extremely twitchy during the
    /// pre-calibration window (tiny hand movement = full swing), which reads as
    /// "flying/too fast" — a real bug this default caused, not a UI complaint.
    /// 48 was the original working value.
    var throwReach: Int = 48
    var range: Int = 100
    /// Reset to 0 — the +35 offset that was here is now baked directly into
    /// screenBoundLeft/Right below, so the slider starts at 0 but the ball still
    /// centers exactly where it did before.
    var shift: Int = 0
    /// "Mouse Speed" — -100...100, 0 = normal (direct 1:1, no scaling). A pure
    /// sensitivity/gain multiplier around screen center, applied instantly
    /// every tick — NOT smoothing, NOT lag, no time delay of any kind. Positive
    /// = the same hand movement covers MORE screen distance (more sensitive/
    /// "faster"). Negative = LESS screen distance (less sensitive/"slower").
    /// Still hard-clamped at the true edges either way — can never trap the
    /// ball short of an edge. Default is -20 (20% slower than normal 1:1).
    var mouseSpeed: Int = -20
    var flipX: Bool = true
    var axisMapped: Bool = false
    var axisLeft: Double = 0
    var axisRight: Double = 0
    /// "X Hand Motion Range" — how many raw MIDI units (0...127 scale) narrower
    /// than the full axisLeft...axisRight span your wrist needs to actually
    /// rotate to reach the true screen edges. 0 = full range required (no
    /// adjustment). Can be positive or negative; both shrink by the same
    /// magnitude — the sign just lets the slider be centered like Center Offset.
    /// Default of 8 reflects the value that reliably reached both true edges
    /// in testing.
    var handMotionRange: Int = 8
    /// Where recorded hand L/R land on the real screen (0..1). Bars start at the
    /// true edges by default — not a leftover position from a previous drag —
    /// and a real RECORD/SAVE overwrites this with an actual calibration anyway.
    var screenBoundLeft: Double = 0
    var screenBoundRight: Double = 1
    var mappedScreen: String? = nil

    private enum CodingKeys: String, CodingKey {
        case smooth = "Smooth"
        case throwReach = "Throw"
        case range = "Range"
        case shift = "Shift"
        case flipX = "FlipX"
        case axisMapped = "AxisMapped"
        case axisLeft = "AxisLeft"
        case axisRight = "AxisRight"
        case handMotionRange = "HandMotionRange"
        case mouseSpeed = "MouseSpeed"
        case screenBoundLeft = "ScreenBoundLeft"
        case screenBoundRight = "ScreenBoundRight"
        case mappedScreen = "MappedScreen"
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Media Ninjas/HOVER/pointer.json")
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              var loaded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }

        if loaded.range < 5 { loaded.range = 40 }
        if loaded.throwReach < 8 { loaded.throwReach = 48 }
        loaded.shift = clampInt(loaded.shift, -50, 50)
        loaded.handMotionRange = clampInt(loaded.handMotionRange, -127, 127)
        loaded.mouseSpeed = clampInt(loaded.mouseSpeed, -100, 100)
        loaded.screenBoundLeft = clamp(loaded.screenBoundLeft, 0, 1)
        loaded.screenBoundRight = clamp(loaded.screenBoundRight, 0, 1)
        if loaded.screenBoundRight < loaded.screenBoundLeft {
            swap(&loaded.screenBoundLeft, &loaded.screenBoundRight)
        }
        if loaded.axisMapped && loaded.screenBoundRight - loaded.screenBoundLeft < 0.04 {
            loaded.screenBoundLeft = 0
            loaded.screenBoundRight = 1
        }
        if loaded.axisMapped && loaded.range < 5 { loaded.range = 100 }
        return loaded
    }

    func save() {
        do {
            let folder = Settings.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(self)
            try data.write(to: Settings.fileURL, options: .atomic)
        } catch {
            NSLog("HOVER: settings save failed: \(error)")
        }
    }
}

func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
