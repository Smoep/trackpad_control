# macOS Low-Memory Playbook

This playbook captures the approach that brought Trackpad Control back down from hundreds of MB of long-running footprint to a very small idle footprint. Use it as the default process for menu-bar, background, helper, and always-on macOS apps.

## 1. Start With Evidence

Before changing code, measure the actual running app.

```sh
pid=$(pgrep -f '/Applications/App Name.app/Contents/MacOS/AppExecutable' | head -1)
ps -o pid,ppid,etime,rss,vsz,comm -p "$pid"
vmmap -summary "$pid" | egrep -i 'Physical footprint|TOTAL|MALLOC|Writable regions|ReadOnly portion of Libraries'
sample "$pid" 2 -file /tmp/app-idle.sample
head -120 /tmp/app-idle.sample
```

Record:

- PID and uptime.
- `ps` RSS.
- `vmmap` physical footprint and peak.
- `MALLOC` allocated bytes and region growth.
- Whether `sample` shows idle run-loop waiting, repeated work, or a hot callback.

Interpretation guide:

- High CPU in `sample`: repeated work, timer storm, polling, rendering, or logging.
- Low CPU but growing `MALLOC`: retained objects, callbacks returning retained references, unbounded arrays/caches, or window/view state not released.
- Large `__TEXT` resident but small footprint: mostly framework/runtime baseline, usually not app-owned.
- Large writable/malloc footprint after long uptime: app-owned growth until proven otherwise.

## 2. Confirm Release Deployment

Make sure you are testing the app users actually run.

```sh
xcodebuild -configuration Release -derivedDataPath build-release -scheme AppScheme build
md5 -q 'build-release/Build/Products/Release/App.app/Contents/MacOS/AppExecutable'
md5 -q '/Applications/App Name.app/Contents/MacOS/AppExecutable'
codesign -dv --verbose=4 '/Applications/App Name.app' 2>&1 | egrep 'Identifier|Format|Runtime|Authority|VersionSDK'
plutil -p '/Applications/App Name.app/Contents/Info.plist' | egrep 'CFBundleIdentifier|LSUIElement|DTSDK|DTXcode'
```

Do not trust `BUILD SUCCEEDED` by itself. Verify the deployed binary hash matches the built binary, and verify the relaunched PID is new.

## 3. Keep Always-On Startup Tiny

For menu-bar/background apps, launch should create only the always-on path:

- status item or menu-bar scene
- event taps, hotkeys, clipboard monitors, or device listeners that must run
- lightweight model metadata
- small settings objects

Do not eagerly create:

- settings windows
- history windows
- editors
- large SwiftUI trees
- image-heavy views
- preview grids
- NSHostingControllers for UI that is not visible

Preferred pattern:

- Use `MenuBarExtra` or an AppKit status item for the always-on surface.
- Create settings/history windows lazily on explicit user action.
- Hold one window reference while visible.
- Clear the delegate and set the reference to `nil` in `windowWillClose`.
- Avoid SwiftUI `WindowGroup` for background-only apps unless you really want eager scene/window restoration behavior.

Example shape:

```swift
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsRootView())
            let settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow.title = "Settings"
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.delegate = self
            window = settingsWindow
        }

        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as AnyObject? === window else { return }
        window?.delegate = nil
        window = nil
    }
}
```

## 4. Audit Ownership At System Boundaries

Long-running macOS apps often leak at C/CoreFoundation/AppKit callback boundaries. Be strict about ownership.

For `CGEventTap` callbacks, pass-through events should normally return unretained events:

```swift
return Unmanaged.passUnretained(event)
```

Do not return this for pass-through events unless you have a specific ownership reason:

```swift
return Unmanaged.passRetained(event)
```

`passRetained` in a high-frequency event tap can retain every scroll/mouse/key/gesture event and slowly grow memory into hundreds of MB while the app appears idle.

Audit similar APIs:

- `CGEvent.tapCreate` callbacks
- `CFRunLoopSource` callbacks
- `IOHIDManager` callbacks
- `AXObserver` callbacks
- `NSEvent` monitors
- C APIs returning `Unmanaged`
- `takeRetainedValue` vs `takeUnretainedValue`

Rule of thumb:

- If you did not create/copy/retain it, do not add a retain on return.
- If an API gives you an object only for the duration of a callback, pass it through unretained unless the API documentation says otherwise.

## 5. Bound Every Always-On Buffer

Every list touched by timers, device callbacks, event taps, or monitors must have an explicit bound or reset path.

