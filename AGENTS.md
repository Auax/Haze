# Focus Recorder

Native macOS SwiftUI app for personal screen recording, inspired by Screen Studio.

## Location

`/Users/auax/Desktop/Trabajo/FocusRecorder`

## Goal

Build a lightweight native macOS recorder that improves on default macOS screen recording with:

- display, window, and region recording
- configurable resolution, frame rate, and bitrate
- live capture preview
- smooth custom cursor overlay
- automatic smooth zoom detection
- post-recording zoom timeline editing
- export to rendered video with cursor and zoom effects

## Tech Stack

- Swift Package Manager
- SwiftUI
- AppKit
- AVFoundation
- CoreImage
- ScreenCaptureKit
- CoreGraphics permission preflight

## Important Files

- `Package.swift`: SwiftPM package definition.
- `Sources/FocusRecorder/FocusRecorderApp.swift`: app entry point.
- `Sources/FocusRecorder/ContentView.swift`: main UI, preview, zoom timeline editor.
- `Sources/FocusRecorder/CaptureEngine.swift`: ScreenCaptureKit recording, permission checks, source discovery, raw recording, cursor sampling, auto zoom generation.
- `Sources/FocusRecorder/ExportRenderer.swift`: renders final video with smooth zooms and cursor overlay.
- `Sources/FocusRecorder/CursorOverlay.swift`: custom cursor image compositing.
- `Sources/FocusRecorder/Models.swift`: recording settings, cursor samples, zoom keyframes, session model.
- `Sources/FocusRecorder/RegionPicker.swift`: draggable region picker overlay.
- `scripts/package-app.sh`: builds and signs `Build/FocusRecorder.app`.
- `scripts/reset-screen-recording-permission.sh`: resets macOS Screen Recording permission for `local.focusrecorder.app`.

## Run

Use the app bundle, not `swift run`, for stable macOS Screen Recording permissions:

```bash
scripts/package-app.sh
open Build/FocusRecorder.app
```

## Permissions

The app uses bundle id:

`local.focusrecorder.app`

The package script signs the bundle with a stable local designated requirement. If permissions get stuck:

```bash
scripts/reset-screen-recording-permission.sh
```

Then open the app, grant Screen Recording permission in System Settings, quit, and reopen.

## Current Behavior

- Recording works after Screen Recording permission is granted.
- Raw recordings and sidecar timelines are saved to `~/Movies/FocusRecorder`.
- After recording, the app shows thumbnail-based preview frames instead of SwiftUI `VideoPlayer`.
- `VideoPlayer` was removed because it crashed inside `_AVKit_SwiftUI` on macOS 26.5 after stopping a recording.
- Export applies smooth zooms and custom cursor overlay.

## Known Issues / Next Work

- Thumbnail preview works but is not true playback.
- Auto zoom detection is heuristic-based and can still be improved.
- Timeline editing supports scrub/playhead, draggable zoom blocks, and zoom inspector, but could use richer trimming and preview of rendered zoom.
- Build has a non-blocking warning: `AVAssetImageGenerator.copyCGImage(at:)` is deprecated in macOS 15; migrate to async image generation later.
