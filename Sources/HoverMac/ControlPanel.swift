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

/// Embedded live-position monitor — port of Windows' `Pad` control. Display
/// only: the yellow bars shown here are whatever AUTO locked (or 0/1 before
/// that) — there is no dragging here anymore. AUTO is the only thing that
/// ever sets them, and nothing else ever touches them afterward.
final class PadView: NSView {
    var x: Double = 0.5
    var y: Double = 0.5
    var yellowL: Double = 0
    var yellowR: Double = 1
    var centerX: Double = 0.5

    override var isFlipped: Bool { false } // bottom-left origin, matches Windows GDI+ Y-up math here.

    func refresh() { setNeedsDisplay(bounds) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(red: 6/255, green: 16/255, blue: 20/255, alpha: 1).setFill()
        ctx.fill(bounds)

        let w = bounds.width, h = bounds.height
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

/// The HOVER control window. Deliberately minimal, per direct instruction:
/// AUTO + MUTE + DEVICES + two sliders (Mouse Speed, Center Offset). Nothing
/// else — RECORD/PLAY/MAP and the TUNE sliders that either did nothing or
/// caused unwanted resistance were removed rather than kept as dead weight.
final class ControlPanel: NSWindow {
    let statusLabel = NSTextField(labelWithString: "SEARCHING GRID")
    let readoutLabel = NSTextField(labelWithString: "X  ---")
    let monitorLabel = NSTextField(labelWithString: "MONITOR")
    let padView = PadView()

    let autoBtn = NeonButton(title: "AUTO")
    let muteBtn = NeonButton(title: "MUTE")
    let monitorBtn = NeonButton(title: "MONITOR")
    let quitBtn = NeonButton(title: "QUIT")
    let flipXCheck = NSButton(checkboxWithTitle: "FLIP X", target: nil, action: nil)
    let flipYCheck = NSButton(checkboxWithTitle: "FLIP Y", target: nil, action: nil)
    /// Independent on/off per axis — lets you isolate Y (or X) to test/tune
    /// it alone without the other axis moving the ball at all.
    let enableXCheck = NSButton(checkboxWithTitle: "ENABLE X", target: nil, action: nil)
    let enableYCheck = NSButton(checkboxWithTitle: "ENABLE Y", target: nil, action: nil)
    /// Tracks a third raw channel for the monitor below — doesn't drive
    /// anything on screen by itself.
    let enableZCheck = NSButton(checkboxWithTitle: "ENABLE Z", target: nil, action: nil)

    /// Which raw MIDI CC drives each screen axis — populated live from
    /// whatever CCs the hardware is actually sending, via `setSourceOptions`.
    /// "Default" keeps the normal built-in grouping.
    let xSourceMenu = NSPopUpButton()
    let ySourceMenu = NSPopUpButton()
    /// Walks you through it hands-free: move left-right, then up-down, and
    /// picks the CC with the most movement in each window automatically.
    let detectBtn = NeonButton(title: "FIND AXES")
    /// Quick fix if FIND AXES (or a manual pick) comes out backwards.
    let swapBtn = NeonButton(title: "SWAP X/Y")
    /// Records just one axis: press it, do the gesture you want for that
    /// axis, and whichever raw CC moved most during that window is assigned.
    /// Leaves the other axis's source completely alone.
    let recordXBtn = NeonButton(title: "RECORD")
    let recordYBtn = NeonButton(title: "RECORD")
    /// Every raw CC number and its current value, refreshed live — lets a
    /// gesture be matched to its CC number by eye, no code changes needed.
    let rawCCLabel = NSTextField(labelWithString: "")

    let shiftSlider = NSSlider(value: 0, minValue: -50, maxValue: 50, target: nil, action: nil)
    /// Per-tick rate cap only — never a range multiplier. See Settings.mouseSpeed.
    let mouseSpeedSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    /// How much of AUTO's measured sweep is needed to reach the edges. See Settings.rangeScale.
    let rangeSlider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    /// Where the (possibly narrowed) window sits inside the measured sweep. See Settings.rangeCenter.
    let rangeCenterSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)

    let shiftValue = NSTextField(labelWithString: "0")
    let mouseSpeedValue = NSTextField(labelWithString: "0")
    let rangeValue = NSTextField(labelWithString: "100")
    let rangeCenterValue = NSTextField(labelWithString: "0")

    let rescanBtn = NeonButton(title: "RESCAN")
    private let devicesBox = SectionBox("DEVICES")
    private var deviceRows: [NSView] = []
    /// (device name, enabled) whenever a checkbox is toggled by the user.
    var onDeviceToggled: ((String, Bool) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        minSize = NSSize(width: 460, height: 400)
        title = "HOVER"
        isReleasedWhenClosed = false
        backgroundColor = .black
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        center()
        buildUI()
    }

    private func sliderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono(10)
        label.textColor = Neon.dimCyan
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return label
    }

