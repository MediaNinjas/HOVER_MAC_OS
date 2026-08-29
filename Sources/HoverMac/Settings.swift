import Foundation

/// Persisted config. AUTO calibration is kept (it works) and still needs
/// axisLeft/axisRight/axisMapped/screenBoundLeft/Right — those are written by
/// finishAuto(), not user-facing sliders. The only sliders actually exposed
/// in the UI now are Mouse Speed and Center Offset, per direct instruction —
/// Smooth/Throw/Edge Range/X Hand Motion Range/RECORD/MAP were removed as
/// unreliable, confusing, or dead weight across many attempts.
struct Settings: Codable {
    var shift: Int = 0
    var flipX: Bool = true
    var axisMapped: Bool = false
    var axisLeft: Double = 0
    var axisRight: Double = 0
    /// Where AUTO's locked range lands on the real screen (0..1).
    var screenBoundLeft: Double = 0
    var screenBoundRight: Double = 1
    var mappedScreen: String? = nil
    /// "Mouse Speed" — -100...100, 0 = normal (direct 1:1). Pure instant
    /// sensitivity/gain multiplier around the corridor's own center — NOT
    /// smoothing, NOT time-based lag, recomputed fresh every tick. Positive =
    /// same hand movement covers MORE screen distance. Negative = LESS.
    /// Always hard-clamped at the true edges regardless of gain — this can
    /// never trap the ball short of an edge, and it never "readjusts" or pulls
    /// on its own after being set; it's a pure function of the current hand
    /// position and this one number, nothing else, every tick.
    var mouseSpeed: Int = -20

    private enum CodingKeys: String, CodingKey {
        case shift = "Shift"
        case flipX = "FlipX"
        case axisMapped = "AxisMapped"
        case axisLeft = "AxisLeft"
        case axisRight = "AxisRight"
        case screenBoundLeft = "ScreenBoundLeft"
        case screenBoundRight = "ScreenBoundRight"
        case mappedScreen = "MappedScreen"
        case mouseSpeed = "MouseSpeed"
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Media Ninjas/HOVER/pointer.json")
    }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              var loaded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        loaded.shift = clampInt(loaded.shift, -50, 50)
        loaded.mouseSpeed = clampInt(loaded.mouseSpeed, -100, 100)
        loaded.screenBoundLeft = clamp(loaded.screenBoundLeft, 0, 1)
        loaded.screenBoundRight = clamp(loaded.screenBoundRight, 0, 1)
        if loaded.screenBoundRight < loaded.screenBoundLeft {
            swap(&loaded.screenBoundLeft, &loaded.screenBoundRight)
        }
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
