import AppKit

// Same palette as Windows' `Native.Tron` / `HoverForm`'s button/section colors.
private enum Neon {
    static let cyan = NSColor(red: 0, green: 229/255, blue: 255/255, alpha: 1)
    static let dimCyan = NSColor(red: 0, green: 160/255, blue: 180/255, alpha: 1)
    static let faintCyan = NSColor(red: 0, green: 120/255, blue: 150/255, alpha: 1)
    static let borderCyan = NSColor(red: 0, green: 140/255, blue: 160/255, alpha: 1)
    static let panelFill = NSColor(red: 8/255, green: 18/255, blue: 22/255, alpha: 1)
    static let orange = NSColor(red: 1, green: 106/255, blue: 0, alpha: 1)
}

private func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
}

/// Plain `NSButton(checkboxWithTitle:)` titles default to a system label color that
/// is effectively invisible against this app's black background (no contrast) —
/// every checkbox needs its title set explicitly like this, not just `.font`.
private func checkboxTitle(_ text: String) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: mono(10),
        .foregroundColor: Neon.dimCyan
    ])
}

/// A flat, bordered, cyan-on-black button matching Windows' `StyleButton`.
final class NeonButton: NSButton {
    private let border = CALayer()

    convenience init(title: String) {
        self.init(title: title, target: nil, action: nil)
        isBordered = false
        wantsLayer = true
        font = mono(11, bold: true)
        contentTintColor = Neon.cyan
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: mono(11, bold: true),
            .foregroundColor: Neon.cyan
        ])
        layer?.backgroundColor = Neon.panelFill.cgColor
        border.borderColor = Neon.borderCyan.cgColor
        border.borderWidth = 1
        layer?.addSublayer(border)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    func setActive(_ active: Bool, activeColor: NSColor = Neon.orange) {
        let color = active ? activeColor : Neon.cyan
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: mono(11, bold: true),
            .foregroundColor: color
        ])
        border.borderColor = color.cgColor
    }

    override func layout() {
        super.layout()
        border.frame = bounds
    }
}

/// Bordered section box with a title, matching Windows' `GroupBox` styling.
private final class SectionBox: NSView {
    let body = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let border = CALayer()

    init(_ title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.stringValue = title
        titleLabel.font = mono(9, bold: true)
        titleLabel.textColor = Neon.dimCyan
        titleLabel.backgroundColor = .black
        titleLabel.drawsBackground = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        border.borderColor = Neon.borderCyan.withAlphaComponent(0.6).cgColor
        border.borderWidth = 1
        layer?.addSublayer(border)

        body.orientation = .horizontal
        body.spacing = 6
        body.distribution = .fillEqually
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(body)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: -7),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        border.frame = bounds
    }
}

/// Embedded live-position monitor — port of Windows' `Pad` control (the small
/// graph at the top of the panel, distinct from the full-screen `OverlayWindow`).
/// Same visual language: grid crosshair, cyan frame, orange throw-triangle,
/// yellow corridor bars, the ball, and a hot-pink edge line when pinned at 0/1.
final class PadView: NSView {
    var x: Double = 0.5
    var y: Double = 0.5
    var yellowL: Double = 0
    var yellowR: Double = 1
    var centerX: Double = 0.5

    /// Dragging these bars works identically no matter what mode/state the rest of
    /// the app is in — there is no "enter calibrate mode" toggle here on purpose.
    /// Ordinary in-window dragging (no full-screen tricks, no click-through games),
    /// so it can never affect anything outside this small view.
    var onLeftBarDragged: ((Double) -> Void)?
    var onRightBarDragged: ((Double) -> Void)?
    var onBarDragEnded: (() -> Void)?

    /// Without this, the FIRST click on a bar when the window isn't already key
    /// just activates the window instead of starting a real drag — the click gets
    /// silently eaten. That's exactly the kind of "won't let me grab it" behavior
    /// that read as the app fighting the mouse. Always treat clicks here as real.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dragging = 0 // 0 none, 1 left, 2 right
    private var panRecognizer: NSPanGestureRecognizer?

    override var isFlipped: Bool { false } // bottom-left origin, matches Windows GDI+ Y-up math here.

