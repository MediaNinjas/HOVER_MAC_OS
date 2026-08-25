# HOVER Mac

Swift/AppKit port of `HOVER-V2-Windows` (in the `MediaNinjas/Hover` repo), X-axis
only — Y stays muted, same as the Windows build's `EnableY = false`.

This is a from-scratch build/verify pass done directly on a Mac (not a blind port
written without a Mac to test on). Behavior is intended to match the Windows app
exactly, bugs included — this is not meant to diverge into a second, different app.

## Open it

Double-click `Package.swift` (or `File → Open` it in Xcode) — Xcode treats an SPM
package with an executable target as a runnable project. Press ▶ to build and run.
No `.xcodeproj` needed.

Alternatively from Terminal:

```bash
cd HOVER_MAC_OS
swift run
```

## Permissions (macOS will prompt, or grant manually)

- **Accessibility** — required to move the cursor (`CGWarpMouseCursorPosition`).
  System Settings → Privacy & Security → Accessibility → add the built app /
  `swift-frontend` (or `Terminal`/`Xcode` if running via `swift run`).
- **Input Monitoring** may also prompt — grant it if the MIDI/keyboard handling asks.
- No microphone/camera permissions needed — MIDI (CoreMIDI) doesn't require a
  privacy prompt.

## Source of truth

Only 4 files in the Windows build are actually live (wired up from `Program.cs`):
`HoverForm.cs`, `Native.cs`, `EdgeSolve.cs`, `Program.cs`. Everything else in that
repo (`AxisMap.cs`, `Mark.cs`, `WireHand.cs`, `Pointer.cs`, `TargetLatch.cs`,
`Homography.cs`, `MidiInput.cs`) is dead legacy code, never instantiated — not
ported here on purpose.

## What's ported (feature-parity with Windows)

- **CoreMIDI** Hot Hand detection (`MidiSensor.swift`) — same name filter
  ("Hot Hand" / "Source Audio"), same CC mapping (CC 4/7/9 = X, Y ignored).
- **RECORD HAND MOVEMENT → SAVE → drag-to-edge auto-save** flow — SAVE ends and
  saves the recording, yellow bars go live, dragging either bar mirrors the other
  around true center (0.5), releasing a drag auto-saves.
- **PLAY** — replays the recorded clip through the live yellow bars.
- **AUTO** — multi-pass edge sweep (`EdgeSolve.swift`), enter/space to force-lock,
  escape to cancel.
- **MAP** — legacy 2-point right/left keyboard calibrate.
- **Settings persistence** — same JSON shape as Windows
  (`~/Library/Application Support/Media Ninjas/HOVER/pointer.json`), same field
  names, so a settings file round-trips between the two builds.
- **Center recentering** — after AUTO locks (or on launch with an existing map),
  the axis span is symmetrized around the CENTER pose, matching Windows'
  `RecenterPan`/`SymmetrizeAxisAroundCenter`.
- **Mouse-yield grace window** — a real trackpad/mouse move mutes HOVER and holds
  off re-driving the cursor for a few seconds even after unmuting, matching
  Windows' `_mouseUntil` behavior.
- **TOOLS**: Smooth, Throw, Edge Range, Center(shift) sliders; Flip X; MUTE; SET
  (center); monitor switch.
- **Overlay**: corner brackets, edge lines, yellow corridor bars with drag
  handles, the ball — in true screen pixels, same math as the cursor driver.

## Deliberately NOT ported (Y is dead code on Windows too — `EnableY = false`)

- Y-axis mapping, `AxisTop`/`AxisBottom`/`ShiftY`/`FlipY`/`Swap`/Ratio-split-gain
  — all only mattered for Y, which is muted in both builds.
- The Windows build's debug minimap (`Pad`) and raw MIDI history arrays —
  display-only, not load-bearing.
- The pre-map "throw triangle" overlay visualization (`EdgeBand`/`ProjectToBand`
  in Windows) — cosmetic only; confirmed it never feeds into actual cursor
  position (`MapCalibrateThrow` doesn't read pan/shift), so cursor *behavior* is
  unaffected by skipping it. The overlay currently only draws corners, edge
  lines, yellow bars, and the ball.

## Known things to verify on a real device

- Cursor drive math converts AppKit's bottom-left-origin screen space to
  CoreGraphics' top-left-origin space using the tallest screen's `maxY` as the
  global top — fine for typical single/dual-monitor setups, verify on your
  actual monitor arrangement.
- `MidiSensor`'s raw MIDI packet walk assumes standard 3-byte CC messages —
  hardening may be needed if the Hot Hand sends running-status or SysEx around it.
- No `midi-debug.log`-equivalent trace file yet (Windows writes one) — add one in
  `MidiSensor` if you need to debug a device that isn't being detected.

## Folder

Local working copy: `~/Developer/HOVER_MAC_OS`. Separate repo from
`HOVER-V2-Windows` on purpose — different toolchains (SwiftPM/Xcode vs .NET), no
shared build; only the settings JSON *shape* is common between them.
