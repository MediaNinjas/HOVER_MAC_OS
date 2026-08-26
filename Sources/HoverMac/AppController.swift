import AppKit

/// Orchestrates everything — direct port of `HoverForm.cs`'s state machine and
/// `Tick()` loop. X-axis only (Y stays muted, matching `EnableY = false` on Windows).
///
/// Deliberate divergence from Windows: HOVER never drives the real OS cursor here.
/// It only moves its own on-screen pointer (the ball, drawn in `OverlayWindow`/
/// `ControlPanel`'s `padView`). Your real mouse/trackpad is a fully independent
/// pointer at all times — HOVER can't take it over, fight it, or be affected by it,
/// full stop, regardless of app state. This is intentional per explicit direction
/// after an earlier build warped the real cursor and locked out trackpad input.
final class AppController {
    let sensor = MidiSensor()
    let panel = ControlPanel()
    var overlay: OverlayWindow?
    var settings = Settings.load()

    private var timer: Timer?
    private var targetScreenIndex = 0
    private var overlayScreenName: String?

    // Pointer state.
    private var rawX = 64
    private var centerX = 64.0
    private var px = 0.5
    /// MUTE freezes HOVER's own ball/pointer (stops updating from hand data). It has
    /// nothing to do with the real OS cursor — HOVER never touches that, ever. Two
    /// fully independent pointers: yours (mouse/trackpad) and HOVER's own on-screen
    /// ball, at all times, regardless of HOVER's state.
    private var muted = false
    private var syncing = false

    // CENTER (rest-pose capture).
    private var centering = false
    private var centerSumX = 0.0
    private var centerCount = 0
    private var centerUntil = Date.distantPast

    // MOTION (record → save → drag-to-edge auto-save).
    private var motionClip: [(ms: Int, midi: Double)] = []
    private var motionRecording = false
    private var motionPlaying = false
    private var motionStamp = Date()
    private var playIndex = 0
    private var motionMin = 127.0
    private var motionMax = 0.0
    private var placingBounds = false // review mode: yellow bars visible + draggable
    private var wallDragging = false
    private var yellowL = 0.0
    private var yellowR = 1.0

    // AUTO ranging.
    private var autoRanging = false
    private var autoMin = 127.0
    private var autoMax = 0.0
    private var autoLast = 0.0
    private var autoDir = 0
    private var autoLegStart = 0.0
    private var autoPasses = 0
    private var autoStableUntil = Date.distantPast

    // Legacy MAP (2-point L/R calibrate).
    private var calibrating = false
    private var calibIndex = 0 // 0 = aim right, 1 = aim left
    private var calibRight = 0.0
    private var calibLeft = 0.0
    private var lastConfirm = Date.distantPast

    // MIDI reconnect throttle — Windows retries `sensor.Connect()` on a 2s timer,
    // not every 16ms tick; matching that here avoids hammering CoreMIDI's source scan.
    private var nextConnectAttempt = Date.distantPast

    private var notice: String?
    private var noticeUntil = Date.distantPast
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    /// Hard kill switch: press F12 twice within 600ms to force-terminate the whole
    /// process instantly, regardless of app state. This exists independent of the
    /// MUTE/yield-to-mouse logic on purpose — it must work even if something else in
    /// the app is misbehaving and fighting the real trackpad/mouse.
    private var lastF12Press = Date.distantPast

    var hasXMap: Bool { settings.axisMapped && abs(settings.axisRight - settings.axisLeft) >= 6 }

