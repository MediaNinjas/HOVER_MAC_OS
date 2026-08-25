import AppKit
import CoreGraphics

/// Drives the real OS cursor — equivalent of Windows `Native.SetCursorPos` +
/// `DriveCursor()`/`DetectPhysicalMouseMove()`. Requires Accessibility permission
/// (System Settings → Privacy & Security → Accessibility) to warp the cursor.
enum CursorDriver {
    /// Moves the OS cursor to x01 (0..1) across `screen`'s width; Y stays at screen
    /// vertical center (Y axis muted, matching the Windows build).
    static func drive(x01: Double, on screen: NSScreen) -> CGPoint {
        let f = screen.frame // AppKit: origin bottom-left, Y up.
        let x = f.minX + clamp(x01, 0, 1) * (f.width - 1)
        let y = f.minY + f.height / 2

        // Flip to CoreGraphics' top-left-origin coordinate space for CGWarpMouseCursorPosition.
        let screens = NSScreen.screens
        let globalTop = screens.map { $0.frame.maxY }.max() ?? f.maxY
        let cgY = globalTop - y

        let point = CGPoint(x: x, y: cgY)
        CGWarpMouseCursorPosition(point)
        // Prevents CGEvent generation from momentarily "eating" real trackpad input.
        CGAssociateMouseAndMouseCursorPosition(1)
        return point
    }

    static func currentLocationTopLeft() -> CGPoint {
        let mouse = NSEvent.mouseLocation // bottom-left origin, global.
        let screens = NSScreen.screens
        let globalTop = screens.map { $0.frame.maxY }.max() ?? mouse.y
        return CGPoint(x: mouse.x, y: globalTop - mouse.y)
    }
}
