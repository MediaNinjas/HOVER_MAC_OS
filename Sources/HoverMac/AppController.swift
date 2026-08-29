import AppKit

/// Orchestrates everything. X and Y are both live now — deliberately kept as
/// two fully separate code paths (separate MIDI CCs, separate settings,
/// separate AUTO state, separate map()/mapY() functions) rather than one
/// generic shared implementation, so a change to one can never silently
/// affect the other. ENABLE X / ENABLE Y let you turn either off entirely to
/// isolate and tune the other on its own.
///
/// Deliberately minimal otherwise, per direct instruction: AUTO calibration,
/// MUTE, DEVICES, and a small TUNE section. RECORD/SAVE/MAP/CENTER and their
/// whole state machine were removed entirely rather than kept as
/// unused/confusing dead weight — they were unreliable across many attempts
/// and are not needed for AUTO to work.
///
/// HOVER never drives the real OS cursor. It only moves its own on-screen
/// pointer (the ball, drawn in `OverlayWindow`/`ControlPanel`'s `padView`).
/// Your real mouse/trackpad is a fully independent pointer at all times —
/// HOVER can't take it over, fight it, or be affected by it, full stop,
/// regardless of app state. This is intentional per explicit direction after
/// an earlier build warped the real cursor and locked out trackpad input.
final class AppController: NSObject, NSWindowDelegate {
    let sensor = MidiSensor()
    let panel = ControlPanel()
    var overlay: OverlayWindow?
    var settings = Settings.load()

    private var timer: Timer?
    private var targetScreenIndex = 0
    private var overlayScreenName: String?

    // Pointer state — X.
    private var rawX = 64
    private var px = 0.5
    // Pointer state — Y. Kept fully separate from the X fields above.
    private var rawY = 64
    private var py = 0.5
    /// MUTE freezes HOVER's own ball/pointer (stops updating from hand data). It has
    /// nothing to do with the real OS cursor — HOVER never touches that, ever.
    private var muted = false
    private var syncing = false

    /// The screen boundary AUTO locks — always the true edges (0/1) once AUTO
    /// completes. Not touched by anything else: no dragging, no periodic
    /// re-adjustment, nothing "pulls" on this after it's set.
    private var yellowL = 0.0
    private var yellowR = 1.0
    private var yellowTop = 0.0
    private var yellowBottom = 1.0

    // AUTO ranging — X.
    private var autoRanging = false
    private var autoMin = 127.0
    private var autoMax = 0.0
    private var autoLast = 0.0
    private var autoDir = 0
    private var autoLegStart = 0.0
    private var autoPasses = 0
    private var autoStableUntil = Date.distantPast
    // AUTO ranging — Y. Same shape as the X fields above, sampled/locked
    // completely separately.
    private var autoMinY = 127.0
    private var autoMaxY = 0.0
    private var autoLastY = 0.0
    private var autoDirY = 0
    private var autoLegStartY = 0.0
    private var autoPassesY = 0

    /// Every raw CC the hardware is currently sending, mirrored from
    /// `sensor.onRawCC` — purely observational, doesn't feed X or Y unless
    /// `settings.xSourceCC`/`ySourceCC` explicitly picks one of these.
    private var rawCCs: [Int: Int] = [:]
    private var lastKnownCCSet: Set<Int> = []

    /// FIND AXES: walks the user through one deliberate horizontal sweep,
    /// then one deliberate vertical sweep, and assigns whichever raw CC moved
    /// the most during each window — no MIDI/CC knowledge required from them.
    /// horizontal/vertical chain together (FIND AXES); recordX/recordY are
    /// standalone single-axis captures (the per-axis RECORD buttons) that
    /// only ever touch that one axis's source.
    private enum DetectPhase { case idle, horizontal, vertical, recordX, recordY }
    private var detectPhase: DetectPhase = .idle
    private var detectPhaseStart = Date.distantPast
    private var detectRanges: [Int: (min: Double, max: Double)] = [:]
    private let detectDuration: TimeInterval = 2.5
    /// Below this raw MIDI swing, a "winner" isn't trusted — avoids locking
    /// onto sensor noise if the user didn't actually move during the window.
    private let detectMinSwing: Double = 8

    // MIDI reconnect throttle — retry every 2s while disconnected, not every tick.
    private var nextConnectAttempt = Date.distantPast