    func start() {
        setupOverlay()
        wireUI()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        sensor.onSample = { [weak self] x in self?.rawX = x }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.checkForceKill(event)
            return self?.handleKey(event) ?? event
        }
        // Global monitor too — the force-kill must work even if HOVER's own window
        // isn't focused (e.g. the cursor is stuck over some other app).
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.checkForceKill(event)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if sensor.connect() {
            if !hasXMap {
                beginCenter()
            } else {
                // Mirrors the Windows `Shown` handler: a map already exists on launch —
                // symmetrize it around center and land the rest pose on screen middle.
                recenterPan()
            }
        }
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
        // `NSWindow.screen` is nil before the window is first shown, so compare against
        // our own last-known screen name rather than `overlay?.screen` directly — the
        // Windows-side draft had a known bug here (flagged in its own README) where the
        // nil comparison could skip recreating the overlay on a real monitor switch.
        if overlay == nil || overlayScreenName != screenName(screen) {
            overlay?.orderOut(nil)
            let ov = OverlayWindow(screen: screen)
            overlayScreenName = screenName(screen)
            ov.overlayView.onBoundsDragStarted = { [weak self] in self?.wallDragging = true }
            ov.overlayView.onBoundsDragged = { [weak self] l, r in self?.onBoundsDragged(l, r) }
            ov.overlayView.onBoundsDragEnded = { [weak self] in
                self?.wallDragging = false
                if self?.placingBounds == true { self?.autoSaveCorridor() }
            }
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
        panel.recordBtn.target = self
        panel.recordBtn.action = #selector(onRecordTapped)
        panel.playBtn.target = self
        panel.playBtn.action = #selector(onPlayTapped)
        panel.mapBtn.target = self
        panel.mapBtn.action = #selector(onMapTapped)
        panel.autoBtn.target = self
        panel.autoBtn.action = #selector(onAutoTapped)
        panel.muteBtn.target = self
        panel.muteBtn.action = #selector(onMuteTapped)
        panel.centerBtn.target = self
        panel.centerBtn.action = #selector(onCenterTapped)
        panel.monitorBtn.target = self
        panel.monitorBtn.action = #selector(onMonitorTapped)
        panel.flipXCheck.target = self
        panel.flipXCheck.action = #selector(onFlipXChanged)

        panel.smoothSlider.integerValue = settings.smooth
        panel.throwSlider.integerValue = settings.throwReach
        panel.rangeSlider.integerValue = settings.range
        panel.shiftSlider.integerValue = settings.shift
        panel.smoothValue.stringValue = "\(settings.smooth)"
        panel.throwValue.stringValue = "\(settings.throwReach)"
        panel.rangeValue.stringValue = "\(settings.range)"
        panel.shiftValue.stringValue = "\(settings.shift)"
        panel.flipXCheck.state = settings.flipX ? .on : .off

        panel.smoothSlider.target = self; panel.smoothSlider.action = #selector(onSmoothChanged)
        panel.throwSlider.target = self; panel.throwSlider.action = #selector(onThrowChanged)
        panel.rangeSlider.target = self; panel.rangeSlider.action = #selector(onRangeChanged)
        panel.shiftSlider.target = self; panel.shiftSlider.action = #selector(onShiftChanged)
    }

    @objc private func onSmoothChanged() {
        settings.smooth = panel.smoothSlider.integerValue
        panel.smoothValue.stringValue = "\(settings.smooth)"
        settings.save()
    }
    @objc private func onThrowChanged() {
        settings.throwReach = panel.throwSlider.integerValue
        panel.throwValue.stringValue = "\(settings.throwReach)"
        settings.save()
    }
    @objc private func onRangeChanged() {
        // Mirrors Windows' `if (_syncing || _placingBounds) return;` guard — a manual
        // nudge here must not clobber the value `autoSaveCorridor` just committed while
        // the yellow bars are live and being dragged.
        if syncing || placingBounds { return }
        settings.range = panel.rangeSlider.integerValue
        panel.rangeValue.stringValue = "\(settings.range)"
        settings.save()
    }
    @objc private func onShiftChanged() {
        if syncing { return }
        settings.shift = panel.shiftSlider.integerValue
        panel.shiftValue.stringValue = "\(settings.shift)"
        settings.save()
    }
    @objc private func onFlipXChanged() {
        settings.flipX = panel.flipXCheck.state == .on
        settings.save()
    }
    @objc private func onMuteTapped() { toggleMute() }
    @objc private func onMonitorTapped() { switchMonitor() }
    @objc private func onCenterTapped() {
        if placingBounds || hasXMap { setCenterFromHand() } else { beginCenter() }
    }
    @objc private func onRecordTapped() { toggleHumanMotion() }
    @objc private func onPlayTapped() { toggleHumanPlayback() }
    @objc private func onAutoTapped() { autoRanging ? cancelAuto() : startAuto() }
    @objc private func onMapTapped() { calibrating ? cancelCalib() : startCalib() }

    // MARK: - Force kill (F12 F12)

    /// F12 twice within 600ms = immediate hard exit. No mute, no cleanup, no "are
    /// you sure" — the whole point is this works even if the rest of the app is
    /// unresponsive or fighting the user's real input.
    private func checkForceKill(_ event: NSEvent) {
        guard event.keyCode == 111 else { return } // F12
        let now = Date()
        if now.timeIntervalSince(lastF12Press) < 0.6 {
            exit(0)
        }
        lastF12Press = now
    }

