# Haze App Structure

This is a file map for humans and AI agents reviewing or changing Haze. Use it to find the owner of a feature before editing.

## Top-Level Project Files

- `Package.swift`
  - Swift Package Manager target definition.
  - Declares the `Haze` executable target, resources, app plist, and entitlements.

- `Haze.xcodeproj/`
  - Xcode project wrapper and shared scheme.
  - Useful for running from Xcode, but core source ownership is still under `Sources/Haze`.

- `README.md`
  - User-facing project overview, feature list, quick start, and roadmap.

- `AGENTS.md`
  - High-level repo instructions for coding agents.
  - Keep run, permission, and known-issue notes here when they affect agent behavior.

- `APP_STRUCTURE.md`
  - This file. Keep it updated when files are split, renamed, or major ownership changes.

## App Entry, Windows, and App Lifecycle

- `Sources/Haze/HazeApp.swift`
  - App entry point: `HazeApp`.
  - Creates and wires the shared `AppViewModel`.
  - Owns AppKit lifecycle glue through `HazeAppDelegate`.
  - Owns the floating recorder panel/window types:
    - `RecorderPanel`
    - `RecorderPanelController`
    - `RecorderWindowController`
  - Owns the editor window types:
    - `EditorAppWindow`
    - `EditorWindowController`
  - Owns menu bar/status item behavior:
    - `RecordingStatusItemController`
  - Owns preferences window presentation:
    - `PreferencesWindowController`
  - Adds app-level notifications in `Notification.Name`.

## Shared App State and Commands

- `Sources/Haze/AppViewModel.swift`
  - Main application state coordinator: `AppViewModel`.
  - Owns shared instances of:
    - `CaptureEngine`
    - `ExportRenderer`
  - Coordinates recording start/stop.
  - Stores the current `RecordingSession`.
  - Loads and manages the recordings library.
  - Owns editor commands for zooms, trims, clipboard, selection, undo, and redo.
  - Regenerates automatic zooms from recorded cursor/click/keystroke data.
  - Persists timeline/session edits through `TimelineStore`.
  - Installs the global toggle-recording hotkey from preferences.

## Data Models

- `Sources/Haze/Models.swift`
  - Core Codable/session models used across capture, editing, and export.
  - Capture settings:
    - `CaptureKind`
    - `ResolutionPreset`
    - `RecordingSettings`
    - `CaptureSource`
    - `AudioInputDevice`
  - Cursor data:
    - `CursorSprite`
    - `CursorShape`
    - `CursorShapeSample`
    - `CursorSample`
  - Input events:
    - `MouseClickEvent`
    - `KeystrokeEvent`
  - Zoom editing:
    - `ZoomKeyframe`
    - `ZoomEasing`
    - `CursorFollowStyle`
    - `CubicBezier`
  - Export presentation settings:
    - `BackgroundStyle`
    - `BackgroundImageFit`
    - `EditSettings`
  - Session container:
    - `RecordingSession`
  - Render math helpers:
    - `CameraState`
    - `RecordingSettings` extensions for output sizing.

- `Sources/Haze/Defaults.swift`
  - Centralized defaults for user-facing settings and generated timeline values.
  - Contains grouped defaults for recording, cursor, auto zooms, manual zooms, editor-created zooms, zoom follow behavior, easing curves, export/edit styling, preferences, and hotkeys.
  - Start here when changing the default value of a setting, reset button value, or generated zoom timing.

- `Sources/Haze/RenderFrameState.swift`
  - Shared per-frame render state for preview and export.
  - Contains:
    - `CursorRenderState`
    - `ClickEffectState`
    - `RenderFrameState`
    - `RenderFrameStateBuilder`
  - Use this when preview/export need to agree on active zoom, cursor, and click state at a timestamp.

- `Sources/Haze/TimelineStore.swift`
  - Reads and writes sidecar timeline/session JSON files.
  - Keeps timeline persistence separate from UI and capture logic.

## Recording and Capture