    func refresh() { setNeedsDisplay(bounds) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpPanRecognizer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpPanRecognizer()
    }

    private func setUpPanRecognizer() {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        panRecognizer = pan
    }

    /// x-position (0...1) across the view's full width — no inset, no margin.
    /// Mouse position and bar position share this exact same [0, bounds.width]
    /// range everywhere, with nothing between them.
    private func x01(for pointInView: NSPoint) -> Double {
        Double(clamp(Double(pointInView.x / max(1, bounds.width)), 0, 1))
    }

    private func barScreenX(_ x01: Double) -> CGFloat {
        CGFloat(x01) * bounds.width
    }

    @objc private func handlePan(_ gr: NSPanGestureRecognizer) {
        let p = gr.location(in: self)
        switch gr.state {
        case .began:
            // Whichever bar is closer wins — no minimum-distance tolerance to fail
            // silently. You always grab something when you click down.
            let sL = barScreenX(yellowL), sR = barScreenX(yellowR)
            dragging = abs(p.x - sL) <= abs(p.x - sR) ? 1 : 2
        case .changed:
            guard dragging != 0 else { return }
            let v = x01(for: p)
            if dragging == 1 { onLeftBarDragged?(v) } else { onRightBarDragged?(v) }
        case .ended, .cancelled, .failed:
            if dragging != 0 { onBarDragEnded?() }
            dragging = 0
        default:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(red: 6/255, green: 16/255, blue: 20/255, alpha: 1).setFill()
        ctx.fill(bounds)

        let w = bounds.width, h = bounds.height
        // Bars span the view's full width (0...w) — exactly matching the drag
        // coordinate space in x01(for:)/barScreenX(_:). Only top/bottom keep a
        // small cosmetic margin; that never affects horizontal (bar) position.
        let left: CGFloat = 0, top: CGFloat = 4
        let right = w, bottom = h - 4
        let originX = left + CGFloat(clamp(centerX, 0, 1)) * (right - left)
        let originY = bottom

        let grid = NSColor(red: 0, green: 50/255, blue: 70/255, alpha: 1)
        let hot = NSColor(red: 1, green: 220/255, blue: 80/255, alpha: 1)

        ctx.setStrokeColor(grid.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: w / 2, y: 10)); ctx.addLine(to: CGPoint(x: w / 2, y: h - 10))
        ctx.move(to: CGPoint(x: 10, y: h / 2)); ctx.addLine(to: CGPoint(x: w - 10, y: h / 2))
        ctx.strokePath()

        ctx.setStrokeColor(Neon.cyan.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: left, y: top)); ctx.addLine(to: CGPoint(x: right, y: top))
        ctx.move(to: CGPoint(x: left, y: top)); ctx.addLine(to: CGPoint(x: left, y: bottom))
        ctx.move(to: CGPoint(x: right, y: top)); ctx.addLine(to: CGPoint(x: right, y: bottom))
        ctx.strokePath()

        if x <= 0.02 || x >= 0.98 {
            ctx.setStrokeColor(hot.cgColor)
            ctx.setLineWidth(2.5)
            let hx = x <= 0.02 ? left : right
            ctx.move(to: CGPoint(x: hx, y: top)); ctx.addLine(to: CGPoint(x: hx, y: bottom))
            ctx.strokePath()
        }

        let innerL = left + CGFloat(yellowL) * (right - left)
        let innerR = left + CGFloat(yellowR) * (right - left)
        let innerTop = top + (bottom - top) * 0.35

        ctx.setStrokeColor(Neon.orange.cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: originX, y: originY)); ctx.addLine(to: CGPoint(x: innerL, y: innerTop))
        ctx.move(to: CGPoint(x: originX, y: originY)); ctx.addLine(to: CGPoint(x: innerR, y: innerTop))
        ctx.move(to: CGPoint(x: innerL, y: innerTop)); ctx.addLine(to: CGPoint(x: innerR, y: innerTop))
        ctx.strokePath()

        if yellowR - yellowL > 0.04 {
            ctx.setStrokeColor(hot.cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: innerL, y: top)); ctx.addLine(to: CGPoint(x: innerL, y: bottom))
            ctx.move(to: CGPoint(x: innerR, y: top)); ctx.addLine(to: CGPoint(x: innerR, y: bottom))
            ctx.strokePath()
        }

        let bx = 12 + CGFloat(x) * (w - 24)
        let by = 12 + CGFloat(y) * (h - 24)
        ctx.setFillColor(Neon.cyan.cgColor)
        ctx.fillEllipse(in: CGRect(x: bx - 5, y: by - 5, width: 10, height: 10))
    }
}

