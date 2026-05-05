# Focus Recorder

Native macOS screen recorder prototype inspired by Screen Studio.

The app records a display, a window, or a manual region with ScreenCaptureKit. It hides the system cursor during capture, stores cursor positions in a sidecar timeline, and exports a rendered video with:

- smoothed cursor overlay
- editable zoom keyframes
- automatic cursor-follow zoom suggestions
- resolution, frame rate, and bitrate controls

## Run

```bash
swift run FocusRecorder
```

macOS will ask for Screen Recording permission the first time it captures. After granting permission, restart the app.

Recordings are saved in `~/Movies/FocusRecorder`.

For a normal app bundle:

```bash
chmod +x scripts/package-app.sh
scripts/package-app.sh
open Build/FocusRecorder.app
```

The package script signs the app bundle as `local.focusrecorder.app` with a stable local designated requirement. macOS tracks Screen Recording permission against that identity.

If permission gets stuck after older unsigned builds:

```bash
scripts/reset-screen-recording-permission.sh
```

Then open the app, grant Screen Recording access once in System Settings, quit, and reopen it.

## Notes

This first version is intentionally personal-tool scoped. Region selection uses numeric coordinates instead of a draggable overlay, and editing is timeline/keyframe based rather than a full video editor.