    private var notice: String?
    private var noticeUntil = Date.distantPast
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    /// Hard kill switch: press F12 twice within 600ms to force-terminate the whole
    /// process instantly, regardless of app state. Independent of MUTE/anything
    /// else — must work even if something else in the app is misbehaving.
    private var lastF12Press = Date.distantPast

    var hasXMap: Bool { settings.axisMapped && abs(settings.axisRight - settings.axisLeft) >= 6 }
    var hasYMap: Bool { settings.axisMappedY && abs(settings.axisBottom - settings.axisTop) >= 6 }

    /// The value actually fed to X's pipeline this tick — `rawX` (the normal
    /// grouped CC4/7/9 union) unless `xSourceCC` overrides it to one specific
    /// raw CC. Falls back to `rawX` if that CC hasn't been seen yet, so an
    /// unset/stale override can't leave X stuck at 0.
    private func rawValueForX() -> Int {
        if let cc = settings.xSourceCC, let v = rawCCs[cc] { return v }
        return rawX
    }

    private func rawValueForY() -> Int {
        if let cc = settings.ySourceCC, let v = rawCCs[cc] { return v }
        return rawY
    }

    func start() {
        yellowL = clamp(settings.screenBoundLeft, 0, 1)
        yellowR = clamp(settings.screenBoundRight, 0, 1)
        yellowTop = clamp(settings.screenBoundTop, 0, 1)
        yellowBottom = clamp(settings.screenBoundBottom, 0, 1)
        setupOverlay()
        wireUI()
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        sensor.onSample = { [weak self] x in self?.rawX = x }
        sensor.onSampleY = { [weak self] y in self?.rawY = y }
        sensor.onRawCC = { [weak self] cc, value in self?.rawCCs[cc] = value }
        sensor.onDevicesChanged = { [weak self] in
            guard let self else { return }
            panel.setDevices(sensor.devices)
        }
        panel.setDevices(sensor.devices)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.checkForceKill(event)
            return self?.handleKey(event) ?? event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.checkForceKill(event)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        sensor.connect()
    }

    // MARK: - Screen / overlay