/// The HOVER control window — mirrors the Windows form's MOTION + TOOLS + TUNE panels.
final class ControlPanel: NSWindow {
    let statusLabel = NSTextField(labelWithString: "SEARCHING GRID")
    let readoutLabel = NSTextField(labelWithString: "X  ---")
    let monitorLabel = NSTextField(labelWithString: "MONITOR")
    let padView = PadView()

    let recordBtn = NeonButton(title: "RECORD HAND MOVEMENT")
    let playBtn = NeonButton(title: "PLAY")
    let mapBtn = NeonButton(title: "MAP")
    let autoBtn = NeonButton(title: "AUTO")
    let muteBtn = NeonButton(title: "MUTE")
    let centerBtn = NeonButton(title: "SET")
    let monitorBtn = NeonButton(title: "MONITOR")
    let flipXCheck = NSButton(checkboxWithTitle: "FLIP X", target: nil, action: nil)

    let smoothSlider = NSSlider(value: 80, minValue: 0, maxValue: 100, target: nil, action: nil)
    let throwSlider = NSSlider(value: 48, minValue: 8, maxValue: 150, target: nil, action: nil)
    let rangeSlider = NSSlider(value: 40, minValue: 5, maxValue: 200, target: nil, action: nil)
    let shiftSlider = NSSlider(value: 0, minValue: -50, maxValue: 50, target: nil, action: nil)

    let smoothValue = NSTextField(labelWithString: "80")
    let throwValue = NSTextField(labelWithString: "48")
    let rangeValue = NSTextField(labelWithString: "40")
    let shiftValue = NSTextField(labelWithString: "0")

