import AppKit

/// Orchestrates everything. X-axis only (Y stays muted, matching the Windows
/// build's `EnableY = false`).
///
/// Deliberately minimal, per direct instruction: only AUTO calibration (it
/// works), MUTE, DEVICES, and two sliders (Mouse Speed, Center Offset) exist
/// here now. RECORD/SAVE/MAP/CENTER and their whole state machine were
/// removed entirely rather than kept as unused/confusing dead weight — they
/// were unreliable across many attempts and are not needed for AUTO to work.
///
/// HOVER never drives the real OS cursor. It only moves its own on-screen
/// pointer (the ball, drawn in `OverlayWindow`/`ControlPanel`'s `padView`).
/// Your real mouse/trackpad is a fully independent pointer at all times —
/// HOVER can't take it over, fight it, or be affected by it, full stop,
/// regardless of app state. This is intentional per explicit direction after
/// an earlier build warped the real cursor and locked out trackpad input.
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
    private var px = 0.5
    /// MUTE freezes HOVER's own ball/pointer (stops updating from hand data). It has
    /// nothing to do with the real OS cursor — HOVER never touches that, ever.
    private var muted = false
    private var syncing = false

    /// The screen boundary AUTO locks — always the true edges (0/1) once AUTO
    /// completes. Not touched by anything else: no dragging, no periodic
    /// re-adjustment, nothing "pulls" on this after it's set.
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

    func start() {
        yellowL = clamp(settings.screenBoundLeft, 0, 1)
        yellowR = clamp(settings.screenBoundRight, 0, 1)
        setupOverlay()
        wireUI()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        sensor.onSample = { [weak self] x in self?.rawX = x }
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
        panel.flipXCheck.target = self
        panel.flipXCheck.action = #selector(onFlipXChanged)
        panel.rescanBtn.target = self
        panel.rescanBtn.action = #selector(onRescanTapped)
        panel.onDeviceToggled = { [weak self] name, enabled in
            self?.sensor.setDevice(name, enabled: enabled)
        }

        panel.mouseSpeedSlider.integerValue = settings.mouseSpeed
        panel.shiftSlider.integerValue = settings.shift
        panel.mouseSpeedValue.stringValue = "\(settings.mouseSpeed)"
        panel.shiftValue.stringValue = "\(settings.shift)"
        panel.flipXCheck.state = settings.flipX ? .on : .off

        panel.mouseSpeedSlider.target = self; panel.mouseSpeedSlider.action = #selector(onMouseSpeedChanged)
        panel.shiftSlider.target = self; panel.shiftSlider.action = #selector(onShiftChanged)
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

    @objc private func onFlipXChanged() {
        settings.flipX = panel.flipXCheck.state == .on
        settings.save()
    }

    @objc private func onMuteTapped() { toggleMute() }
    @objc private func onMonitorTapped() { switchMonitor() }
    @objc private func onRescanTapped() {
        sensor.rescan()
        showStatus()
    }
    @objc private func onAutoTapped() { autoRanging ? cancelAuto() : startAuto() }

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

    /// The only function that ever sets the ball's live position. Direct,
    /// 1:1, no smoothing/easing/lag of any kind — hard-clamped at either true
    /// edge, nothing else touches it. Before AUTO has ever locked a range,
    /// uses the full fixed 0...127 MIDI range as a sane default so the ball
    /// still does something reasonable.
    private func map(_ raw: Int) {
        let midi = horizontalOf(raw)
        let axisLeft = hasXMap ? settings.axisLeft : 0
        let axisRight = hasXMap ? settings.axisRight : 127
        let targetX = Geometry.mappedX(midi: midi, axisLeft: axisLeft, axisRight: axisRight, screenL: yellowL, screenR: yellowR)
        let l = min(yellowL, yellowR), r = max(yellowL, yellowR)
        // "Mouse Speed": pure instant gain around the corridor's own center —
        // no smoothing, no time delay. See Settings.mouseSpeed doc.
        let mid = (l + r) / 2
        let gain = 1.0 + Double(settings.mouseSpeed) / 100.0
        let scaledX = mid + (targetX - mid) * gain + Double(settings.shift) / 100.0
        px = clamp(scaledX, l, r)
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
        // Always the true screen edges, every time AUTO locks — this was the
        // actual bug behind "space between MIDI 0 and the side": these were
        // never being set here at all, so the screen boundary silently stayed
        // whatever stale value happened to be left over.
        settings.screenBoundLeft = 0
        settings.screenBoundRight = 1
        yellowL = 0
        yellowR = 1
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
        map(rawX)
        show("locked · \(Int(result.axisLeft))-\(Int(result.axisRight))")
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
            showStatus()
            refreshOverlay()
            return
        }

        // MUTE freezes HOVER's own ball in place — it does not touch the real
        // cursor either way (that's never touched), it just stops updating
        // from hand data. This is the ONLY function that can ever set px
        // during live tracking, full stop.
        if !muted {
            map(rawX)
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
            else if autoRanging { panel.statusLabel.stringValue = "AUTO X · \(autoPasses)/\(EdgeSolve.minPasses)" }
            else if muted { panel.statusLabel.stringValue = "MUTED" }
            else if hasXMap { panel.statusLabel.stringValue = "MAPPED" }
            else { panel.statusLabel.stringValue = "READY" }
        }
        let lPct = Int((yellowL * 100).rounded())
        let rPct = Int((yellowR * 100).rounded())
        panel.readoutLabel.stringValue = "X  \(rawX)     Y  MUTE     L\(lPct)% R\(rPct)%"
        panel.monitorLabel.stringValue = "MONITOR \(targetScreenIndex + 1)/\(NSScreen.screens.count)"
    }

    private func refreshOverlay() {
        setupOverlay()
        guard let overlay else { return }
        let showOverlay = autoRanging || !hasXMap
        if !showOverlay {
            overlay.orderOut(nil)
        } else {
            overlay.orderFrontRegardless()
            overlay.overlayView.ballX = px
            overlay.overlayView.boundL = yellowL
            overlay.overlayView.boundR = yellowR
            overlay.overlayView.prompt = nil
            overlay.overlayView.refresh()
        }
        refreshPad()
    }

    private func refreshPad() {
        panel.padView.x = px
        panel.padView.y = 0.5
        panel.padView.yellowL = yellowL
        panel.padView.yellowR = yellowR
        let mid = (yellowL + yellowR) / 2
        panel.padView.centerX = clamp(mid + Double(settings.shift) / 100.0, 0, 1)
        panel.padView.refresh()
    }
}