    private var targetScreen: NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        if let saved = settings.mappedScreen, let match = screens.first(where: { screenName($0) == saved }) {
            return match
        }
        let idx = targetScreenIndex < screens.count ? targetScreenIndex : 0
        return screens[idx]
    }

    private func screenName(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    private func setupOverlay() {
        let screen = targetScreen
        if overlay == nil || overlayScreenName != screenName(screen) {
            overlay?.orderOut(nil)
            let ov = OverlayWindow(screen: screen)
            overlayScreenName = screenName(screen)
            overlay = ov
        }
    }

    private func switchMonitor() {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        targetScreenIndex = (targetScreenIndex + 1) % screens.count
        settings.mappedScreen = screenName(screens[targetScreenIndex])
        settings.save()
        setupOverlay()
        show("using MONITOR \(targetScreenIndex + 1)/\(screens.count)")
    }

    // MARK: - UI wiring

    private func wireUI() {
        panel.autoBtn.target = self
        panel.autoBtn.action = #selector(onAutoTapped)
        panel.muteBtn.target = self
        panel.muteBtn.action = #selector(onMuteTapped)
        panel.monitorBtn.target = self
        panel.monitorBtn.action = #selector(onMonitorTapped)
        panel.quitBtn.target = self
        panel.quitBtn.action = #selector(onQuitTapped)
        panel.flipXCheck.target = self
        panel.flipXCheck.action = #selector(onFlipXChanged)
        panel.flipYCheck.target = self
        panel.flipYCheck.action = #selector(onFlipYChanged)
        panel.enableXCheck.target = self
        panel.enableXCheck.action = #selector(onEnableXChanged)
        panel.enableYCheck.target = self
        panel.enableYCheck.action = #selector(onEnableYChanged)
        panel.enableZCheck.target = self
        panel.enableZCheck.action = #selector(onEnableZChanged)
        panel.xSourceMenu.target = self
        panel.xSourceMenu.action = #selector(onXSourceChanged)
        panel.ySourceMenu.target = self
        panel.ySourceMenu.action = #selector(onYSourceChanged)
        panel.detectBtn.target = self
        panel.detectBtn.action = #selector(onDetectTapped)
        panel.swapBtn.target = self
        panel.swapBtn.action = #selector(onSwapTapped)
        panel.recordXBtn.target = self
        panel.recordXBtn.action = #selector(onRecordXTapped)
        panel.recordYBtn.target = self
        panel.recordYBtn.action = #selector(onRecordYTapped)
        panel.rescanBtn.target = self
        panel.rescanBtn.action = #selector(onRescanTapped)
        panel.onDeviceToggled = { [weak self] name, enabled in
            self?.sensor.setDevice(name, enabled: enabled)
        }

        panel.mouseSpeedSlider.integerValue = settings.mouseSpeed
        panel.shiftSlider.integerValue = settings.shift
        panel.rangeSlider.integerValue = settings.rangeScale
        panel.rangeCenterSlider.integerValue = settings.rangeCenter
        panel.mouseSpeedValue.stringValue = "\(settings.mouseSpeed)"
        panel.shiftValue.stringValue = "\(settings.shift)"
        panel.rangeValue.stringValue = "\(settings.rangeScale)"
        panel.rangeCenterValue.stringValue = "\(settings.rangeCenter)"
        panel.flipXCheck.state = settings.flipX ? .on : .off
        panel.flipYCheck.state = settings.flipY ? .on : .off
        panel.enableXCheck.state = settings.enableX ? .on : .off
        panel.enableYCheck.state = settings.enableY ? .on : .off
        panel.enableZCheck.state = settings.enableZ ? .on : .off
        panel.setSourceOptions([], selectedX: settings.xSourceCC, selectedY: settings.ySourceCC)

        panel.mouseSpeedSlider.target = self; panel.mouseSpeedSlider.action = #selector(onMouseSpeedChanged)
        panel.shiftSlider.target = self; panel.shiftSlider.action = #selector(onShiftChanged)
        panel.rangeSlider.target = self; panel.rangeSlider.action = #selector(onRangeChanged)
        panel.rangeCenterSlider.target = self; panel.rangeCenterSlider.action = #selector(onRangeCenterChanged)
    }

    @objc private func onMouseSpeedChanged() {
        if syncing { return }
        settings.mouseSpeed = panel.mouseSpeedSlider.integerValue
        panel.mouseSpeedValue.stringValue = "\(settings.mouseSpeed)"
        settings.save()
    }

    @objc private func onShiftChanged() {
        if syncing { return }
        settings.shift = panel.shiftSlider.integerValue
        panel.shiftValue.stringValue = "\(settings.shift)"
        settings.save()
    }

    @objc private func onRangeChanged() {
        if syncing { return }
        settings.rangeScale = panel.rangeSlider.integerValue
        panel.rangeValue.stringValue = "\(settings.rangeScale)"
        settings.save()
    }

    @objc private func onRangeCenterChanged() {
        if syncing { return }
        settings.rangeCenter = panel.rangeCenterSlider.integerValue
        panel.rangeCenterValue.stringValue = "\(settings.rangeCenter)"
        settings.save()
    }

    @objc private func onFlipXChanged() {
        settings.flipX = panel.flipXCheck.state == .on
        settings.save()
    }

    @objc private func onFlipYChanged() {
        settings.flipY = panel.flipYCheck.state == .on
        settings.save()
    }

    /// Disabling an axis freezes its half of the ball dead center (0.5) so
    /// it's out of the way visually while you isolate the other axis — it
    /// does not erase that axis's calibration, just stops it from moving.
    @objc private func onEnableXChanged() {
        settings.enableX = panel.enableXCheck.state == .on
        if !settings.enableX { px = 0.5 }
        settings.save()
    }

    @objc private func onEnableYChanged() {
        settings.enableY = panel.enableYCheck.state == .on
        if !settings.enableY { py = 0.5 }
        settings.save()
    }

    /// Z isn't wired to anything on screen — enabling it just starts showing
    /// its raw value in the SOURCES monitor so its CC can be identified.
    @objc private func onEnableZChanged() {
        settings.enableZ = panel.enableZCheck.state == .on
        settings.save()
    }

    @objc private func onXSourceChanged() {
        let tag = panel.xSourceMenu.selectedItem?.tag ?? -1
        settings.xSourceCC = tag == -1 ? nil : tag
        settings.save()
    }

    @objc private func onYSourceChanged() {
        let tag = panel.ySourceMenu.selectedItem?.tag ?? -1
        settings.ySourceCC = tag == -1 ? nil : tag
        settings.save()
    }

    /// Swaps which raw CC drives X vs Y — quick fix if FIND AXES (or a
    /// manual pick) comes out backwards, without redoing detection.
    @objc private func onSwapTapped() {
        swap(&settings.xSourceCC, &settings.ySourceCC)
        settings.save()
        resyncSourceMenus()
        show("SOURCES · swapped X/Y")
    }

    @objc private func onDetectTapped() {
        if detectPhase != .idle {
            cancelDetect()
            return
        }
        guard sensor.connected else { return }
        if autoRanging { cancelAuto() }
        detectPhase = .horizontal
        detectPhaseStart = Date()
        detectRanges = [:]
        panel.detectBtn.title = "CANCEL"
        show("FIND AXES · move hand LEFT-RIGHT now")
    }

    /// Records just Y (or just X below): press it, do the one gesture you
    /// want for that axis, done — the other axis's source is never touched.
    @objc private func onRecordYTapped() {
        if detectPhase == .recordY { cancelDetect(); return }
        guard sensor.connected, detectPhase == .idle else { return }
        if autoRanging { cancelAuto() }
        detectPhase = .recordY
        detectPhaseStart = Date()
        detectRanges = [:]
        panel.recordYBtn.title = "..."
        show("RECORD Y · do the gesture you want now")
    }

    @objc private func onRecordXTapped() {
        if detectPhase == .recordX { cancelDetect(); return }
        guard sensor.connected, detectPhase == .idle else { return }
        if autoRanging { cancelAuto() }
        detectPhase = .recordX
        detectPhaseStart = Date()
        detectRanges = [:]
        panel.recordXBtn.title = "..."
        show("RECORD X · do the gesture you want now")
    }

    private func cancelDetect() {
        detectPhase = .idle
        panel.detectBtn.title = "FIND AXES"
        panel.recordXBtn.title = "RECORD"
        panel.recordYBtn.title = "RECORD"
        showStatus()
    }

    @objc private func onMuteTapped() { toggleMute() }
    @objc private func onMonitorTapped() { switchMonitor() }
    @objc private func onRescanTapped() {
        sensor.rescan()
        showStatus()
    }
    @objc private func onAutoTapped() {
        if detectPhase != .idle { return }
        autoRanging ? cancelAuto() : startAuto()
    }
    @objc private func onQuitTapped() { NSApp.terminate(nil) }

    /// The overlay window is always open on its own, so the panel is never
    /// actually the "last window" when you hit its red close button —
    /// `applicationShouldTerminateAfterLastWindowClosed` never gets a chance
    /// to fire and the app (and the full-screen overlay) is left running.
    /// Quit explicitly instead of relying on that.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: - Force kill (F12 F12)

    /// F12 twice within 600ms = immediate hard exit. No mute, no cleanup, no "are
    /// you sure" — must work even if the rest of the app is unresponsive.
    private func checkForceKill(_ event: NSEvent) {
        guard event.keyCode == 111 else { return } // F12
        let now = Date()
        if now.timeIntervalSince(lastF12Press) < 0.6 {
            exit(0)
        }
        lastF12Press = now
    }

    // MARK: - Key handling (AUTO confirm/cancel)

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if autoRanging {
            if event.keyCode == 36 || event.keyCode == 49 { finishAuto(force: true); return nil } // Return / Space
            if event.keyCode == 53 { cancelAuto(); return nil } // Escape
        }
        return event
    }

    // MARK: - Mapping

    private func horizontalOf(_ raw: Int) -> Double {
        settings.flipX ? Double(127 - raw) : Double(raw)
    }

    private func verticalOf(_ raw: Int) -> Double {
        settings.flipY ? Double(127 - raw) : Double(raw)
    }

    /// Narrows AUTO's measured [left, right] sweep down to the window
    /// `rangeScale`/`rangeCenter` select, so a smaller physical arc still
    /// reaches both true screen edges. Always stays inside the sweep AUTO
    /// actually measured — panning can't go past what your hand proved it
    /// can reach, and at the defaults (100/0) this is a no-op, identical to
    /// using the raw measured axis directly.
    private func effectiveAxis(_ left: Double, _ right: Double) -> (Double, Double) {
        let fullSpan = right - left
        let mid = (left + right) / 2
        let scale = clamp(Double(settings.rangeScale) / 100.0, 0.1, 1.0)
        let span = fullSpan * scale
        let headroom = (fullSpan - span) / 2
        let center = mid + (Double(settings.rangeCenter) / 100.0) * headroom
        return (center - span / 2, center + span / 2)
    }

    /// The only function that ever sets the ball's live position. Before AUTO
    /// has ever locked a range, uses the full fixed 0...127 MIDI range as a
    /// sane default so the ball still does something reasonable.
    ///
    /// Mouse Speed at 0 (the default) is a direct 1:1 map — held at the
    /// hand's true calibrated extreme, the ball is exactly at the true screen
    /// edge, full stop. It does NOT multiply/compress the range around the
    /// corridor center — a gain like that used to silently cap the ball short
    /// of the edge (e.g. gain 0.8 → the ball topped out at 90% of the
    /// screen), which looked exactly like AUTO having locked a smaller range
    /// than it actually did. Negative Mouse Speed only caps how far the ball
    /// can move in a single tick, so it can only ever slow down how fast the
    /// ball follows the hand — held in the same hand position long enough it
    /// always arrives at the exact same target a direct 1:1 map would give.
    private func map(_ raw: Int) {
        let midi = horizontalOf(raw)
        let rawAxisLeft = hasXMap ? settings.axisLeft : 0
        let rawAxisRight = hasXMap ? settings.axisRight : 127
        let (axisLeft, axisRight) = effectiveAxis(rawAxisLeft, rawAxisRight)
        let rawTargetX = Geometry.mappedX(midi: midi, axisLeft: axisLeft, axisRight: axisRight, screenL: yellowL, screenR: yellowR)
        let l = min(yellowL, yellowR), r = max(yellowL, yellowR)
        let targetX = clamp(rawTargetX + Double(settings.shift) / 100.0, l, r)

        // Positive Mouse Speed has no extra effect — 0 is already an instant,
        // uncapped, single-tick jump to targetX, so there's no "faster" than that.
        let speed = min(0, settings.mouseSpeed)
        let maxStep = speed == 0 ? 1.0 : max(0.004, 1.0 + Double(speed) / 100.0)
        let delta = clamp(targetX - px, -maxStep, maxStep)
        px = clamp(px + delta, l, r)
    }

    /// Y's own copy of `effectiveAxis` — deliberately not shared with X's, so
    /// nothing about X's behavior can change if this one is ever edited.
    private func effectiveAxisY(_ top: Double, _ bottom: Double) -> (Double, Double) {
        let fullSpan = bottom - top
        let mid = (top + bottom) / 2
        let scale = clamp(Double(settings.rangeScale) / 100.0, 0.1, 1.0)
        let span = fullSpan * scale
        let headroom = (fullSpan - span) / 2
        let center = mid + (Double(settings.rangeCenter) / 100.0) * headroom
        return (center - span / 2, center + span / 2)
    }

    /// Y's own copy of `map()` — sets `py` only, never touches `px`. Same
    /// direct-1:1-at-0/rate-cap-below-0 Mouse Speed behavior as X, kept as a
    /// fully separate function on purpose.
    private func mapY(_ raw: Int) {
        let midi = verticalOf(raw)
        let rawAxisTop = hasYMap ? settings.axisTop : 0
        let rawAxisBottom = hasYMap ? settings.axisBottom : 127
        let (axisTop, axisBottom) = effectiveAxisY(rawAxisTop, rawAxisBottom)
        let rawTargetY = Geometry.mappedX(midi: midi, axisLeft: axisTop, axisRight: axisBottom, screenL: yellowTop, screenR: yellowBottom)
        let t = min(yellowTop, yellowBottom), b = max(yellowTop, yellowBottom)
        let targetY = clamp(rawTargetY, t, b)

        let speed = min(0, settings.mouseSpeed)
        let maxStep = speed == 0 ? 1.0 : max(0.004, 1.0 + Double(speed) / 100.0)
        let delta = clamp(targetY - py, -maxStep, maxStep)
        py = clamp(py + delta, t, b)
    }

    private func toggleMute() { muteHover(!muted) }

    private func muteHover(_ value: Bool) {
        muted = value
        panel.muteBtn.title = muted ? "MUTED" : "MUTE"
        show(muted ? "MUTED" : "LIVE")
    }

    // MARK: - AUTO ranging

    private func startAuto() {
        guard sensor.connected else { return }
        guard settings.enableX || settings.enableY else {
            show("enable X or Y before AUTO")
            return
        }
        autoRanging = true
        autoMin = horizontalOf(rawValueForX())
        autoMax = autoMin
        autoLast = autoMin
        autoDir = 0
        autoLegStart = autoMin
        autoPasses = 0
        autoMinY = verticalOf(rawValueForY())
        autoMaxY = autoMinY
        autoLastY = autoMinY
        autoDirY = 0
        autoLegStartY = autoMinY
        autoPassesY = 0
        autoStableUntil = Date().addingTimeInterval(1.1)
        panel.autoBtn.title = "CANCEL"
        show("AUTO · sweep enabled axes, enter to lock")
    }

    private func cancelAuto() {
        guard autoRanging else { return }
        autoRanging = false
        panel.autoBtn.title = "AUTO"
        refreshOverlay()
        showStatus()
    }

    private func sampleAuto() {
        var grew = false

        if settings.enableX {
            let midi = horizontalOf(rawValueForX())
            if midi < autoMin { autoMin = midi; grew = true }
            if midi > autoMax { autoMax = midi; grew = true }

            let delta = midi - autoLast
            if abs(delta) >= 1.5 {
                let dir = delta < 0 ? -1 : 1
                if autoDir == 0 {
                    autoDir = dir
                    autoLegStart = midi
                } else if dir != autoDir && abs(autoLast - autoLegStart) >= 5 {
                    autoPasses += 1
                    autoDir = dir
                    autoLegStart = autoLast
                }
                autoLast = midi
            }

            let span = autoMax - autoMin
            px = span < 1 ? 0.5 : clamp((midi - autoMin) / span, 0, 1)
        }

        if settings.enableY {
            let midi = verticalOf(rawValueForY())
            if midi < autoMinY { autoMinY = midi; grew = true }
            if midi > autoMaxY { autoMaxY = midi; grew = true }

            let delta = midi - autoLastY
            if abs(delta) >= 1.5 {
                let dir = delta < 0 ? -1 : 1
                if autoDirY == 0 {
                    autoDirY = dir
                    autoLegStartY = midi
                } else if dir != autoDirY && abs(autoLastY - autoLegStartY) >= 5 {
                    autoPassesY += 1
                    autoDirY = dir
                    autoLegStartY = autoLastY
                }
                autoLastY = midi
            }

            let spanY = autoMaxY - autoMinY
            py = spanY < 1 ? 0.5 : clamp((midi - autoMinY) / spanY, 0, 1)
        }

        if grew { autoStableUntil = Date().addingTimeInterval(1.1) }

        // Only enabled axes gate the lock — a disabled axis is skipped
        // entirely, both for sampling requirements and for what finishAuto
        // ends up writing.
        let xReady = !settings.enableX || (autoPasses >= EdgeSolve.minPasses && (autoMax - autoMin) >= EdgeSolve.minMidiSpan)
        let yReady = !settings.enableY || (autoPassesY >= EdgeSolve.minPasses && (autoMaxY - autoMinY) >= EdgeSolve.minMidiSpan)
        if xReady && yReady && Date() >= autoStableUntil {
            finishAuto(force: false)
        }
    }

    private func finishAuto(force: Bool) {
        guard autoRanging else { return }
        var lockedX = false
        var lockedY = false
        var lockedXLeft = 0.0, lockedXRight = 0.0
        var lockedYTop = 0.0, lockedYBottom = 0.0

        if settings.enableX {
            let result = EdgeSolve.trySweep(midiMin: autoMin, midiMax: autoMax, passes: autoPasses, force: force)
            if let err = result.err {
                show("X: \(err)")
                return
            }
            lockedXLeft = result.axisLeft
            lockedXRight = result.axisRight
            lockedX = true
        }

        if settings.enableY {
            let result = EdgeSolve.trySweep(midiMin: autoMinY, midiMax: autoMaxY, passes: autoPassesY, force: force)
            if let err = result.err {
                show("Y: \(err)")
                return
            }
            lockedYTop = result.axisLeft
            lockedYBottom = result.axisRight
            lockedY = true
        }

        if lockedX {
            settings.axisLeft = lockedXLeft
            settings.axisRight = lockedXRight
            settings.axisMapped = true
            // Always the true screen edges, every time AUTO locks — this was the
            // actual bug behind "space between MIDI 0 and the side": these were
            // never being set here at all, so the screen boundary silently stayed
            // whatever stale value happened to be left over.
            settings.screenBoundLeft = 0
            settings.screenBoundRight = 1
            yellowL = 0
            yellowR = 1
        }
        if lockedY {
            settings.axisTop = lockedYTop
            settings.axisBottom = lockedYBottom
            settings.axisMappedY = true
            settings.screenBoundTop = 0
            settings.screenBoundBottom = 1
            yellowTop = 0
            yellowBottom = 1
        }

        settings.shift = 0
        settings.mappedScreen = screenName(targetScreen)
        settings.save()
        syncing = true
        panel.shiftSlider.integerValue = 0
        panel.shiftValue.stringValue = "0"
        syncing = false
        cancelAuto()
        // No re-adjustment of any kind after this — what AUTO measured is what
        // gets used, permanently, until you run AUTO again. Per direct
        // instruction: nothing pulls on the mapping after it's set.
        if lockedX { map(rawValueForX()) }
        if lockedY { mapY(rawValueForY()) }
        var parts: [String] = []
        if lockedX { parts.append("X \(Int(lockedXLeft))-\(Int(lockedXRight))") }
        if lockedY { parts.append("Y \(Int(lockedYTop))-\(Int(lockedYBottom))") }
        show("locked · " + parts.joined(separator: "  "))
    }

    // MARK: - Tick

    private func tick() {
        if !sensor.connected {
            if Date() >= nextConnectAttempt {
                nextConnectAttempt = Date().addingTimeInterval(2)
                sensor.connect()
            }
            showStatus()
            refreshOverlay()
            return
        }
        sensor.keepAlive()

        if autoRanging {
            sampleAuto()
            refreshSourceOptionsIfNeeded()
            showStatus()
            refreshOverlay()
            return
        }

        if detectPhase != .idle {
            sampleDetect()
            refreshSourceOptionsIfNeeded()
            showStatus()
            refreshOverlay()
            return
        }

        // MUTE freezes HOVER's own ball in place — it does not touch the real
        // cursor either way (that's never touched), it just stops updating
        // from hand data. map()/mapY() are the only functions that can ever
        // set px/py during live tracking, full stop. A disabled axis is
        // pinned to center instead of being left at whatever it last was.
        if !muted {
            if settings.enableX { map(rawValueForX()) } else { px = 0.5 }
            if settings.enableY { mapY(rawValueForY()) } else { py = 0.5 }
        }

        refreshSourceOptionsIfNeeded()
        showStatus()
        refreshOverlay()
    }

    // MARK: - Sources (raw CC monitor / assignment)

    /// Only rebuilds the popup menus when the set of seen CCs actually
    /// changed, and always refreshes the live "CCn:value" text — cheap
    /// enough to call every tick.
    private func refreshSourceOptionsIfNeeded() {
        let ccSet = Set(rawCCs.keys)
        if ccSet != lastKnownCCSet {
            lastKnownCCSet = ccSet
            resyncSourceMenus()
        }
        let text = rawCCs.sorted { $0.key < $1.key }.map { "CC\($0.key):\($0.value)" }.joined(separator: "  ")
        panel.setRawCCText(text.isEmpty ? "no raw CC traffic yet" : text)
    }

    private func resyncSourceMenus() {
        panel.setSourceOptions(lastKnownCCSet.sorted(), selectedX: settings.xSourceCC, selectedY: settings.ySourceCC)
    }

    /// One window watching for horizontal movement, then one watching for
    /// vertical — whichever raw CC swung the most in each window wins that
    /// axis. No CC numbers or MIDI knowledge required from the user at all.
    private func sampleDetect() {
        for (cc, v) in rawCCs {
            let dv = Double(v)
            if let r = detectRanges[cc] {
                detectRanges[cc] = (min(r.min, dv), max(r.max, dv))
            } else {
                detectRanges[cc] = (dv, dv)
            }
        }
        guard Date().timeIntervalSince(detectPhaseStart) >= detectDuration else { return }

        // While picking Y in the FIND AXES chain, ignore whatever CC just won
        // X — a real second axis should win on its own merits, not by riding
        // X's already-large swing. The standalone RECORD buttons don't chain,
        // so nothing needs excluding there.
        let excluded = detectPhase == .vertical ? settings.xSourceCC : nil
        let winner = detectRanges
            .filter { $0.key != excluded }
            .max(by: { ($0.value.max - $0.value.min) < ($1.value.max - $1.value.min) })
        let swing = winner.map { $0.value.max - $0.value.min } ?? 0
        let notEnoughMovement = winner == nil || swing < detectMinSwing

        switch detectPhase {
        case .horizontal:
            guard !notEnoughMovement, let winner else {
                show("FIND AXES · didn't see enough movement, try again")
                cancelDetect()
                return
            }
            settings.xSourceCC = winner.key
            settings.save()
            resyncSourceMenus()
            detectPhase = .vertical
            detectPhaseStart = Date()
            detectRanges = [:]
            show("FIND AXES · now move hand UP-DOWN")
        case .vertical:
            guard !notEnoughMovement, let winner else {
                show("FIND AXES · didn't see enough movement, try again")
                cancelDetect()
                return
            }
            settings.ySourceCC = winner.key
            settings.save()
            resyncSourceMenus()
            cancelDetect()
            show("FIND AXES · done — X=CC\(settings.xSourceCC.map(String.init) ?? "?") Y=CC\(winner.key)")
        case .recordX:
            guard !notEnoughMovement, let winner else {
                show("RECORD X · didn't see enough movement, try again")
                cancelDetect()
                return
            }
            settings.xSourceCC = winner.key
            settings.save()
            resyncSourceMenus()
            cancelDetect()
            show("RECORD X · done — X=CC\(winner.key)")
        case .recordY:
            guard !notEnoughMovement, let winner else {
                show("RECORD Y · didn't see enough movement, try again")
                cancelDetect()
                return
            }
            settings.ySourceCC = winner.key
            settings.save()
            resyncSourceMenus()
            cancelDetect()
            show("RECORD Y · done — Y=CC\(winner.key)")
        case .idle:
            break
        }
    }

    // MARK: - Status / overlay

    private func show(_ text: String) {
        notice = text
        noticeUntil = Date().addingTimeInterval(2.5)
        panel.statusLabel.stringValue = text
    }

    private func showStatus() {
        if let notice, Date() < noticeUntil {
            panel.statusLabel.stringValue = notice
        } else {
            self.notice = nil
            if !sensor.connected { panel.statusLabel.stringValue = sensor.status }
            else if autoRanging {
                panel.statusLabel.stringValue = "AUTO · X \(autoPasses)/\(EdgeSolve.minPasses)  Y \(autoPassesY)/\(EdgeSolve.minPasses)"
            }
            else if detectPhase == .horizontal { panel.statusLabel.stringValue = "FIND AXES · move LEFT-RIGHT" }
            else if detectPhase == .vertical { panel.statusLabel.stringValue = "FIND AXES · move UP-DOWN" }
            else if detectPhase == .recordX { panel.statusLabel.stringValue = "RECORD X · do the gesture" }
            else if detectPhase == .recordY { panel.statusLabel.stringValue = "RECORD Y · do the gesture" }
            else if muted { panel.statusLabel.stringValue = "MUTED" }
            else if !settings.enableX && !settings.enableY { panel.statusLabel.stringValue = "OFF" }
            else if (!settings.enableX || hasXMap) && (!settings.enableY || hasYMap) { panel.statusLabel.stringValue = "MAPPED" }
            else { panel.statusLabel.stringValue = "READY" }
        }
        let lPct = Int((yellowL * 100).rounded())
        let rPct = Int((yellowR * 100).rounded())
        let tPct = Int((yellowTop * 100).rounded())
        let bPct = Int((yellowBottom * 100).rounded())
        panel.readoutLabel.stringValue = "X  \(rawX)   Y  \(rawY)     L\(lPct)% R\(rPct)%  T\(tPct)% B\(bPct)%"
        panel.monitorLabel.stringValue = "MONITOR \(targetScreenIndex + 1)/\(NSScreen.screens.count)"
    }

    /// Always visible during live tracking — an on-screen pointer that hides
    /// itself once calibrated defeats the entire point of the app. It only
    /// ever used to show during AUTO or before the first calibration; fixed
    /// to also show for ordinary live use (MAPPED/MUTED), same as the
    /// panel's own PadView already did.
    private func refreshOverlay() {
        setupOverlay()
        guard let overlay else { return }
        overlay.orderFrontRegardless()
        overlay.overlayView.ballX = px
        overlay.overlayView.ballY = py
        overlay.overlayView.boundL = yellowL
        overlay.overlayView.boundR = yellowR
        overlay.overlayView.prompt = nil
        overlay.overlayView.refresh()
        refreshPad()
    }

    private func refreshPad() {
        panel.padView.x = px
        // PadView is bottom-left origin; py is top-left (0 = top, matching the
        // full-screen overlay), so it needs the same flip FLIP X gets nowhere
        // near — this is purely a coordinate-space conversion for display.
        panel.padView.y = 1 - py
        panel.padView.yellowL = yellowL
        panel.padView.yellowR = yellowR
        let mid = (yellowL + yellowR) / 2
        panel.padView.centerX = clamp(mid + Double(settings.shift) / 100.0, 0, 1)
        panel.padView.refresh()
    }
}