- `Sources/Haze/CaptureEngine.swift`
  - ScreenCaptureKit recording engine: `CaptureEngine`.
  - Checks and requests screen-recording permission.
  - Discovers displays, windows, and microphone devices.
  - Starts and stops raw screen recording.
  - Captures live preview frames.
  - Captures optional microphone and system audio.
  - Samples cursor position, cursor shape, clicks, and keystrokes while recording.
  - Generates heuristic default zooms from captured interaction data.
  - Writes raw recordings and sidecar timelines under `~/Movies/Haze`.
  - Implements:
    - `SCStreamOutput`
    - `SCStreamDelegate`
    - `AVCaptureAudioDataOutputSampleBufferDelegate`
  - Defines `RecorderError`.

- `Sources/Haze/RegionPicker.swift`
  - AppKit overlay used to pick a draggable recording region.
  - Used when `RecordingSettings.captureKind == .region`.

## Recorder UI

- `Sources/Haze/ContentView.swift`
  - Main floating recorder UI.
  - Displays source selectors for display/window/region capture.
  - Displays microphone and system audio controls.
  - Displays quality/video settings controls for FPS, resolution, and bitrate.
  - Displays live capture preview image from `CaptureEngine`.
  - Displays recent recording library popover/list.
  - Owns the record button UI and calls `AppViewModel.toggleRecording()`.
  - Contains small supporting views for permission prompts, region selection controls, meters, library rows, and recorder-window configuration.

- `Sources/Haze/Theme.swift`
  - Shared SwiftUI color helpers/theme values.
  - Use for visual consistency before introducing new colors directly in views.

## Editor UI

- `Sources/Haze/EditorView.swift`
  - Main post-recording editor window UI.
  - Owns the timeline editor, playhead, thumbnails, zoom blocks, trim handles, inspector panels, settings panels, and export panel.
  - Contains keyboard handling for editor shortcuts.
  - Contains controls for:
    - Adding, deleting, duplicating, splitting, copying, cutting, and pasting zooms.
    - Moving and resizing zoom keyframes.
    - Editing zoom scale, timing, anchor, easing, and cursor-follow behavior.
    - Editing clip trim start/end.
    - Editing background, padding, corner radius, shadow, and motion blur.
    - Editing cursor, click, and export settings.
    - Choosing export destination and starting render.
  - Uses `AppViewModel` for durable state changes and `ExportRenderer` for final render.
  - Important helper area: `EditorPlaybackHolder` keeps playback controller lifecycle stable.

- `Sources/Haze/PlayerView.swift`
  - AppKit-backed video playback host.
  - Contains:
    - `PlayerHostNSView`
    - `PlayerHostView`
    - `PlaybackController`
  - Use this for actual AVPlayer-based playback surfaces.
  - Note: recorder preview currently uses generated thumbnails/images instead of SwiftUI `VideoPlayer` because of prior `_AVKit_SwiftUI` crashes after recording stop.

## Export and Rendering

- `Sources/Haze/ExportRenderer.swift`
  - Final video rendering pipeline: `ExportRenderer`.
  - Reads raw recording frames through a `SourceFrameProvider`.
  - Applies trim, background, padding, corner radius, shadow, motion blur, zoom animation, cursor overlay, click effects, and audio handling.
  - Writes the rendered output video.
  - Contains:
    - `SourceFrameProvider`
    - `SequentialAssetFrameProvider`
    - `PolishPipeline`
  - This is the primary file for changing the final exported look.

- `Sources/Haze/CursorOverlay.swift`
  - Cursor compositing and cursor asset logic.
  - Contains:
    - `CursorSpriteRender`
    - `CursorOverlay`
    - `CustomCursorImageCache`
    - `CursorShapeDetector`
    - `LionCursorAssets`
  - Owns built-in cursor SVG rasterization/loading and custom cursor image caching.
  - Used by export and any preview path that needs rendered cursor overlays.

## Preferences and Hotkeys

- `Sources/Haze/Preferences.swift`
  - Preferences data model and persistence.
  - Contains:
    - `HotkeyBinding`
    - `AppPreferences`
    - `PreferencesStore`
  - Stores app preferences such as editor hotkeys and toggle-recording hotkey.

