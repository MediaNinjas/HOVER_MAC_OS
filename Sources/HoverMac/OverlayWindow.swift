import AppKit

/// Full-screen transparent overlay — port of Windows `Edges.cs`. Draws the corner
/// brackets, throw guide, yellow corridor bars, and the ball — a full-screen
/// mirror of what's shown in the app panel's own graph. This window is PURELY
/// VISUAL: it is always click-through (`ignoresMouseEvents = true`, set once
/// here and never touched again anywhere in this file) and never touches the
/// real OS cursor. There is no code path anywhere that can make this window, or
/// any window in this app, capture clicks across a large or arbitrary area —
/// dragging the yellow bars happens only via ordinary in-window dragging inside
/// the app panel's own small graph (`PadView` in `ControlPanel.swift`), exactly
/// like any other Mac app control. That's deliberate, after an earlier version
/// made this window briefly non-click-through while "interactive," which sat
/// above every other window (including HOVER's own control panel) and blocked
/// ALL clicks on the entire screen, locking out the real mouse/trackpad
/// system-wide. That must never be possible again, by construction.
final class OverlayWindow: NSWindow {
    let overlayView = OverlayView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true // permanent — never toggled anywhere in this class.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = overlayView
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }
}

final class OverlayView: NSView {
    // Normalized 0..1 state, same semantics as the Windows Edges control.
    var ballX: Double = 0.5
    var boundL: Double = 0
    var boundR: Double = 1
    var prompt: String?

    override var isFlipped: Bool { true } // top-left origin, matches the Windows GDI+ math.

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

        // Yellow corridor bars (display only — dragging happens in the app panel).
        let barPx: CGFloat = 18
        let sL = CGFloat(boundL) * w
        let sR = CGFloat(boundR) * w
        ctx.setFillColor(yellow.cgColor)
        ctx.fill(CGRect(x: sL - barPx / 2, y: 0, width: barPx, height: h))
        ctx.fill(CGRect(x: sR - barPx / 2, y: 0, width: barPx, height: h))

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
}