    // MARK: - Key handling (MAP confirm/cancel, AUTO confirm/cancel)

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if calibrating {
            if event.keyCode == 36 || event.keyCode == 49 { confirmEdge(); return nil } // Return / Space
            if event.keyCode == 53 { cancelCalib(); return nil } // Escape
        } else if autoRanging {
            if event.keyCode == 36 || event.keyCode == 49 { finishAuto(force: true); return nil }
            if event.keyCode == 53 { cancelAuto(); return nil }
        }
        return event
    }

    // MARK: - Mapping helpers (mirror HorizontalOf / MapCalibrateThrow / Map)

    private func horizontalOf(_ raw: Int) -> Double {
        settings.flipX ? Double(127 - raw) : Double(raw)
    }

    /// Pre-map full-screen throw from rest center — same curve before and during calibrate.
    private func mapCalibrateThrow(_ raw: Int) {
        var dx = Double(raw) - centerX
        if settings.flipX { dx = -dx }
        let reach = max(8, settings.throwReach)
        let targetX = clamp(0.5 + Geometry.axis(dx, reach: reach), 0, 1)
        let alpha = clamp(1.0 - Double(settings.smooth) / 100.0, 0.04, 1)
        px = px + (targetX - px) * alpha
    }

    /// Normal live mapping — mirrors `Map()`.
    private func map(_ raw: Int) {
        let alpha = clamp(1.0 - Double(settings.smooth) / 100.0, 0.04, 1)
        if hasXMap {
            let targetX = Geometry.mappedX(
                midi: horizontalOf(raw),
                axisLeft: settings.axisLeft, axisRight: settings.axisRight,
                screenL: settings.screenBoundLeft, screenR: settings.screenBoundRight)
            var l = clamp(settings.screenBoundLeft, 0, 1)
            var r = clamp(settings.screenBoundRight, 0, 1)
            if r < l { swap(&l, &r) }
            px = clamp(px + (targetX - px) * alpha, l, r)
            return
        }
        mapCalibrateThrow(raw)
    }

    private func toggleMute() { muteHover(!muted) }

    private func muteHover(_ value: Bool) {
        muted = value
        panel.muteBtn.title = muted ? "MUTED" : "MUTE"
        show(muted ? "MUTED" : "LIVE")
    }

    // MARK: - CENTER

    private func beginCenter() {
        guard sensor.connected, !calibrating, !autoRanging, !motionRecording, !motionPlaying else { return }
        centering = true
        centerSumX = 0
        centerCount = 0
        centerUntil = Date().addingTimeInterval(1.2)
        show("CENTER · hold your rest pose")
    }

    private func setCenterFromHand() {
        guard sensor.connected else { return }
        centerX = horizontalOf(rawX)
        show("CENTER SET from your hand")
    }

    // MARK: - Recenter / symmetrize (mirrors RecenterPan / SymmetrizeAxisAroundCenter)

    /// Rest center = midpoint of axis span so `mappedX(center)` lands on screen mid.
    private func symmetrizeAxisAroundCenter() {
        let left = centerX - settings.axisLeft
        let right = settings.axisRight - centerX
        let half = max(max(left, right), 3)
        settings.axisLeft = centerX - half
        settings.axisRight = centerX + half
    }

    /// Called after AUTO locks and on launch if a map already exists — mirrors
    /// `RecenterPan()`'s `HasXMap` branch. (The pre-map else-branch on Windows only
    /// nudges the overlay's cosmetic throw-triangle position, not actual cursor
    /// driving, since `MapCalibrateThrow` never reads `_panX` — safe to skip here.)
    private func recenterPan() {
        guard hasXMap else { return }
        symmetrizeAxisAroundCenter()
        settings.shift = 0
        settings.save()
        syncing = true
        panel.shiftSlider.integerValue = 0
        panel.shiftValue.stringValue = "0"
        syncing = false
        px = 0.5
    }

    // MARK: - RECORD / SAVE / drag-to-edge auto-save

    private func toggleHumanMotion() {
        if motionPlaying { stopHumanPlayback() }
        if motionRecording { finishHumanRecord() } else { startHumanRecord() }
    }

    private func startHumanRecord() {
        guard sensor.connected else { return }
        if autoRanging { cancelAuto() }
        if calibrating { cancelCalib() }
        centering = false
        motionPlaying = false
        motionRecording = true
        placingBounds = false // no bars/walls while recording — plain pointer feel
        settings.axisMapped = false
        motionClip.removeAll()
        motionMin = 127
        motionMax = 0
        motionStamp = Date()
        yellowL = 0
        yellowR = 1
        panel.recordBtn.title = "SAVE"
        panel.playBtn.isEnabled = false
        refreshOverlay()
        showStatus()
    }

    private func sampleHumanRecord() {
        let midi = horizontalOf(rawX)
        let ms = Int(Date().timeIntervalSince(motionStamp) * 1000)
        if motionClip.isEmpty || ms - motionClip[motionClip.count - 1].ms >= 8 {
            motionClip.append((ms, midi))
        }
        if wallDragging { return }
        if midi < motionMin { motionMin = midi }
        if midi > motionMax { motionMax = midi }
    }

    private func finishHumanRecord() {
        guard motionRecording else { return }
        motionRecording = false
        wallDragging = false
        panel.recordBtn.title = "RECORD HAND MOVEMENT"

        if motionClip.count < 12 || motionMax - motionMin < 6 {
            motionClip.removeAll()
            placingBounds = false
            panel.playBtn.isEnabled = false
            show("need a wider sweep — try again")
            refreshOverlay()
            return
        }

        // Recording saved. Yellow bars go live at the screen edges and auto-save from
        // here — drag either one (they mirror around true center) until happy; every
        // drag release commits. No separate save step.
        placingBounds = true
        panel.playBtn.isEnabled = true
        autoSaveCorridor()
        show("SAVED · drag yellow bars to the screen edges")
        refreshOverlay()
    }

    /// Auto-save: recorded MIDI min/max → current yellow screen L/R. Linear only — no
    /// symmetrize. Runs on every drag release; stays in review mode (bars stay live).
    private func autoSaveCorridor() {
        if motionMax < motionMin { swap(&motionMin, &motionMax) }
        guard motionMax - motionMin >= 6 else { return }

        var scaleL = min(yellowL, yellowR)
        var scaleR = max(yellowL, yellowR)
        guard scaleR - scaleL >= 0.04 else { return }
        if scaleL <= 0.02 { scaleL = 0 }
        if scaleR >= 0.98 { scaleR = 1 }

        settings.axisLeft = motionMin
        settings.axisRight = motionMax
        settings.axisMapped = true
        settings.screenBoundLeft = scaleL
        settings.screenBoundRight = scaleR
        settings.range = 100
        settings.shift = 0
        settings.mappedScreen = screenName(targetScreen)
        settings.save()

        syncing = true
        panel.rangeSlider.integerValue = 100
        panel.rangeValue.stringValue = "100"
        panel.shiftSlider.integerValue = 0
        panel.shiftValue.stringValue = "0"
        syncing = false
    }

    private func onBoundsDragged(_ left: Double, _ right: Double) {
        guard placingBounds else { return }
        yellowL = left
        yellowR = right
        if motionMax - motionMin >= 6 {
            px = clamp(Geometry.corridorMappedX(midi: horizontalOf(rawX), motionMin: motionMin, motionMax: motionMax, screenL: yellowL, screenR: yellowR), min(yellowL, yellowR), max(yellowL, yellowR))
        }
        refreshOverlay()
    }

    // MARK: - PLAY

    private func toggleHumanPlayback() {
        motionPlaying ? stopHumanPlayback() : startHumanPlayback()
    }

    private func startHumanPlayback() {
        guard motionClip.count >= 2, !motionRecording else { return }
        if autoRanging { cancelAuto() }
        motionPlaying = true
        playIndex = 0
        motionStamp = Date()
        panel.playBtn.title = "STOP PLAY"
        show("PLAYBACK · replaying your human motion")
    }

    private func sampleHumanPlayback() {
        guard !motionClip.isEmpty else { stopHumanPlayback(); return }
        let elapsed = Int(Date().timeIntervalSince(motionStamp) * 1000)
        while playIndex < motionClip.count - 1 && motionClip[playIndex + 1].ms <= elapsed {
            playIndex += 1
        }
        let midi = motionClip[playIndex].midi
        // Always the LIVE yellow bars, not a frozen snapshot — dragging while this plays
        // must visibly change where the recorded sweep lands, in real time.
        if motionMax - motionMin >= 6 {
            px = Geometry.corridorMappedX(midi: midi, motionMin: motionMin, motionMax: motionMax, screenL: yellowL, screenR: yellowR)
        }
        if playIndex >= motionClip.count - 1 && elapsed >= motionClip.last!.ms {
            stopHumanPlayback()
        }
    }

    private func stopHumanPlayback() {
        guard motionPlaying else { return }
        motionPlaying = false
        panel.playBtn.title = "PLAY"
        panel.playBtn.isEnabled = motionClip.count >= 2
        showStatus()
        refreshOverlay()
    }

    // MARK: - AUTO ranging

    private func startAuto() {
        guard sensor.connected else { return }
        if motionRecording { finishHumanRecord() }
        if motionPlaying { stopHumanPlayback() }
        if calibrating { cancelCalib() }
        centering = false
        autoRanging = true
        autoMin = horizontalOf(rawX)
        autoMax = autoMin
        autoLast = autoMin
        autoDir = 0
        autoLegStart = autoMin
        autoPasses = 0
        autoStableUntil = Date().addingTimeInterval(1.1)
        panel.autoBtn.title = "CANCEL"
        show("AUTO · sweep left and right, enter to lock")
    }

    private func cancelAuto() {
        guard autoRanging else { return }
        autoRanging = false
        panel.autoBtn.title = "AUTO"
        refreshOverlay()
        showStatus()
    }

    private func sampleAuto() {
        let midi = horizontalOf(rawX)
        var grew = false
        if midi < autoMin { autoMin = midi; grew = true }
        if midi > autoMax { autoMax = midi; grew = true }
        if grew { autoStableUntil = Date().addingTimeInterval(1.1) }

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

        if autoPasses >= EdgeSolve.minPasses && span >= EdgeSolve.minMidiSpan && Date() >= autoStableUntil {
            finishAuto(force: false)
        }
    }

    private func finishAuto(force: Bool) {
        guard autoRanging else { return }
        let result = EdgeSolve.trySweep(midiMin: autoMin, midiMax: autoMax, passes: autoPasses, force: force)
        if let err = result.err {
            show(err)
            return
        }
        settings.axisLeft = result.axisLeft
        settings.axisRight = result.axisRight
        settings.axisMapped = true
        settings.range = max(result.range, 140) // MappedRangeDefault on Windows
        settings.shift = 0
        settings.mappedScreen = screenName(targetScreen)
        settings.save()
        syncing = true
        panel.rangeSlider.integerValue = settings.range
        panel.rangeValue.stringValue = "\(settings.range)"
        syncing = false
        cancelAuto()
        // Rest pose = screen center — mirrors Windows calling RecenterPan() + Rematch()
        // after locking, so the axis span is symmetrized around the CENTER pose rather
        // than left as the raw sweep min/max.
        recenterPan()
        map(rawX)
        show("x edge range locked · range \(settings.range)")
    }

    // MARK: - Legacy MAP (2-point left/right calibrate)

    private func startCalib() {
        guard sensor.connected else { return }
        if autoRanging { cancelAuto() }
        if motionRecording { finishHumanRecord() }
        centering = false
        calibrating = true
        calibIndex = 0
        panel.mapBtn.title = "CANCEL"
        refreshOverlay()
        showStatus()
    }

    private func cancelCalib() {
        calibrating = false
        panel.mapBtn.title = "MAP"
        refreshOverlay()
        showStatus()
    }

    private func confirmEdge() {
        guard calibrating else { return }
        guard Date().timeIntervalSince(lastConfirm) >= 0.35 else { return }
        lastConfirm = Date()
        let midi = horizontalOf(rawX)
        if calibIndex == 0 {
            calibRight = midi
            calibIndex = 1
            show("aim hand at the left edge · enter")
            return
        }
        calibLeft = midi
        if abs(calibRight - calibLeft) < EdgeSolve.minMidiSpan {
            show("left and right too close — stretch farther")
            calibIndex = 0
            return
        }
        // Mirrors `EdgeSolve.TryLock`: axisLeft/axisRight are assigned as-aimed, NOT
        // sorted by numeric value — the aim order (right pose, then left pose) is what
        // determines which one is "left" on screen, so the mapping still works even if
        // a given hand's raw MIDI happens to run the "wrong" direction.
        settings.axisLeft = calibLeft
        settings.axisRight = calibRight
        settings.axisMapped = true
        settings.range = 100
        settings.shift = 0
        settings.mappedScreen = screenName(targetScreen)
        settings.save()
        syncing = true
        panel.rangeSlider.integerValue = 100
        panel.rangeValue.stringValue = "100"
        panel.shiftSlider.integerValue = 0
        panel.shiftValue.stringValue = "0"
        syncing = false
        cancelCalib()
        recenterPan()
        map(rawX)
        show("mapped · left/right edges locked")
    }

    // MARK: - Tick

    private func tick() {
        if !sensor.connected {
            if Date() >= nextConnectAttempt {
                nextConnectAttempt = Date().addingTimeInterval(2)
                if sensor.connect() && !hasXMap { beginCenter() }
            }
            showStatus()
            refreshOverlay()
            return
        }
        sensor.keepAlive()

        if centering {
            centerSumX += Double(rawX)
            centerCount += 1
            px = 0.5
            if Date() >= centerUntil && centerCount >= 20 {
                centerX = centerSumX / Double(centerCount)
                centering = false
                recenterPan()
            }
            showStatus()
            refreshOverlay()
            return
        }

        if motionRecording { sampleHumanRecord() }

        if motionPlaying {
            sampleHumanPlayback()
            showStatus()
            refreshOverlay()
            return
        }

        if autoRanging {
            sampleAuto()
            showStatus()
            refreshOverlay()
            return
        }

        if calibrating {
            // Live preview while aiming, same throw as normal pointer feel.
            mapCalibrateThrow(rawX)
            showStatus()
            refreshOverlay()
            return
        }

        // MUTE freezes HOVER's own ball in place — it does not touch the real
        // cursor either way (that's never touched), it just stops updating from
        // hand data.
        if !wallDragging && !muted {
            if placingBounds && !motionRecording && motionMax - motionMin >= 6 {
                // Review phase (after SAVE, before/while dragging): live hand mapped
                // straight through the current yellow corridor — no smoothing. Drag a
                // bar toward the real screen edge and the reach expands to match it.
                px = Geometry.corridorMappedX(midi: horizontalOf(rawX), motionMin: motionMin, motionMax: motionMax, screenL: yellowL, screenR: yellowR)
            } else {
                map(rawX)
            }
        }

        showStatus()
        refreshOverlay()
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
            else if calibrating { panel.statusLabel.stringValue = "aim hand at the \(calibIndex == 0 ? "right" : "left") edge · enter" }
            else if motionRecording { panel.statusLabel.stringValue = "RECORDING" }
            else if motionPlaying { panel.statusLabel.stringValue = "PLAYBACK · drag bars to auto-save" }
            else if placingBounds { panel.statusLabel.stringValue = "SAVED · drag bars to the edges" }
            else if autoRanging { panel.statusLabel.stringValue = "AUTO X · \(autoPasses)/\(EdgeSolve.minPasses)" }
            else if centering { panel.statusLabel.stringValue = "CENTER" }
            else if muted { panel.statusLabel.stringValue = "MUTED" }
            else if hasXMap { panel.statusLabel.stringValue = "MAPPED" }
            else { panel.statusLabel.stringValue = "READY" }
        }
        panel.readoutLabel.stringValue = "X  \(rawX)     Y  MUTE"
        panel.monitorLabel.stringValue = "MONITOR \(targetScreenIndex + 1)/\(NSScreen.screens.count)"
    }

    private func yellowLeft() -> Double { placingBounds ? yellowL : (hasXMap ? settings.screenBoundLeft : 0) }
    private func yellowRight() -> Double { placingBounds ? yellowR : (hasXMap ? settings.screenBoundRight : 1) }

    private func refreshOverlay() {
        setupOverlay()
        guard let overlay else { return }
        let showOverlay = calibrating || autoRanging || motionRecording || placingBounds || !hasXMap
        if !showOverlay {
            overlay.orderOut(nil)
        } else {
            overlay.orderFrontRegardless()
            overlay.setInteractive(placingBounds)
            overlay.overlayView.ballX = px
            overlay.overlayView.boundL = yellowLeft()
            overlay.overlayView.boundR = yellowRight()
            overlay.overlayView.prompt = placingBounds ? "drag yellow bars to the real screen edges — saves automatically" : nil
            overlay.overlayView.refresh()
        }
        refreshPad()
    }

    /// Mirrors `RefreshPad()` — updates the embedded in-panel monitor, distinct
    /// from the full-screen overlay (which only shows in specific states).
    private func refreshPad() {
        panel.padView.x = px
        panel.padView.y = 0.5
        panel.padView.yellowL = yellowLeft()
        panel.padView.yellowR = yellowRight()
        // Mirrors `CenterScreen01()`: yellow midpoint + fader offset, clamped.
        let mid = (yellowLeft() + yellowRight()) / 2
        panel.padView.centerX = clamp(mid + Double(settings.shift) / 100.0, 0, 1)
        panel.padView.refresh()
    }
}
