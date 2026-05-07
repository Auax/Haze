# Haze

A native macOS screen recorder for clean product demos, tutorials, cursor motion, and cinematic zooms.

[Features](#features) · [Quick Start](#quick-start) · [Permissions](#permissions) · [Roadmap](#roadmap)

---

## Overview

Haze is a lightweight macOS recording app. It captures your screen, tracks cursor movement, suggests smooth zooms automatically, and renders a final video with polished cursor and zoom effects.

It is designed for people who record product walkthroughs, coding demos, tutorials, bug reports, or short visual explanations and want something more polished than the default macOS recorder.

## Features

| Capture                     | Editing                 | Export                  |
| --------------------------- | ----------------------- | ----------------------- |
| Display recording           | Editable zoom keyframes | Rendered cursor overlay |
| Window recording            | Timeline-based workflow | Smooth zoom animation   |
| Region recording            | Auto zoom suggestions   | Configurable bitrate    |
| FPS and resolution controls | Cursor timeline sidecar | Final video output      |

**Minimum target: macOS 15.0+**

## Quick Start

### Xcode

Open `Haze.xcodeproj` and press **⌘R**. Xcode builds, signs, and launches the app directly.

### Build script

The build script produces a properly bundled and signed `.app` — recommended when testing Screen Recording permission, since macOS ties the permission to the app's bundle identity.

```bash
scripts/package-app.sh
open Build/Haze.app
```

The app is signed with bundle identifier:

```
local.haze.app
```

### CLI (quick iteration)

```bash
swift run Haze
```

## Permissions

macOS requires Screen Recording permission before capture can start. The permission is tied to the app identity, so it is most reliable when running the bundled app rather than `swift run`.

Recommended flow:

1. Open `Build/Haze.app` (or run via Xcode)
2. Start a recording — macOS will prompt for Screen Recording permission
3. Grant permission in System Settings
4. Quit and reopen Haze

If permissions get stuck after older builds or signing changes:

```bash
scripts/reset-screen-recording-permission.sh
```

Then open the app, grant permission again, quit, and relaunch.

## Output

Recordings are saved to:

```
~/Movies/Haze
```

The app stores raw `.mov` recordings alongside timeline sidecar data, then exports a rendered video with cursor and zoom effects applied.

## Project Structure

```
Haze
├── Haze.xcodeproj          # Xcode project
├── Package.swift           # SPM manifest (used by build script and swift run)
├── Sources/Haze
│   ├── HazeApp.swift
│   ├── AppViewModel.swift
│   ├── CaptureEngine.swift
│   ├── ContentView.swift
│   ├── CursorOverlay.swift
│   ├── EditorView.swift
│   ├── ExportRenderer.swift
│   ├── Models.swift
│   ├── PlayerView.swift
│   ├── Preferences.swift
│   ├── PreferencesView.swift
│   ├── RegionPicker.swift
│   ├── RenderFrameState.swift
│   ├── Theme.swift
│   ├── TimelineStore.swift
│   ├── Info.plist
│   ├── Haze.entitlements
│   └── Resources
│       ├── AppIcon.icns
│       └── Cursors/        # SVG cursor artwork
└── scripts
    ├── package-app.sh
    └── reset-screen-recording-permission.sh
```

## Roadmap

- True playback preview instead of thumbnail-based preview frames
- Smarter auto zoom detection
- Richer timeline editing
- Trimming controls
- Preview of rendered zoom/cursor effects before export
