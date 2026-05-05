

# Focus Recorder

Native macOS screen recorder for polished tutorials and demos, with smooth cursor rendering and editable zoom timeline.

[macOS](#)
[Swift](#)
[Platform](#)



---

## Preview

> Replace the placeholder files below with your own screenshots/GIFs for GitHub-ready presentation.

Focus Recorder Hero
Focus Recorder Timeline

---

## Table of Contents

- [Why Focus Recorder](#why-focus-recorder)
- [Features](#features)
- [Tech Stack](#tech-stack)
- [Quick Start](#quick-start)
- [Permissions](#permissions)
- [Output](#output)
- [Project Structure](#project-structure)
- [Roadmap](#roadmap)

## Why Focus Recorder

Focus Recorder is a lightweight native recorder inspired by Screen Studio, built for creators who want:

- fast setup with native performance
- clean cursor visualization
- zoom-driven storytelling
- post-recording control without a heavy editor

## Features

- Record full display, specific window, or manual region
- Control output resolution, FPS, and bitrate
- Store cursor motion in sidecar timeline data
- Render smooth custom cursor overlay on export
- Generate automatic cursor-follow zoom suggestions
- Edit zoom keyframes in timeline UI
- Export final rendered video with cursor + zoom effects

## Tech Stack

- Swift Package Manager
- SwiftUI + AppKit
- ScreenCaptureKit + AVFoundation
- CoreImage

**Minimum OS:** macOS 15.0+

## Quick Start

### Recommended (App Bundle)

Use the packaged app for stable Screen Recording permissions:

```bash
scripts/package-app.sh
open Build/FocusRecorder.app
```

Why this is recommended:

- uses stable bundle identifier: `local.focusrecorder.app`
- macOS permission tracking remains consistent
- fewer issues while iterating

### Alternative (Direct Run)

```bash
swift run FocusRecorder
```

Good for quick local iteration, but less stable for permission-sensitive testing.

## Permissions

On first capture, macOS asks for **Screen Recording** permission.

Recommended flow:

1. Launch packaged app
2. Trigger a recording
3. Grant permission in System Settings
4. Quit and relaunch app

If permissions get stuck (e.g. after older unsigned builds):

```bash
scripts/reset-screen-recording-permission.sh
```

Then relaunch, grant once, and reopen.

## Output

- Recordings and timeline sidecars: `~/Movies/FocusRecorder`
- Exported videos include cursor overlay and zoom effects

## Project Structure

- `Package.swift` - SwiftPM manifest and framework linking
- `Sources/FocusRecorder/FocusRecorderApp.swift` - app entry point
- `Sources/FocusRecorder/ContentView.swift` - main app UI and flow
- `Sources/FocusRecorder/CaptureEngine.swift` - capture pipeline
- `Sources/FocusRecorder/EditorView.swift` - timeline editor UI
- `Sources/FocusRecorder/ExportRenderer.swift` - export renderer
- `Sources/FocusRecorder/CursorOverlay.swift` - cursor compositing
- `Sources/FocusRecorder/Models.swift` - settings, models, timeline types
- `Sources/FocusRecorder/RegionPicker.swift` - region picker tooling
- `scripts/package-app.sh` - build/sign app bundle
- `scripts/reset-screen-recording-permission.sh` - reset TCC permission

## Roadmap

- Improve preview from thumbnails to true playback
- Refine automatic zoom detection heuristics
- Expand timeline editing (trimming, richer controls, render preview)

---

### Add Your Images

For a polished GitHub README, add your screenshots here:

- `docs/images/hero.png` (main app screenshot)
- `docs/images/timeline.png` (editor/timeline screenshot)

Optional: replace one image with a short GIF demo for stronger project presentation.