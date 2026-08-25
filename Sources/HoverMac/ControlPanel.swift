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

/// The HOVER control window — mirrors the Windows form's MOTION + TOOLS + TUNE panels.
final class ControlPanel: NSWindow {
    let statusLabel = NSTextField(labelWithString: "SEARCHING GRID")
    let readoutLabel = NSTextField(labelWithString: "X  ---")
    let monitorLabel = NSTextField(labelWithString: "MONITOR")

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

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
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

        flipXCheck.font = mono(10)
        flipXCheck.contentTintColor = Neon.dimCyan
        flipXCheck.state = .on

        let bottomRow = NSStackView(views: [flipXCheck, monitorBtn])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 14
        monitorBtn.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let root = NSStackView(views: [
            header, readoutLabel,
            motion, tools, tune, bottomRow
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        for section in [motion, tools, tune] {
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
}
