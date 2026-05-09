# Goal 1: Conservative Rendering/Preview Performance Improvements

Implement only the following low-risk quality/performance improvements for Haze. Keep the change scoped. Do not perform unrelated UI, model, architecture, packaging, or formatting refactors.

## Context

Haze is a native macOS SwiftUI screen recorder. Relevant files:

- `Sources/Haze/ExportRenderer.swift`: final Core Image export pipeline, source frame provider, polish pipeline, preview frame rendering.
- `Sources/Haze/CaptureEngine.swift`: ScreenCaptureKit capture, raw writer, live recording preview, cursor/event sampling.
- `Sources/Haze/CursorOverlay.swift`: cursor raster/overlay rendering if present in the project.
- `Sources/Haze/AppViewModel.swift`: session/editor state coordinator only if needed.

Build/package workflow:

```bash
swift build
scripts/package-app.sh
```

## Non-Goals

- Do not change final export appearance intentionally.
- Do not replace the high-quality temporal motion blur with an approximation.
- Do not add broad third-party dependencies.
- Do not change session JSON schema.
- Do not rewrite editor UI.
- Do not touch unrelated preferences, hotkeys, packaging, or design.
- Do not modify the raw recording pipeline except where needed to ensure preview downscaling does not affect it.

---

## Change 1: Use Metal-Backed Core Image Contexts

### Current issue

`ExportRenderer`, `CaptureEngine`, and `CursorOverlay` create plain `CIContext(options: [.workingColorSpace: NSNull()])`.

Export already uses Metal-compatible pixel buffers, but the context does not explicitly use a shared `MTLDevice`.

### Implement

Add a small shared factory, for example:

- `CIContext.hazeMetalBacked()`
- or `RenderContextFactory`

Behavior:

- Prefer `MTLCreateSystemDefaultDevice()`.
- Create `CIContext(mtlDevice:options:)`.
- Preserve existing working color behavior, especially:

```swift
[.workingColorSpace: NSNull()]
```

- Fall back to the current `CIContext(options:)` if Metal device creation fails.

Use the factory in:

- `ExportRenderer`
- `CaptureEngine` preview/resize context
- `CursorOverlay` cursor raster context, if that file/context exists

### Quality requirement

Final output should be visually the same. Tiny GPU/CPU pixel-level differences are acceptable only if there is no visible effect.

---

## Change 2: Lower-Cost Live Recording Preview

### Current issue

`CaptureEngine.publishPreviewIfNeeded(from:)` converts full capture frames to `CGImage`/`NSImage` at about 15 fps even though the recorder UI preview is small.

### Implement

- Cap live preview rendering size before creating `CGImage`/`NSImage`.
- Keep raw recording resolution and export quality unchanged.
- Suggested cap:

```swift
private let maxLivePreviewSize = CGSize(width: 720, height: 450)
```

or equivalent constants.

- Preserve aspect ratio.
- Keep preview FPS around the current 15 fps unless there is a clear technical reason to change it.
- Reuse the existing preview context or the new Metal-backed context factory.
- Ensure `frameBufferForWriting(...)` still writes the full selected output size and is not affected by preview downscaling.

### Quality requirement

Only the small live recorder preview may become slightly softer. Raw recording and rendered export must be unchanged.

---

## Verification

Run:

```bash
swift build
scripts/package-app.sh
```

If possible, manually test:

- Open packaged app.
- Record a short display or region clip.
- Confirm live preview appears.
- Confirm recording stops cleanly.
- Open editor.
- Export a short clip and confirm output appearance is unchanged.

## Expected Deliverable

- Small, scoped code changes.
- No unrelated formatting churn.
- Final summary listing files changed.
- Confirm both items completed.
- If either item is skipped, explain why in one sentence and leave a clear TODO in `docs/TODO.md`.
