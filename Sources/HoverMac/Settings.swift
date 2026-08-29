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
    /// "Mouse Speed" — -100...100, 0 (default) = direct 1:1, zero artificial
    /// effect on range. Negative values cap how far the ball can move per
    /// tick, so they can only ever slow down how fast the ball follows the
    /// hand — never how far it can ultimately go. Held at the hand's true
    /// calibrated extreme long enough, the ball always reaches the exact true
    /// screen edge regardless of this value. See `AppController.map()`.
    var mouseSpeed: Int = 0
    /// How much of AUTO's measured sweep is actually needed to reach the
    /// screen edges, as a percent of that sweep — 100 (default) = the whole
    /// thing, same as today. Lower values let a smaller physical arc still
    /// reach both true edges. Never widens past what AUTO actually measured.
    var rangeScale: Int = 100
    /// Where the (possibly narrowed) window from `rangeScale` sits inside
    /// AUTO's measured sweep — -100...100, 0 (default) = centered. Panning
    /// only ever moves within the measured sweep, never outside it.
    var rangeCenter: Int = 0

    /// Y axis — its own fields, entirely separate from the X ones above, so
    /// nothing about X's calibration or behavior is touched by any of this.
    var flipY: Bool = false
    var axisMappedY: Bool = false
    var axisTop: Double = 0
    var axisBottom: Double = 0
    var screenBoundTop: Double = 0
    var screenBoundBottom: Double = 1
    /// Independent on/off for each axis, so you can isolate one to test/tune
    /// it without the other moving the ball at all. Both default on.
    var enableX: Bool = true
    var enableY: Bool = true

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
        case rangeScale = "RangeScale"
        case rangeCenter = "RangeCenter"
        case flipY = "FlipY"
        case axisMappedY = "AxisMappedY"
        case axisTop = "AxisTop"
        case axisBottom = "AxisBottom"
        case screenBoundTop = "ScreenBoundTop"
        case screenBoundBottom = "ScreenBoundBottom"
        case enableX = "EnableX"
        case enableY = "EnableY"
    }

    init() {}

    /// Custom decode so a settings file saved before a new field existed
    /// (e.g. RangeScale/RangeCenter, added after ship) loads fine instead of
    /// failing whole-hog and silently wiping the user's real calibration back
    /// to defaults — every field falls back to its normal default if absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shift = try c.decodeIfPresent(Int.self, forKey: .shift) ?? 0
        flipX = try c.decodeIfPresent(Bool.self, forKey: .flipX) ?? true
        axisMapped = try c.decodeIfPresent(Bool.self, forKey: .axisMapped) ?? false
        axisLeft = try c.decodeIfPresent(Double.self, forKey: .axisLeft) ?? 0
        axisRight = try c.decodeIfPresent(Double.self, forKey: .axisRight) ?? 0
        screenBoundLeft = try c.decodeIfPresent(Double.self, forKey: .screenBoundLeft) ?? 0
        screenBoundRight = try c.decodeIfPresent(Double.self, forKey: .screenBoundRight) ?? 1
        mappedScreen = try c.decodeIfPresent(String.self, forKey: .mappedScreen)
        mouseSpeed = try c.decodeIfPresent(Int.self, forKey: .mouseSpeed) ?? 0
        rangeScale = try c.decodeIfPresent(Int.self, forKey: .rangeScale) ?? 100
        rangeCenter = try c.decodeIfPresent(Int.self, forKey: .rangeCenter) ?? 0
        flipY = try c.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
        axisMappedY = try c.decodeIfPresent(Bool.self, forKey: .axisMappedY) ?? false
        axisTop = try c.decodeIfPresent(Double.self, forKey: .axisTop) ?? 0
        axisBottom = try c.decodeIfPresent(Double.self, forKey: .axisBottom) ?? 0
        screenBoundTop = try c.decodeIfPresent(Double.self, forKey: .screenBoundTop) ?? 0
        screenBoundBottom = try c.decodeIfPresent(Double.self, forKey: .screenBoundBottom) ?? 1
        enableX = try c.decodeIfPresent(Bool.self, forKey: .enableX) ?? true
        enableY = try c.decodeIfPresent(Bool.self, forKey: .enableY) ?? true
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
        loaded.rangeScale = clampInt(loaded.rangeScale, 10, 100)
        loaded.rangeCenter = clampInt(loaded.rangeCenter, -100, 100)
        loaded.screenBoundLeft = clamp(loaded.screenBoundLeft, 0, 1)
        loaded.screenBoundRight = clamp(loaded.screenBoundRight, 0, 1)
        if loaded.screenBoundRight < loaded.screenBoundLeft {
            swap(&loaded.screenBoundLeft, &loaded.screenBoundRight)
        }
        loaded.screenBoundTop = clamp(loaded.screenBoundTop, 0, 1)
        loaded.screenBoundBottom = clamp(loaded.screenBoundBottom, 0, 1)
        if loaded.screenBoundBottom < loaded.screenBoundTop {
            swap(&loaded.screenBoundTop, &loaded.screenBoundBottom)
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
