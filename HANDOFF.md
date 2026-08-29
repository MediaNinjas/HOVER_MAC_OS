# HOVER Mac — Handoff (2026-08-28, rewritten — major simplification)

## Canonical location

`~/Developer/HOVER_MAC_OS` (separate git repo, `MediaNinjas/HOVER_MAC_OS` on
GitHub — intentionally separate from the Windows repo, different toolchain,
no shared code).

Build/run: `swift build`, then either `swift run` or copy the binary into
`HOVER.app/Contents/MacOS/HoverMac` and `open HOVER.app` (the `.app` bundle
lets macOS treat it as a real app for permission grants — it's gitignored,
rebuild it locally, it's not checked in).

## Current design (as of this commit) — read this before assuming anything from older history

The app went through many iterations (RECORD/SAVE with mouse-dragged
calibration bars, several TUNE sliders, a "corridor" concept) that turned out
unreliable or confusing across a long session of real-hardware testing. All
of that was **removed entirely**, not disabled. If you're reading old commit
messages and see references to RECORD, SAVE, MAP, drag-to-edge, Smooth,
Throw, Edge Range, or X Hand Motion Range — none of that exists anymore.
Don't resurrect it without direct instruction.

**What exists now, full stop:**
- **AUTO** — sweep your hand left/right until it locks (multi-pass edge
  detection, `EdgeSolve.swift`, unchanged/working). This is the only
  calibration method. Locks `axisLeft`/`axisRight` (raw MIDI extremes) AND
  always forces `screenBoundLeft = 0`, `screenBoundRight = 1` (true screen
  edges) — every single time, no exceptions, no leftover stale values.
- **MUTE** — freezes HOVER's own ball in place. Does not touch the real
  cursor either way (that's never touched, see below).
- **DEVICES** — lists every MIDI source CoreMIDI sees, each with an on/off
  checkbox, plus RESCAN to manually re-enumerate.
- **Mouse Speed** slider (-100...100, default **-20**) — pure instant
  sensitivity/gain multiplier around the corridor's center. NOT smoothing,
  NOT time-based lag — recomputed fresh every tick from the current hand
  position and this one number, nothing else. Still always hard-clamped at
  the true edges regardless of gain.
- **Center Offset** slider (-50...50) — pan, as percent of screen width.
- **FLIP X**, **MONITOR** (cycle displays).

That's the entire control surface. `map()` in `AppController.swift` is the
only function that ever sets the ball's position — direct linear map
(`Geometry.mappedX`, the only function left in `Geometry.swift`), Mouse Speed
gain and Center Offset pan applied on top, hard-clamped. Before AUTO has ever
locked a range, it uses the full fixed 0-127 MIDI range as a default so the
ball still does something reasonable.

**Nothing "pulls" on the ball after AUTO locks.** No periodic re-adjustment,
no symmetrize-around-center, no drag mechanism to fight. This was explicit,
repeated direction after multiple rounds of exactly that kind of "invisible
readjustment" causing real, hard-to-diagnose bugs (see below).

## Real bugs found and fixed in this session (useful if similar symptoms return)

- **"Space between MIDI 0 and the side" on both edges after AUTO** — the
  actual cause: `finishAuto()` never set `screenBoundLeft`/`screenBoundRight`
  at all. It locked the MIDI axis but left the screen boundary at whatever
  stale value was already there. Fixed by always forcing 0/1 there,
  unconditionally, every lock.
- **"Flying from one side to the other" / Mouse Speed "not connected"** — the
  status label said **READY**, not **MAPPED**, meaning there was no active
  calibration and a completely different (now-deleted) code path was
  running. **Always check the status label before assuming which mapping
  logic is even active** if something's behaving strangely — this caused
  real confusion more than once.
- Earlier in the session (now moot, since that whole flow is deleted): a
  10px coordinate margin, a `minBarGap` resistance clamp, and a
  settings/live-state desync all caused a manually-dragged calibration bar to
  never quite reach the true edge. Not relevant to the current AUTO-only
  design, but if anyone ever re-adds a draggable UI element, re-read this
  git history first (`git log --oneline` around late Aug 2026) — the same
  category of bug (a value shown in the UI diverging from the value actually
  used for computation) recurred multiple times and is worth being paranoid
  about.

## Hardware notes (Hot Hand MIDI receiver)

- Needs an explicit "unmute" MIDI handshake before it streams —
  `MidiSensor.swift`'s `unmuteHotHands()` (CC112=127, then CC102-111=127, on
  all 16 channels, to the Hot Hand's MIDI **destination**). Written on the
  Windows side (`MidiInput.cs`) but never wired into the live Windows app.
- Goes quiet again after a few seconds of no traffic — `keepAlive()`
  re-sends the handshake if no sample has landed in 3+ seconds. Can still
  have genuine hardware-level wireless dropouts between the ring and
  receiver, independent of software — if the X readout freezes and the
  receiver's own LED isn't solid, that's physical, not a code bug.

## Cursor safety — read this before touching anything cursor-related

**HOVER never touches the real OS cursor. Deliberate and load-bearing, not an
oversight.** An earlier version drove the real cursor via
`CGWarpMouseCursorPosition`, which fought real trackpad input and locked the
user out of their own machine twice, requiring a forced shutdown both times.
`CursorDriver.swift` was deleted entirely so it can't be silently re-wired.
HOVER only ever moves its own on-screen ball (`OverlayWindow.swift`'s
full-screen overlay, and the panel's `PadView`, display-only now). The real
mouse/trackpad is a fully independent pointer, always, regardless of app
state.

Hard kill switch, independent of any app logic: **F12 twice within 600ms =
instant `exit(0)`** (`AppController.swift`'s `checkForceKill`), both a local
and global key monitor.

**If you ever add anything that could move the real cursor, or bring back a
draggable UI element, or add any form of periodic/background readjustment to
the ball's position — stop and ask first.** This has burned significant time
across this session, more than once.

## What's deliberately NOT ported (dead code on Windows too)

Only 4 of 12 `.cs` files in `HOVER-V2-Windows` are live (`Program.cs`,
`HoverForm.cs`, `Native.cs`, `EdgeSolve.cs`) — the rest are never
instantiated. None of that was ported here. Y-axis is muted throughout,
matching Windows' `EnableY = false`.

## Folder / access

Local working copy: `~/Developer/HOVER_MAC_OS`. Push access to
`MediaNinjas/HOVER_MAC_OS` is via a GitHub token in this Mac's Keychain (git
credential helper `osxkeychain`) — already configured.
