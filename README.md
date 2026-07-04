# Trackpad Control

Trackpad Control is a macOS menu bar app that turns custom multi-finger trackpad gestures into actions like app launch, keyboard shortcuts, and window management.

It is built for power users who want gesture automation on Mac without opening full automation tools.

## Download

[**→ Download trackpad_control.zip from the latest release**](https://github.com/Smoep/trackpad_control/releases/latest)

Unzip and drag **trackpad_control.app** to your Applications folder.

> **First launch:** macOS will show a security warning because the app is not signed with an Apple Developer certificate.
> Right-click (or Control-click) the app → **Open** → **Open**. You only need to do this once.

## What It Does

- Records one to five finger gestures on the Mac trackpad
- Matches gestures with a shape-based recognizer tuned for noisy real-world input
- Triggers actions: launch apps, run shortcuts, execute continuous actions, and control windows
- Runs from the menu bar with configurable settings and optional overlay diagnostics

## Build & install

Requires macOS 26 and Xcode 26+.

```bash
git clone https://github.com/Smoep/trackpad_control.git
cd trackpad_control
xcodebuild -project trackpad_control.xcodeproj -scheme trackpad_control -configuration Release \
  -derivedDataPath build-release build
cp -R build-release/Build/Products/Release/trackpad_control.app /Applications/trackpad_control.app
open /Applications/trackpad_control.app
```

## Keywords

macOS, trackpad gestures, gesture recognition, gesture automation, menu bar app, window management, productivity, SwiftUI, multitouch