    private func sliderRow(_ name: String, _ slider: NSSlider, _ value: NSTextField) -> NSView {
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
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

        // TOOLS
        let tools = SectionBox("TOOLS")
        tools.body.addArrangedSubview(muteBtn)
        tools.body.addArrangedSubview(autoBtn)
        tools.body.addArrangedSubview(quitBtn)
        tools.heightAnchor.constraint(equalToConstant: 56).isActive = true

        // TUNE
        let tune = SectionBox("TUNE")
        let tuneStack = NSStackView(views: [
            sliderRow("Mouse Speed", mouseSpeedSlider, mouseSpeedValue),
            sliderRow("Center Offset", shiftSlider, shiftValue),
            sliderRow("Range", rangeSlider, rangeValue),
            sliderRow("Range Center", rangeCenterSlider, rangeCenterValue)
        ])
        tuneStack.orientation = .vertical
        tuneStack.alignment = .leading
        tuneStack.spacing = 8
        tune.body.orientation = .vertical
        tune.body.distribution = .fill
        tune.body.addArrangedSubview(tuneStack)

        flipXCheck.attributedTitle = checkboxTitle("FLIP X")
        flipXCheck.state = .on
        flipYCheck.attributedTitle = checkboxTitle("FLIP Y")
        enableXCheck.attributedTitle = checkboxTitle("ENABLE X")
        enableXCheck.state = .on
        enableYCheck.attributedTitle = checkboxTitle("ENABLE Y")
        enableYCheck.state = .on
        enableZCheck.attributedTitle = checkboxTitle("ENABLE Z")

        let axesRow = NSStackView(views: [enableXCheck, enableYCheck, enableZCheck])
        axesRow.orientation = .horizontal
        axesRow.spacing = 14

        let bottomRow = NSStackView(views: [flipXCheck, flipYCheck, monitorBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 14
        monitorBtn.widthAnchor.constraint(equalToConstant: 100).isActive = true

        // SOURCES — which raw MIDI CC actually drives each screen axis, plus
        // a live readout of every CC number the hardware sends, so a natural
        // gesture's CC can be spotted and assigned without guessing.
        let sources = SectionBox("SOURCES")
        let detectRow = NSStackView(views: [detectBtn, swapBtn])
        detectRow.orientation = .horizontal
        detectRow.spacing = 10
        xSourceMenu.font = mono(10)
        ySourceMenu.font = mono(10)
        xSourceMenu.widthAnchor.constraint(equalToConstant: 130).isActive = true
        ySourceMenu.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let xSourceLabel = NSTextField(labelWithString: "X Source")
        xSourceLabel.font = mono(10); xSourceLabel.textColor = Neon.dimCyan
        xSourceLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let ySourceLabel = NSTextField(labelWithString: "Y Source")
        ySourceLabel.font = mono(10); ySourceLabel.textColor = Neon.dimCyan
        ySourceLabel.widthAnchor.constraint(equalToConstant: 60).isActive = true
        rawCCLabel.font = mono(9)
        rawCCLabel.textColor = Neon.dimCyan
        rawCCLabel.lineBreakMode = .byWordWrapping
        rawCCLabel.maximumNumberOfLines = 3
        rawCCLabel.preferredMaxLayoutWidth = 380
        let sourcesStack = NSStackView(views: [
            detectRow,
            NSStackView(views: [xSourceLabel, xSourceMenu, recordXBtn]),
            NSStackView(views: [ySourceLabel, ySourceMenu, recordYBtn]),
            rawCCLabel
        ])
        sourcesStack.orientation = .vertical
        sourcesStack.alignment = .leading
        sourcesStack.spacing = 6
        sources.body.orientation = .vertical
        sources.body.distribution = .fill
        sources.body.addArrangedSubview(sourcesStack)

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
            tools, tune, axesRow, sources, devicesBox, bottomRow
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        for section in [tools, tune, sources, devicesBox] {
            section.translatesAutoresizingMaskIntoConstraints = false
            section.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }

        // Scrollable so a fixed/resized window height can never silently clip
        // content off the bottom with no way to reach it — this exact thing
        // happened once already (RECORD buttons rendered below the visible
        // window, invisible, on a non-resizable fixed-height window).
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = root
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            root.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        ])
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

    /// Rebuilds both source popups to list "Default" plus every CC number
    /// currently being seen — called whenever a new CC shows up. `tag` on
    /// each item carries the CC number, -1 for "Default", so the caller can
    /// read the selection without parsing title strings.
    func setSourceOptions(_ ccs: [Int], selectedX: Int?, selectedY: Int?) {
        for (menu, selected) in [(xSourceMenu, selectedX), (ySourceMenu, selectedY)] {
            menu.removeAllItems()
            menu.addItem(withTitle: "Default")
            menu.lastItem?.tag = -1
            for cc in ccs {
                menu.addItem(withTitle: "CC \(cc)")
                menu.lastItem?.tag = cc
            }
            let wantTag = selected ?? -1
            if let item = menu.itemArray.first(where: { $0.tag == wantTag }) {
                menu.select(item)
            }
        }
    }

    /// Live "CC n:value" readout for every raw CC the hardware is sending.
    func setRawCCText(_ text: String) {
        rawCCLabel.stringValue = text
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
