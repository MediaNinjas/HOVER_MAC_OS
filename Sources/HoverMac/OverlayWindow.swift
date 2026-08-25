import AppKit

/// Full-screen transparent overlay — port of Windows `Edges.cs`. Draws the corner
/// brackets, throw guide, yellow corridor bars, and the ball — HOVER's own
/// independent on-screen pointer, drawn here in true screen pixels. This never
/// touches the real OS cursor; the real mouse/trackpad is completely separate,
/// always. Click-through when not interactive.
final class OverlayWindow: NSWindow {
    let overlayView = OverlayView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = overlayView
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
        overlayView.interactive = interactive
    }
}

final class OverlayView: NSView {
    // Normalized 0..1 state, same semantics as the Windows Edges control.
    var ballX: Double = 0.5
    var boundL: Double = 0
    var boundR: Double = 1
    var prompt: String?
    var interactive: Bool = false

    var onBoundsDragStarted: (() -> Void)?
    var onBoundsDragged: ((Double, Double) -> Void)?
    var onBoundsDragEnded: (() -> Void)?

    private let barPx: CGFloat = 18
    private let grabPx: CGFloat = 36
    private var dragging = 0 // 0 none, 1 left, 2 right

    override var isFlipped: Bool { true } // top-left origin, matches the Windows GDI+ math.
    override var acceptsFirstResponder: Bool { true }

    func refresh() { setNeedsDisplay(bounds) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height
        let tron = NSColor(red: 0, green: 229/255, blue: 255/255, alpha: 1)
        let dim = NSColor(red: 0, green: 70/255, blue: 95/255, alpha: 1)
        let yellow = NSColor(red: 1, green: 220/255, blue: 80/255, alpha: 1)

        ctx.setLineWidth(3)
        ctx.setStrokeColor(tron.cgColor)
        drawCorners(ctx, w: w, h: h, arm: 72)
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: w, y: 0))
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: h))
        ctx.move(to: CGPoint(x: w, y: 0)); ctx.addLine(to: CGPoint(x: w, y: h))
        ctx.strokePath()

        ctx.setLineWidth(1)
        ctx.setStrokeColor(dim.cgColor)
        ctx.move(to: CGPoint(x: 0, y: h)); ctx.addLine(to: CGPoint(x: w, y: h))
        ctx.strokePath()

        // Yellow corridor bars.
        let sL = CGFloat(boundL) * w
        let sR = CGFloat(boundR) * w
        ctx.setFillColor(yellow.cgColor)
        ctx.fill(CGRect(x: sL - barPx / 2, y: 0, width: barPx, height: h))
        ctx.fill(CGRect(x: sR - barPx / 2, y: 0, width: barPx, height: h))
        if interactive {
            let handle = NSColor(red: 1, green: 160/255, blue: 0, alpha: 1)
            ctx.setFillColor(handle.cgColor)
            ctx.fill(CGRect(x: sL - 10, y: h / 2 - 40, width: 20, height: 80))
            ctx.fill(CGRect(x: sR - 10, y: h / 2 - 40, width: 20, height: 80))
        }

        // Ball.
        let bx = CGFloat(ballX) * w
        let by = h / 2
        ctx.setFillColor(tron.cgColor)
        ctx.fillEllipse(in: CGRect(x: bx - 7, y: by - 7, width: 14, height: 14))

        if let prompt, !prompt.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Menlo", size: 13) ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: yellow
            ]
            let size = prompt.size(withAttributes: attrs)
            prompt.draw(at: CGPoint(x: (w - size.width) / 2, y: 18), withAttributes: attrs)
        }
    }

    private func drawCorners(_ ctx: CGContext, w: CGFloat, h: CGFloat, arm: CGFloat) {
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: arm, y: 0), CGPoint(x: 0, y: arm)),
            (CGPoint(x: w, y: 0), CGPoint(x: w - arm, y: 0), CGPoint(x: w, y: arm)),
            (CGPoint(x: 0, y: h), CGPoint(x: arm, y: h), CGPoint(x: 0, y: h - arm)),
            (CGPoint(x: w, y: h), CGPoint(x: w - arm, y: h), CGPoint(x: w, y: h - arm))
        ]
        for (origin, a, b) in corners {
            ctx.move(to: origin); ctx.addLine(to: a)
            ctx.move(to: origin); ctx.addLine(to: b)
        }
        ctx.strokePath()
    }

    private func nearBar(_ x01: Double, _ bar01: Double) -> Bool {
        abs(x01 - bar01) * Double(max(1, bounds.width - 1)) <= Double(grabPx)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = Double(p.x) / Double(max(1, bounds.width - 1))
        if nearBar(x, boundL) { dragging = 1; onBoundsDragStarted?() }
        else if nearBar(x, boundR) { dragging = 2; onBoundsDragStarted?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging != 0, interactive else { return }
        let p = convert(event.locationInWindow, from: nil)
        let bx = clamp(Double(p.x) / Double(max(1, bounds.width - 1)), 0, 1)
        // Mirror around true center (0.5): drag either bar, both move together so the
        // corridor always auto-scales symmetrically — matches the Windows fix.
        if dragging == 1 {
            boundL = min(bx, 0.49)
            boundR = 1 - boundL
        } else {
            boundR = max(bx, 0.51)
            boundL = 1 - boundR
        }
        onBoundsDragged?(boundL, boundR)
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != 0 else { return }
        dragging = 0
        onBoundsDragEnded?()
    }
}