- `Sources/Haze/PreferencesView.swift`
  - Preferences window UI.
  - Contains:
    - `PreferencesView`
    - `HotkeyRecorderNSView`
  - Use this for changing visible preference controls or hotkey recording behavior.

## Resources

- `Sources/Haze/Info.plist`
  - App bundle metadata.
  - Includes bundle id related settings for `local.haze.app`.

- `Sources/Haze/Haze.entitlements`
  - App sandbox/hardened runtime capability settings used by the packaged app.

- `Sources/Haze/Resources/AppIcon.icns`
  - App icon bundled into the app.

- `Sources/Haze/Resources/Cursors/*.svg`
  - Built-in cursor artwork used by `CursorOverlay.swift`.
  - Add new bundled cursor shapes here and wire them through cursor asset logic.

## Build and Permission Scripts

- `scripts/package-app.sh`
  - Builds and signs `Build/Haze.app`.
  - Use this instead of `swift run` for stable macOS Screen Recording permissions.

- `scripts/reset-screen-recording-permission.sh`
  - Resets macOS Screen Recording permission for `local.haze.app`.
  - Use when macOS permission state gets stuck while testing capture.

## Common Change Map

- Change app startup, menu bar behavior, floating recorder window, or editor window creation:
  - `Sources/Haze/HazeApp.swift`

- Change recorder controls, source selection, recording button, live preview, or library popover:
  - `Sources/Haze/ContentView.swift`
  - `Sources/Haze/AppViewModel.swift` if behavior/state changes are needed.

- Change capture behavior, permissions, source discovery, preview frame capture, cursor sampling, audio capture, or auto zoom generation:
  - `Sources/Haze/Defaults.swift` for generated zoom timing defaults.
  - `Sources/Haze/CaptureEngine.swift`
  - `Sources/Haze/Models.swift` if settings/session schema changes are needed.

- Change region selection:
  - `Sources/Haze/RegionPicker.swift`
  - `Sources/Haze/ContentView.swift` for the recorder control that launches it.

- Change editor timeline interactions, zoom inspector, trim controls, keyboard shortcuts, or export UI:
  - `Sources/Haze/EditorView.swift`
  - `Sources/Haze/AppViewModel.swift` for persistent editing commands.

- Change timeline/session JSON persistence:
  - `Sources/Haze/TimelineStore.swift`
  - `Sources/Haze/Models.swift`

- Change exported video appearance:
  - `Sources/Haze/ExportRenderer.swift`
  - `Sources/Haze/RenderFrameState.swift`
  - `Sources/Haze/CursorOverlay.swift` for cursor-specific rendering.
  - `Sources/Haze/Models.swift` if export/edit settings change.

- Change cursor visuals or cursor shape detection:
  - `Sources/Haze/CursorOverlay.swift`
  - `Sources/Haze/Resources/Cursors/`
  - `Sources/Haze/Models.swift` for cursor enums/settings.

- Change preferences or hotkey persistence:
  - `Sources/Haze/Defaults.swift` for factory preference and hotkey defaults.
  - `Sources/Haze/Preferences.swift`
  - `Sources/Haze/PreferencesView.swift`
  - `Sources/Haze/AppViewModel.swift` for global recording hotkey installation.

- Change shared styling:
  - `Sources/Haze/Theme.swift`
  - Existing local styles in `ContentView.swift` and `EditorView.swift`.

- Change packaging, signing, bundle id, or entitlements:
  - `Package.swift`
  - `Sources/Haze/Info.plist`
  - `Sources/Haze/Haze.entitlements`
  - `scripts/package-app.sh`

## Review Notes for Agents

- Prefer changing behavior in `AppViewModel` when the command affects app state, undo/redo, selection, or persistence.
- Prefer changing `EditorView` only for editor UI composition and immediate gestures.
- Prefer changing `CaptureEngine` only for capture-time behavior; do not put editor/export behavior there unless it is generated from raw capture data.
- Prefer changing `ExportRenderer` for final rendered output; keep preview-only UI concerns out of it.
- If you add or rename model fields, check Codable compatibility for existing sidecar timelines in `~/Movies/Haze`.
- If you touch ScreenCaptureKit permissions or bundle identity, test with the packaged app from `scripts/package-app.sh`.
