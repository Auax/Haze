

# Focus Recorder

A native macOS screen recorder for clean product demos, tutorials, cursor motion, and cinematic zooms.



[Features](#features) · [Quick Start](#quick-start) · [Permissions](#permissions) · [Roadmap](#roadmap)

---

## Overview

Focus Recorder is a lightweight macOS app inspired by Screen Studio. It captures your screen, tracks cursor movement, suggests smooth zooms automatically, and renders a final video with polished cursor and zoom effects.

It is designed for people who record product walkthroughs, coding demos, tutorials, bug reports, or short visual explanations and want something more polished than the default macOS recorder.



## Features


| Capture                     | Editing                 | Export                  |
| --------------------------- | ----------------------- | ----------------------- |
| Display recording           | Editable zoom keyframes | Rendered cursor overlay |
| Window recording            | Timeline-based workflow | Smooth zoom animation   |
| Region recording            | Auto zoom suggestions   | Configurable bitrate    |
| FPS and resolution controls | Cursor timeline sidecar | Final video output      |


## Built With



Minimum target: **macOS 15.0+**

## Quick Start

For the best development experience, run Focus Recorder as an app bundle. macOS Screen Recording permission is tied to the app identity, so the bundle flow is more reliable than `swift run`.

```bash
scripts/package-app.sh
open Build/FocusRecorder.app
```

The package script builds and signs the app as:

```text
local.focusrecorder.app
```

You can also run directly during quick iteration:

```bash
swift run FocusRecorder
```

## Permissions

macOS requires Screen Recording permission before capture can start.

Recommended flow:

1. Open `Build/FocusRecorder.app`
2. Start a recording
3. Grant Screen Recording permission in System Settings
4. Quit and reopen Focus Recorder

If permissions get stuck after older builds or signing changes:

```bash
scripts/reset-screen-recording-permission.sh
```

Then open the app, grant permission again, quit, and relaunch.

## Output

Recordings are saved to:

```text
~/Movies/FocusRecorder
```

The app stores raw recordings plus timeline sidecar data, then exports a rendered video with cursor and zoom effects applied.

## Project Structure

```text
FocusRecorder
├── Package.swift
├── Sources/FocusRecorder
│   ├── FocusRecorderApp.swift
│   ├── ContentView.swift
│   ├── CaptureEngine.swift
│   ├── EditorView.swift
│   ├── ExportRenderer.swift
│   ├── CursorOverlay.swift
│   ├── Models.swift
│   └── RegionPicker.swift
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

## Screenshots

Add real screenshots or GIFs here when you are ready:

- `docs/images/app.png`
- `docs/images/editor.png`
- `docs/images/demo.gif`

The included SVG artwork keeps the README presentable until real product screenshots are available.