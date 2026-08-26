import AppKit

/// Full-screen transparent overlay — port of Windows `Edges.cs`. Draws the corner
/// brackets, throw guide, yellow corridor bars, and the ball — HOVER's own
/// independent on-screen pointer. This window is PURELY VISUAL: it is always
/// click-through (`ignoresMouseEvents = true`, never changed, ever) and never
/// touches the real OS cursor. It cannot capture input, structurally — there is
/// no code path that flips that flag on this window.
///
/// Dragging the yellow bars is handled by two separate small `DragHandleWindow`s
/// instead of making this window interactive. Each is a fixed, small size (just
/// big enough to grab) positioned exactly at one bar — never full-screen, never
/// arbitrary size. This is deliberate: an earlier version made this whole window
/// non-click-through while "interactive," which sat above every other window
/// (including HOVER's own control panel) and blocked ALL clicks on the entire
/// screen, locking out the real mouse/trackpad system-wide. That must never be
/// possible again, by construction, not just by careful state management.
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
    var interactive: Bool = false // drawing only (shows/hides the handle graphics)

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

        // Yellow corridor bars.
        let barPx: CGFloat = 18
        let sL = CGFloat(boundL) * w
        let sR = CGFloat(boundR) * w
        ctx.setFillColor(yellow.cgColor)
        ctx.fill(CGRect(x: sL - barPx / 2, y: 0, width: barPx, height: h))
        ctx.fill(CGRect(x: sR - barPx / 2, y: 0, width: barPx, height: h))
        if interactive {
            let handle = NSColor(red: 1, green: 160/255, blue: 0, alpha: 1)
            ctx.setFillColor(handle.cgColor)
            ctx.fill(DragHandleWindow.frame(forBarX01: boundL, in: bounds).insetBy(dx: -10, dy: 0))
            ctx.fill(DragHandleWindow.frame(forBarX01: boundR, in: bounds).insetBy(dx: -10, dy: 0))
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
}

/// A small, fixed-size (44×140pt) window positioned exactly over one yellow bar's
/// grab handle. This — not the full-screen overlay — is what's ever interactive.
/// Its size is a compile-time constant; nothing in this class can make it larger,
/// let alone full-screen. Two of these exist total (left bar, right bar).
final class DragHandleWindow: NSWindow {
    static let size = CGSize(width: 44, height: 140)

    var onDragStarted: (() -> Void)?
    var onDragged: ((Double) -> Void)? // reports this handle's new x01
    var onDragEnded: (() -> Void)?

    private var dragging = false
    private var homeScreen: NSScreen

    init(screen: NSScreen) {
        self.homeScreen = screen
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true // only turned on while actually shown as draggable.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        contentView = view
        installDragGesture(on: view)
    }

    /// `x01` = this bar's current position (0..1) across the screen's width.
    /// `visible` controls whether this handle can be clicked at all.
    func update(x01: Double, visible: Bool) {
        ignoresMouseEvents = !visible
        if !visible {
            orderOut(nil)
            return
        }
        let frame = Self.frame(forBarX01: x01, in: homeScreen.frame, windowSize: Self.size)
        setFrame(frame, display: false)
        orderFrontRegardless()
    }

    static func frame(forBarX01 x01: Double, in bounds: NSRect) -> NSRect {
        let barX = CGFloat(x01) * bounds.width
        return NSRect(x: barX - 20, y: bounds.height / 2 - 40, width: 20, height: 80)
    }

    private static func frame(forBarX01 x01: Double, in screenFrame: NSRect, windowSize: CGSize) -> NSRect {
        let barX = screenFrame.minX + CGFloat(x01) * screenFrame.width
        let centerY = screenFrame.minY + screenFrame.height / 2
        return NSRect(
            x: barX - windowSize.width / 2,
            y: centerY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height)
    }

    private func installDragGesture(on view: NSView) {
        let recognizer = DragGestureView(frame: view.bounds)
        recognizer.autoresizingMask = [.width, .height]
        recognizer.onDown = { [weak self] in self?.dragging = true; self?.onDragStarted?() }
        recognizer.onDragged = { [weak self] locationInScreen in
            guard let self, dragging else { return }
            let x01 = (locationInScreen.x - homeScreen.frame.minX) / homeScreen.frame.width
            onDragged?(Double(clampCG(x01, 0, 1)))
        }
        recognizer.onUp = { [weak self] in
            guard let self, dragging else { return }
            dragging = false
            onDragEnded?()
        }
        view.addSubview(recognizer)
    }
}

/// Plain NSView that reports mouse down/drag/up as screen-space points. Kept tiny
/// and dumb on purpose — all the interesting logic lives in `DragHandleWindow`.
private final class DragGestureView: NSView {
    var onDown: (() -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseDragged(with event: NSEvent) { onDragged?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { onUp?() }
}

private func clampCG(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
