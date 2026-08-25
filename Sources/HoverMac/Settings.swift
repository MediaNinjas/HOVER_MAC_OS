import Foundation

/// Persisted config — mirrors the Windows build's `Settings` class field-for-field
/// (X-axis-only fields; Y stays muted here exactly like `EnableY = false` on Windows).
struct Settings: Codable {
    var smooth: Int = 80
    var throwReach: Int = 48
    var range: Int = 40
    var shift: Int = 0
    var flipX: Bool = true
    var axisMapped: Bool = false
    var axisLeft: Double = 0
    var axisRight: Double = 0
    /// Where recorded hand L/R land on the real screen (0..1). Drag yellow bars to change.
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
