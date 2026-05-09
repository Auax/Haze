# Goal 2: Indexed Render State and Thumbnail Cache

Implement only the following editor/export performance improvements for Haze. Keep changes scoped. Preserve final rendered visual output unless explicitly noted.

## Context

Haze is a native macOS SwiftUI screen recorder. Relevant files:

- `Sources/Haze/RenderFrameState.swift`: builds per-frame zoom/cursor/click state for editor preview and export.
- `Sources/Haze/ExportRenderer.swift`: final Core Image export pipeline, source frame provider, polish pipeline, preview frame rendering.
- `Sources/Haze/EditorView.swift`: editor preview/timeline UI and current thumbnail strip implementation.
- `Sources/Haze/AppViewModel.swift`: session/editor state coordinator.
- `Sources/Haze/Models.swift`: recording/session/edit models and cursor smoothing helpers.

Build/package workflow:

```bash
swift build
scripts/package-app.sh
```

## Non-Goals

- Do not change final export appearance intentionally.
- Do not replace the high-quality temporal motion blur with an approximation.
- Do not add broad third-party dependencies.
- Do not change session JSON schema unless absolutely necessary.
- Do not rewrite the editor UI.
- Do not touch unrelated preferences, hotkeys, packaging, recording capture, or design.
- Do not combine this with Metal context or live recording preview work if those are not already implemented.

---

## Change 1: Add Render Timeline Index

### Current issue

`RenderFrameStateBuilder.make(...)` repeatedly scans these arrays for every preview/export frame:

- `session.zooms`
- `session.cursorSamples`
- `session.cursorShapes`
- `session.clicks`

Export motion blur calls this multiple times per output frame, so repeated scans are expensive.

### Implement

Add an internal helper, likely:

- `RenderTimelineIndex`

Place it in:

- `Sources/Haze/RenderFrameState.swift`
- or a small new file under `Sources/Haze/`

It should be built once per `RecordingSession`.

It should provide fast lookups for:

- active zoom at source time
- smoothed/interpolated cursor at source time
- cursor shape at source time
- active click ripple states at source time
- optional cursor spring rotation support, if the current builder handles this

### Required behavior

- Preserve existing timing semantics and boundary tolerances from `RenderFrameStateBuilder`.
- Keep existing free functions if useful.
- Route export/editor hot paths through the index.
- Avoid changing model types or persisted session format.

### Integration points

- `ExportRenderer.render(...)`: build one index per export and pass/reuse it during frame rendering, including motion blur sub-samples.
- `ExportRenderer.previewCGImage(...)`: use the same indexed state path where practical.
- `EditorView` live preview: use the index if it can be introduced without major view churn.
- If editor integration becomes invasive, prioritize export first and leave a small TODO comment.

### Quality requirement

The generated `RenderFrameState` values should match the old path for representative times.

If the project has a test target, add focused tests comparing old and indexed paths at representative timestamps.

If there is no test target, add a small non-intrusive debug/self-check helper only if it does not ship intrusive code or alter release behavior.

---

## Change 2: Add Thumbnail Cache

### Current issue

`ThumbnailStrip` in `EditorView.swift` owns thumbnail state and regenerates thumbnails when URL/start/end/width changes.

This repeats `AVAssetImageGenerator` work across reloads and resizes.

### Implement

Add a lightweight thumbnail cache:

- Prefer placing it near `ThumbnailStrip` in `EditorView.swift` if small.
- Use a small new file if cleaner.
- Start with an in-memory `actor` or `@MainActor` cache.
- Disk cache is optional only if simple; do not overbuild it.

Cache key should include:

- raw video URL path
- file modification date or file size
- start time bucket
- end time bucket
- thumbnail count
- target maximum size

Behavior:

- Reuse cached `[CGImage]`.
- Keep memory bounded with a simple LRU/count cap.
- Avoid retaining huge full-size images.
- Keep `generator.maximumSize = CGSize(width: 200, height: 120)` or similar.
- Preserve current thumbnail strip appearance.

### Optional modernization

Existing code may use `generateCGImageAsynchronously`.

If easy, migrate to the modern async image generation API for macOS 15+ while keeping compatibility.

If not easy, leave the existing API and focus on cache.

---

## Verification

Run:

```bash
swift build
scripts/package-app.sh
```

If possible, manually test:

- Open packaged app.
- Open editor for an existing or newly recorded clip.
- Confirm timeline thumbnails appear.
- Resize/reopen editor and confirm thumbnails still appear.
- Scrub/play editor preview with cursor and zoom overlays.
- Export with motion blur enabled.
- Compare visually against expected behavior.

## Expected Deliverable

- Small, scoped code changes.
- No unrelated formatting churn.
- Final summary listing files changed.
- State whether Render Timeline Index was used in export, preview, and editor live preview.
- State whether thumbnail cache was completed.
- If any item is skipped, explain why in one sentence and leave a clear TODO in `docs/TODO.md`.