    let rescanBtn = NeonButton(title: "RESCAN")
    private let devicesBox = SectionBox("DEVICES")
    private var deviceRows: [NSView] = []
    /// (device name, enabled) whenever a checkbox is toggled by the user.
    var onDeviceToggled: ((String, Bool) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 900),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "HOVER"
        isReleasedWhenClosed = false
        backgroundColor = .black
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        center()
        buildUI()
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono(11, bold: true)
        label.textColor = Neon.cyan
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 32).isActive = true
        return label
    }

    private func sliderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono(10)
        label.textColor = Neon.dimCyan
        label.widthAnchor.constraint(equalToConstant: 78).isActive = true
        return label
    }

    private func styleSlider(_ slider: NSSlider) {
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
    }

    private func sliderRow(_ name: String, _ slider: NSSlider, _ value: NSTextField) -> NSView {
        styleSlider(slider)
        let row = NSStackView(views: [sliderLabel(name), slider, value])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func buildUI() {
        guard let content = contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        let titleLabel = NSTextField(labelWithString: "HOVER")
        titleLabel.font = mono(20, bold: true)
        titleLabel.textColor = Neon.cyan

        statusLabel.font = mono(10)
        statusLabel.textColor = Neon.faintCyan
        readoutLabel.font = mono(12, bold: true)
        readoutLabel.textColor = Neon.cyan
        monitorLabel.font = mono(10)
        monitorLabel.textColor = Neon.dimCyan

        let header = NSStackView(views: [titleLabel, statusLabel, monitorLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        padView.wantsLayer = true
        padView.layer?.borderColor = Neon.borderCyan.withAlphaComponent(0.5).cgColor
        padView.layer?.borderWidth = 1
        padView.translatesAutoresizingMaskIntoConstraints = false
        padView.widthAnchor.constraint(equalToConstant: 420).isActive = true
        padView.heightAnchor.constraint(equalToConstant: 150).isActive = true

        // MOTION
        let motion = SectionBox("MOTION")
        motion.body.addArrangedSubview(recordBtn)
        motion.body.addArrangedSubview(playBtn)
        motion.heightAnchor.constraint(equalToConstant: 56).isActive = true

        // TOOLS
        let tools = SectionBox("TOOLS")
        tools.body.addArrangedSubview(muteBtn)
        tools.body.addArrangedSubview(mapBtn)
        tools.body.addArrangedSubview(autoBtn)
        tools.heightAnchor.constraint(equalToConstant: 56).isActive = true

        // TUNE
        let tune = SectionBox("TUNE (fine adjust after calibrate)")
        let centerRow = NSStackView(views: [centerBtn, sliderRow("Center Offset", shiftSlider, shiftValue)])
        centerRow.orientation = .horizontal
        centerRow.spacing = 8
        centerBtn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let tuneStack = NSStackView(views: [
            sliderRow("smooth", smoothSlider, smoothValue),
            sliderRow("throw", throwSlider, throwValue),
            sliderRow("Edge Range", rangeSlider, rangeValue),
            centerRow
        ])
        tuneStack.orientation = .vertical
        tuneStack.alignment = .leading
        tuneStack.spacing = 8
        tune.body.orientation = .vertical
        tune.body.distribution = .fill
        tune.body.addArrangedSubview(tuneStack)

        flipXCheck.attributedTitle = checkboxTitle("FLIP X")
        flipXCheck.state = .on

        let bottomRow = NSStackView(views: [flipXCheck, monitorBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 14
        monitorBtn.widthAnchor.constraint(equalToConstant: 100).isActive = true

        // DEVICES — every MIDI source CoreMIDI sees, each with its own on/off
        // checkbox, plus a manual rescan. Rebuilt live via `setDevices`.
        rescanBtn.widthAnchor.constraint(equalToConstant: 90).isActive = true
        devicesBox.body.orientation = .vertical
        devicesBox.body.alignment = .leading
        devicesBox.body.distribution = .fill
        devicesBox.body.spacing = 4
        let devicesHeaderRow = NSStackView(views: [rescanBtn])
        devicesHeaderRow.orientation = .horizontal
        devicesBox.body.addArrangedSubview(devicesHeaderRow)

        let root = NSStackView(views: [
            header, padView, readoutLabel,
            motion, tools, tune, devicesBox, bottomRow
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        for section in [motion, tools, tune, devicesBox] {
            section.translatesAutoresizingMaskIntoConstraints = false
            section.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor)
        ])

        playBtn.isEnabled = false
    }

    /// Rebuilds the DEVICES checkbox list to match `devices` exactly. Cheap enough
    /// to call on every rescan/device-change — this list is never long.
    func setDevices(_ devices: [MidiDeviceInfo]) {
        for row in deviceRows { row.removeFromSuperview() }
        deviceRows.removeAll()

        if devices.isEmpty {
            let empty = NSTextField(labelWithString: "no MIDI devices found")
            empty.font = mono(10)
            empty.textColor = Neon.dimCyan
            devicesBox.body.addArrangedSubview(empty)
            deviceRows.append(empty)
            return
        }

        for device in devices {
            let row = DeviceCheckboxRow(name: device.name, enabled: device.enabled)
            row.onToggle = { [weak self] enabled in
                self?.onDeviceToggled?(device.name, enabled)
            }
            devicesBox.body.addArrangedSubview(row)
            deviceRows.append(row)
        }
    }
}

/// One row in the DEVICES list: a checkbox plus the device's name, reporting
/// toggles via a closure (plain `NSButton` target/action can't carry one).
final class DeviceCheckboxRow: NSView {
    var onToggle: ((Bool) -> Void)?
    private let checkbox: NSButton

    init(name: String, enabled: Bool) {
        checkbox = NSButton(checkboxWithTitle: name, target: nil, action: nil)
        super.init(frame: .zero)
        checkbox.attributedTitle = checkboxTitle(name)
        checkbox.state = enabled ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(handleToggle)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            checkbox.topAnchor.constraint(equalTo: topAnchor),
            checkbox.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleToggle() {
        onToggle?(checkbox.state == .on)
    }
}
