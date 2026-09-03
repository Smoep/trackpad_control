# Lessons Learned

## Tuning values that worked
- Zone-tap overlap timing: `0.16s` for double-tap overlap and `0.22s` for 3+ tap overlap reduced left-side delay and improved recognition reliability.
- Desktop window move action improved after probing multiple title-bar grab points and verifying drag mode before switching Spaces.

## Things that caused problems
- Returning pass-through CGEvent tap events with `Unmanaged.passRetained(event)` caused long-uptime memory growth; `passUnretained` fixed the confirmed leak.
- `ENABLE_APP_SANDBOX = YES` blocked `dlopen` of `MultitouchSupport`, which prevented raw touch callbacks.
- Wrong touch record size (`kTouchRecordSize = 80` instead of `96`) broke multi-touch parsing.
- Using `ObjectIdentifier(touch.identity as AnyObject)` for touch identity was unstable across callbacks and broke per-finger tracking.
- Very low disk space caused Xcode build/launch failure even when code was fine.

## Build/run steps that work
- Build: `xcodebuild -configuration Release -derivedDataPath build-release -scheme trackpad_control`
- Deploy: copy `build-release/Build/Products/Release/trackpad_control.app` to `/Applications/Trackpad Control.app`, then relaunch.
- Verify deploy actually took effect by checking deployed binary hash matches build output and process PID changes after relaunch.
- If launch suddenly fails without code changes, run `df -h /` first and clean generated build folders if needed.

## Useful log messages and what they mean
- `No space left on device` while Xcode writes build metadata (for example `build-debug/info.plist`) means disk pressure is the root cause, not app logic.
- Build marked "green" plus a successful direct app-bundle launch check indicates toolchain/build output is healthy.
- Matching deployed/build binary hashes and a new app PID after relaunch confirm the running app is the new build.

## Diagnosis lessons (2026-09-03)
- Measure before theorizing. Three code-reading theories for the scroll bleed (main-thread race, staggered landing, stale 5 s valve) were all wrong; a 60-line listen-only event tap (`scripts/scroll_listener.swift`) showed the leak was macOS momentum after lift within one test round.
- Anchor holds were rejected because drift was measured from the first contact sample; the finger centroid shifts 0.013–0.02 while flattening. Measure from the position at candidate start.
- Tap-to-click during an anchor hold reached the window behind because `leftMouseDown/Up` were not in the blocking tap's mask.
- A blocked scroll sequence's trailing `changed` event can arrive after the MT lift frame has reset capture state — decide per sequence (`swallowedScrollSequence`), never per event.
- Offline harness ≠ live reality: leave-one-out on recordings was 98% while live failures were ~10%. Record live strokes (`live-strokes.jsonl`) and evaluate matcher changes against those; synthetic perturbations of recordings gave the wrong answer.
- Sample thumbnails stretched X/Y independently, hiding leg-length and hook differences between recordings; visuals used for judging data must be to scale.
- The `SKIP cell=` anchor-zone log repeated every frame (69% of a 41 MB log) because the "attempted" flag was set after the early return.