Check for:

- gesture point arrays
- continuous step history
- clipboard histories
- log line buffers
- recent-event caches
- per-frame rendering paths
- diagnostics arrays
- match-score histories

Rules:

- Clear gesture paths on completion, cancellation, timeout, and stop.
- Keep only the last N telemetry samples.
- Use ring buffers for diagnostics.
- Avoid appending to arrays from high-frequency callbacks unless the array has a hard cap.
- Cancel timers and dispatch work items when state ends.

## 6. Put Payloads On Disk, Metadata In Memory

For apps with clipboard/history/document/image/rich data, keep memory and UserDefaults metadata-only.

In memory/UserDefaults keep:

- id
- date
- kind/type
- short preview
- byte count
- file path or relative payload name
- content hash/signature
- availability state

On disk under `~/Library/Application Support/<AppName>/`, store:

- full text files
- image data files
- rich payload files by UTI/type
- thumbnails only if the UI needs them

Do not store partial payloads as if they are complete. Either store the whole payload on disk, or mark it explicitly unavailable/skipped.

Migration shape:

1. Decode old inline records.
2. Write full payloads to Application Support.
3. Replace old records with metadata-only records.
4. Re-save preferences/database.
5. Prune orphaned files.
6. Verify old items still paste/open/export by loading payloads lazily from disk.

## 7. Keep UserDefaults Small

UserDefaults should be settings, window positions, and small metadata. It should not hold large JSON blobs, images, base64, rich text, or history payloads.

Check sizes:

```sh
prefs="$HOME/Library/Preferences/com.example.app.plist"
ls -lh "$prefs"
plutil -p "$prefs" | head -200
```

Clean up obsolete keys during migration or startup maintenance. Be careful not to remove user settings still used by current code.

## 8. Manage Diagnostics Logs

Diagnostics logs are useful, but they must not grow forever.

Preferred options:

- Use `Logger`/`os_log` for normal diagnostics.
- Gate file logs behind an explicit diagnostics setting.
- Rotate or cap file logs, for example at 1 MiB to 10 MiB depending on need.
- Do not write file logs from a high-frequency callback unless sampling or rate-limited.

Check:

```sh
du -sh "$HOME/Library/Application Support/AppName"
find "$HOME/Library/Application Support/AppName" -maxdepth 2 -type f -print0 | xargs -0 ls -lh
```

## 9. Verify With A Short Loop, Then A Soak

After every memory fix:

```sh
# fresh launch baseline
pid=$(pgrep -f '/Applications/App Name.app/Contents/MacOS/AppExecutable' | head -1)
ps -o pid,ppid,etime,rss,vsz,comm -p "$pid"
vmmap -summary "$pid" | egrep -i 'Physical footprint|TOTAL|MALLOC|Writable regions'
sample "$pid" 2 -file /tmp/app-after.sample

# use the app normally, then repeat after 10 min, 1 hour, and overnight
```

A good result looks like:

- clean launch footprint is low
- footprint remains roughly stable after normal idle use
- high-frequency interactions do not produce monotonic growth
- closing settings/history windows returns UI-owned memory where practical
- UserDefaults stays small
- Application Support grows only by expected payload/log files

## 10. Postmortem Template

Use this after each app cleanup.

```md
# Memory Postmortem: <AppName>

## Symptom
- What was reported?
- How high did memory get?
- How long had the process been running?

## Baseline
- Release or Debug:
- PID / uptime:
- ps RSS:
- vmmap physical footprint:
- vmmap malloc allocated:
- sample summary:
- UserDefaults size:
- Application Support size:

## Classification
- app-owned data:
- UI/window/view state:
- framework/runtime baseline:
- leaked/repeated work:

## Fixes
- Change 1:
- Change 2:

## Verification
- Release build hash:
- deployed hash:
- new PID:
- after ps RSS:
- after physical footprint:
- after malloc allocated:
- idle sample result:
- persisted data result:
- behavior smoke tests:

## Follow-Up
- soak duration:
- remaining risks:
- next measurement date:
```

## 11. Trackpad Control Lesson

The major long-uptime memory issue in Trackpad Control was consistent with retained pass-through `CGEvent` objects in event-tap callbacks. The app appeared idle in samples, but `MALLOC_SMALL` grew by hundreds of MB over time. Returning pass-through events with `Unmanaged.passUnretained(event)` fixed the growth pattern while preserving behavior.

The secondary quick win was lazy settings UI: the always-on process no longer creates the settings window/view tree at launch.
