# Copilot instructions — trackpad_control

macOS menu-bar app (Swift/SwiftUI, macOS 26, Xcode 26) that turns multi-finger trackpad
gestures into actions. Raw touches come from the private MultitouchSupport framework; a
CGEventTap swallows the system's own interpretation while a gesture is ours.

## How the owner wants to work

- **Ask before building.** Never build/deploy without an explicit OK. Prefer one build that
  bundles agreed changes over several small builds — builds and test rounds cost the owner time
  and credits.
- **No assumptions — ask questions.** If a test result, a shape, or an intent is unclear, ask a
  short yes/no question (per attempt when it's a test) instead of guessing.
- **Measure before theorizing.** Use the log, the live-stroke corpus, or a probe (see tools
  below) before proposing a cause. Say "candidate hypothesis" until the owner confirms.
- **Plain language, short.** Conclusions in simple terms, the question at the end. No long
  tables unless asked. No emojis.
- **Recordings are ground truth.** Gesture samples reflect how the owner really moves; do not
  ask to re-record or reshape gestures to suit the recognizer. Adapt the recognizer.
- **Commit locally at milestones only; never push.** Pushing is the owner's decision.

## Build / deploy / verify

```bash
xcodebuild -configuration Release -derivedDataPath build-release -scheme trackpad_control build
pkill -x trackpad_control; ditto build-release/Build/Products/Release/trackpad_control.app "/Applications/Trackpad Control.app"; open "/Applications/Trackpad Control.app"
shasum -a 256 build-release/Build/Products/Release/trackpad_control.app/Contents/MacOS/trackpad_control "/Applications/Trackpad Control.app/Contents/MacOS/trackpad_control"   # must match
pgrep -x trackpad_control   # new PID
```
"BUILD SUCCEEDED" is not proof; hash match + new PID + a runtime check in the log is.

## Diagnostics (all in `~/Library/Application Support/TrackpadControl/`)

- `tc-debug.log` — written only when Settings → Advanced → diagnostics is on. Two timestamp
  formats interleave (`[uptime]` and `HH:MM:SS.mmm`); read adjacent raw lines, not just greps.
  Key markers: `TCM-CONFIG`, `ANCHOR-ACTIVATION`, `LANDING`, `MT-CONTACT` (per-finger truth),
  `SWIPE-GEOM`, `DISCRETE-FIRE|NOMATCH|AMBIGUOUS`, `ZT-check`/`ZT-EXEC`, `[OVERLAY]`.
- `live-strokes.jsonl` — every discrete/tap stroke with raw finger paths and the verdict.
  **Any recognizer change must be evaluated against this first:**
  `python3 scripts/matcher_experiment.py --live` (agree / would-fix / would-break).
  Leave-one-out on recordings (`scripts/recognizer_eval.py`) is necessary but not sufficient —
  it read 98% while live use failed ~10%, and synthetic perturbations gave a wrong answer.
- `scripts/scroll_listener.swift` — standalone listen-only tap that prints what actually
  reaches apps (scroll phase, momentum, delta). Use it for any "bleeds through" question.
  Write to a file and read filtered lines; kill it when done.
- `gestures.json` — the library. Thumbnails in the app are now uniform-scale; the recorder
  canvas is to scale.

## Facts already established (don't re-derive)

- Scroll bleed behind 3-finger gestures was macOS **momentum after lift**; fixed by
  `swallowedScrollSequence` in the event tap (decide per sequence, never per event; the last
  `changed` can arrive after the MT lift frame). Race/stagger/5 s-valve theories were wrong.
- Anchor drift is measured from the finger's position at candidate start (100 ms), not first
  contact — landing shifts the centroid 0.013–0.02.
- Tap-to-click during an anchor hold is swallowed (`leftMouseDown/Up` in the tap mask, own pid passes).
- Kopy = up-then-right L, Mission C = straight up; BRQ = down-then-right, Close tab = straight
  down. Live misses happen when the second leg is 12–18 % of the path: the matcher weights by
  leg length. Corner-first (leg-normalized) matching was NOT shipped — it broke a real BRQ.
- Rejected recognizer ideas (with data): centroid/median finger, $P cloud, freeze-at-liftoff,
  turn penalty > 0.15, trackpad aspect correction, post-resample smoothing.
- Overlay disappearing on desktops 2+ is still open; needs the time it broke to read the log.

## Code conventions

- `TouchCaptureManager` is not `@Observable`; the event-tap callback must stay lock-free and
  read only plain stored properties.
- Never animate `layer.transform`/`anchorPoint` on the overlay view (it drifts); opacity only.
- Log lines are the debugging interface: keep existing markers stable, add fields rather than
  renaming.

See `Lessons Learned.md` and `docs/gesture-recognition.md` for the longer history.
