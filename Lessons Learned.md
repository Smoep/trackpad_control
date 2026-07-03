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
