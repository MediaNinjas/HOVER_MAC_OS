# HOVER Mac — Handoff (2026-08-27, updated)

## Canonical location

This folder is the Mac build: `~/Developer/HOVER_MAC_OS` (separate git repo,
`MediaNinjas/HOVER_MAC_OS` on GitHub — intentionally separate from the Windows
repo, different toolchain, no shared code).

Build/run: `swift build`, then either `swift run` or copy the binary into
`HOVER.app/Contents/MacOS/HoverMac` and `open HOVER.app` (the `.app` bundle is
what lets macOS treat it as a real app for permission grants — it's
gitignored, rebuild it locally with the commands above, it's not checked in).

## Confirmed working, on real hardware, as of this commit

RECORD → SAVE → done. No mouse dragging required or expected:

1. **RECORD HAND MOVEMENT** — sweep your hand through its natural comfortable
   range. Captures raw MIDI min/max (`motionMin`/`motionMax`).
2. **SAVE** (same button) — auto-scales that recorded range to the true
   screen edges (`screenBoundLeft = 0`, `screenBoundRight = 1`), immediately,
   no dragging. `autoSaveCorridor()` in `AppController.swift`.
3. Live tracking uses `map()` → `Geometry.mappedX()`, which has two adjustable
   knobs, both in TUNE, both current defaults confirmed working on real
   hardware:
   - **X Hand Motion Range** (-127...127, default **8**): shrinks how much of
     your recorded range is actually needed to reach the true edges — a real
     human can't repeat an exact physical extreme every time, so without this
     the ball falls perpetually just short.
   - **Mouse Speed** (-100...100, default **-20**): a pure instant
     sensitivity/gain multiplier around the corridor's own center — NOT
     smoothing, NOT time-based lag, applied fresh every tick. Positive = same
     hand movement covers more screen distance; negative = less. Still
     hard-clamped at the true edges regardless of gain — can never trap the
     ball short.
4. **Throw defaults to 48** — but READ THIS: Throw is genuinely irrelevant
   *once a calibration exists* (`hasXMap == true`, status shows **MAPPED**),
   used only in the pre-calibration path (`mapCalibrateThrow`, status shows
   **READY**). It is NOT dead code in general — at the slider floor (8) it
   made the pre-calibration ball fly wildly on tiny hand movements, which was
   mistaken for a Mouse Speed bug before the real cause (no active
   calibration at the time) was found. **Always check the status label
   (READY vs MAPPED) before assuming which code path is even running** — this
   cost real time twice in this session.

`clamp()` is the only thing that stops the ball at an edge — a hard stop,
mathematically "stay exactly there," not resistance or easing. There is no
time-based smoothing/lerp/gravity anywhere in the ball's motion
(`AppController.swift`'s `map()`/`mapCalibrateThrow()`) — Mouse Speed is
instant gain, explicitly not a delay effect, per direct instruction.

## Hardware notes (Hot Hand MIDI receiver)

- The receiver needs an explicit "unmute" MIDI handshake sent to it before it
  streams — `MidiSensor.swift`'s `unmuteHotHands()` (CC112=127, then
  CC102-111=127, on all 16 channels, to the Hot Hand's MIDI **destination**).
  This was written on the Windows side (`MidiInput.cs`) but never wired into
  the live Windows app either.
- The receiver also **goes quiet again** after a few seconds of no traffic —
  a `keepAlive()` re-sends the same handshake automatically if no sample has
  landed in 3+ seconds while connected. Still can have real, hardware-level
  wireless dropouts between the ring and the receiver (independent of
  software) — if the X readout freezes and the receiver's own LED isn't
  solid, that's a physical RF issue, not a code bug. Check `system_profiler
  SPUSBDataType` for the receiver and CoreMIDI source list if debugging this.
- **DEVICES panel** (new): lists every MIDI source CoreMIDI sees (not just
  auto-detected Hot Hand ones), each with an on/off checkbox, plus RESCAN.
  `MidiSensor.devices` / `setDevice(_:enabled:)`.

## Cursor safety — read this before touching anything cursor-related

**HOVER never touches the real OS cursor. This is deliberate and load-bearing,
not an oversight to "fix."** An earlier version drove the real cursor via
`CGWarpMouseCursorPosition`, which fought/overrode real trackpad input and
locked the user out of their own machine twice, requiring a forced shutdown
both times. `CursorDriver.swift` was deleted entirely (not left unused) so it
can't be silently re-wired. HOVER only ever moves its own on-screen ball
(drawn in `OverlayWindow.swift`'s full-screen overlay, and in the panel's
`PadView`). The real mouse/trackpad is a fully independent pointer, always,
regardless of app state — that's required so a user can interact with
anything else while HOVER is tracking their hand.

There's also a hard kill switch as an unconditional backstop, independent of
any of the app's own logic: **F12 twice within 600ms = instant `exit(0)`**
(`AppController.swift`'s `checkForceKill`), both a local and a global key
monitor so it works even if HOVER's window isn't focused.

If you ever add anything that could move the real cursor or capture input
across a large/arbitrary area again, stop and ask first — this has burned an
entire session before.

## What's deliberately NOT ported (dead code on Windows too)

Only 4 of 12 `.cs` files in `HOVER-V2-Windows` are live (`Program.cs`,
`HoverForm.cs`, `Native.cs`, `EdgeSolve.cs`) — `AxisMap.cs`, `Mark.cs`,
`WireHand.cs`, `Pointer.cs`, `TargetLatch.cs`, `Homography.cs`,
`MidiInput.cs` are never instantiated from `Program.cs`. None of that was
ported here. Y-axis is muted throughout, matching Windows' `EnableY = false`.

## Known rough edges / things to check next

- The bar-dragging mechanism in `PadView` (mouse-drag the yellow bars
  directly in the panel's small graph) still exists and works, but is no
  longer required for normal operation — RECORD/SAVE handles calibration
  automatically now. Treat dragging as optional fine-tuning only.
- `OverlayWindow`'s full-screen visual can overlap the control panel
  visually (cosmetic only, not a click-blocking issue — confirmed
  structurally: `ignoresMouseEvents` is set once in `OverlayWindow.init` and
  never touched again anywhere in that file) whenever `!hasXMap` — i.e.
  before any calibration exists.
- No `midi-debug.log`-equivalent trace file yet (Windows writes one). Add
  one in `MidiSensor` if debugging a device that isn't detected.
- Synthetic mouse-drag testing via this session's screenshot/computer-use
  tooling does **not** reliably trigger real AppKit drag tracking — confirmed
  with two different drag implementations, same non-result both times. Don't
  trust that tool for verifying drag interactions; real hardware testing is
  the only reliable signal for this app.

## Folder

Local working copy: `~/Developer/HOVER_MAC_OS`. Push access to
`MediaNinjas/HOVER_MAC_OS` is via a GitHub token stored in this Mac's
Keychain (git credential helper `osxkeychain`) — already configured, pushes
should just work without re-prompting.
