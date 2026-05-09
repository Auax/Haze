import AppKit
import CoreGraphics

/// Centralized app defaults for user-facing settings and generated timeline values.
///
/// Keep durable defaults here when they affect new recordings, saved sessions, preferences,
/// generated zooms, export styling, or reset buttons. Local view-only spacing/layout constants
/// should stay near the view that owns them.
enum HazeDefaults {
    enum Recording {
        /// Initial capture mode when the app starts before the user picks display/window/region.
        static let captureKind: CaptureKind = .display
        /// Initial output size preset. `.native` keeps the captured source dimensions.
        static let resolutionPreset: ResolutionPreset = .native
        /// Default video encoder target bitrate in megabits per second.
        static let bitrateMbps: Double = 60
        /// Default capture/export frame rate in frames per second.
        static let frameRate: Int = 60
        /// Initial region rectangle used before the user draws a custom capture area.
        static let region = CGRect(x: 120, y: 120, width: 1280, height: 720)

        /// Whether microphone capture is enabled for new recordings.
        static let recordMicrophone = false
        /// Whether ScreenCaptureKit system audio capture is enabled for new recordings.
        static let recordSystemAudio = false
        /// Stored microphone device id. `nil` means use the system/default input.
        static let microphoneDeviceID: String? = nil
    }

    enum Cursor {
        /// Cursor path smoothing strength. 0 is raw cursor data; 2 is very smooth.
        static let smoothing: Double = 1.3
        /// Seconds of neighboring cursor samples considered when smoothing cursor position.
        static let smoothingWindow: Double = 0.34
        /// Cursor tilt amount during fast movement. 0 disables tilt; 2 is strongest.
        static let spring: Double = 2.0
        /// Rendered cursor alpha. 1 is fully opaque.
        static let opacity: Double = 1.0
        /// Whether the cursor briefly grows when a click is detected.
        static let clickPulse = true
        /// Size multiplier for the click pulse. 0 disables visible growth; 1 is strongest.
        static let clickPulseStrength: Double = 0.55
        /// Base rendered cursor size multiplier.
        static let scale: Double = 2.5
        /// Default cursor artwork source. `.system` uses bundled macOS-style cursor SVGs.
        static let sprite: CursorSprite = .system
        /// Minimum seconds a cursor shape must remain active before it is rendered.
        /// Shorter changes are treated as transient hovers and keep the previous stable shape.
        static let shapeChangeMinimumDuration: Double = 0.5
        /// File path for custom cursor artwork. `nil` means no custom image selected.
        static let customPath: String? = nil
        /// Custom cursor hotspot X as a fraction of image width. 0 is left; 1 is right.
        static let customHotspotX: Double = 0.5
        /// Custom cursor hotspot Y as a fraction of image height. 0 is top; 1 is bottom.
        static let customHotspotY: Double = 0.5
    }

    enum AutoZoom {
        /// Whether new recordings generate zooms automatically from clicks/cursor movement.
        static let enabled = true
        /// Default zoom scale used by automatically generated zooms.
        static let scale: Double = 1.4
        /// Whether mouse clicks are recorded and used as the primary auto-zoom signal.
        static let detectClicks = true
        /// Whether keystrokes are recorded and used to extend/smooth auto-zoom timing.
        static let detectKeystrokes = true

        /// Seconds before a click where a generated click zoom starts easing in.
        static let clickPreroll: Double = 1.6
        /// Seconds after the last click where a generated click zoom begins settling out.
        static let clickTrailing: Double = 2.35
        /// Minimum total duration for generated click zoom blocks.
        static let clickMinimumDuration: Double = 3.2
        /// Explicit ease-in/ease-out duration for generated click zooms.
        static let clickRampDuration: Double = 1.55
        /// Timeline ramp handle fraction shown for generated click zooms.
        static let clickRampFraction: Double = 0.33

        /// Seconds before a cursor dwell event where a fallback dwell zoom starts easing in.
        static let dwellPreroll: Double = 0.78
        /// Seconds after a cursor dwell event where a fallback dwell zoom settles out.
        static let dwellTrailing: Double = 1.1
        /// Minimum total duration for generated dwell zoom blocks.
        static let dwellMinimumDuration: Double = 1.6
        /// Timeline ramp handle fraction shown for generated dwell zooms.
        static let dwellRampFraction: Double = 0.36
    }

    enum ManualZoom {
        /// Seconds before a manual zoom marker where the generated zoom starts easing in.
        static let preroll: Double = 1.6
        /// Seconds after a manual zoom marker where the generated zoom settles out.
        static let trailing: Double = 2.4
        /// Minimum total duration for zooms created from manual recording markers.
        static let minimumDuration: Double = 3.2
        /// Explicit ease-in/ease-out duration for manual-marker zooms.
        static let rampDuration: Double = 1.55
        /// Timeline ramp handle fraction shown for manual-marker zooms.
        static let rampFraction: Double = 0.33
    }

    enum NewEditorZoom {
        /// Longest duration for a zoom added from the editor playhead.
        static let maximumDuration: Double = 3.5
        /// Shortest duration for a zoom added from the editor playhead.
        static let minimumDuration: Double = 0.6
        /// Seconds before the playhead where a newly added editor zoom starts.
        static let preroll: Double = 1
    }

    enum ZoomFollow {
        /// Default smoothing when a zoom follows the cursor. 0 is tight; 2 is very smooth.
        static let smoothing: Double = 1.5
        /// Default intentional camera lag, in seconds, when following the cursor.
        static let delay: Double = 0.2
        /// Default horizontal dead zone fraction before cinematic follow starts moving.
        static let deadZoneWidth: Double = 0.35
        /// Default vertical dead zone fraction before cinematic follow starts moving.
        static let deadZoneHeight: Double = 0.30
        /// Default centered-follow anchor X. 0.5 keeps the cursor horizontally centered.
        static let anchorX: Double = 0.5
        /// Default centered-follow anchor Y. 0.5 keeps the cursor vertically centered.
        static let anchorY: Double = 0.5
    }

    enum Easing {
        /// Ramp fraction when the user picks "Snappy" easing.
        static let snappyRampFraction: Double = 0.18
        /// Ramp fraction when the user picks "Smooth" easing.
        static let smoothRampFraction: Double = 0.30
        /// Ramp fraction when the user picks "Gentle" easing.
        static let gentleRampFraction: Double = 0.42
        /// Initial ramp fraction for custom easing curves.
        static let customRampFraction: Double = 0.30

        /// Cubic Bezier curve for fast zooms with a quick settle.
        static let snappyCurve = CubicBezier(x1: 0.18, y1: 0.94, x2: 0.24, y2: 1.0)
        /// Cubic Bezier curve for the standard smooth zoom feel.
        static let smoothCurve = CubicBezier(x1: 0.33, y1: 0.0, x2: 0.20, y2: 1.0)
        /// Cubic Bezier curve for slower, softer zoom motion.
        static let gentleCurve = CubicBezier(x1: 0.45, y1: 0.0, x2: 0.35, y2: 1.0)
    }

    enum Edit {
        /// Default canvas/background behind the recorded screen in rendered exports.
        static let background = BackgroundStyle.gradient(
            top: BackgroundStyle.RGB(red: 0.18, green: 0.19, blue: 0.22),
            bottom: BackgroundStyle.RGB(red: 0.08, green: 0.09, blue: 0.11)
        )
        /// Empty canvas space around the recording as a fraction of the smaller output dimension.
        static let padding: Double = 0.05
        /// Rounded corner amount as a fraction of the smaller output dimension.
        static let cornerRadius: Double = 0.018
        /// Drop shadow strength under the recorded screen. 0 disables it; 1 is strongest.
        static let shadow: Double = 0.55
        /// Whether rendered exports show the cursor by default.
        static let showCursor = true
        /// Whether rendered exports show click ripple effects by default.
        static let showClickRipples = true
        /// Camera/cursor motion blur strength. 0 disables it.
        static let motionBlur: Double = 0
        /// How custom image backgrounds are fit into the export canvas.
        static let imageFit: BackgroundImageFit = .fill
        /// Horizontal crop focus for image backgrounds. 0 is left; 1 is right.
        static let imageFocusX: Double = 0.5
        /// Vertical crop focus for image backgrounds. 0 is top; 1 is bottom.
        static let imageFocusY: Double = 0.5
    }

    enum Preferences {
        /// Whether the floating recorder bar hides while recording.
        static let hideBarWhileRecording = false
        /// Whether the editor opens automatically after a recording stops.
        static let openEditorWhenRecordingStops = true
    }

    enum Hotkeys {
        /// Default key code for marking a zoom while recording. 6 is ANSI Z.
        static let markZoomKeyCode: UInt16 = 6
        /// Default modifiers for marking a zoom while recording.
        static let markZoomModifiers: NSEvent.ModifierFlags = [.control, .option]
        /// Default key code for toggling recording. 15 is ANSI R.
        static let toggleRecordKeyCode: UInt16 = 15
        /// Default modifiers for toggling recording.
        static let toggleRecordModifiers: NSEvent.ModifierFlags = [.control, .option]
        /// Default key code for duplicating selected zooms in the editor. 2 is ANSI D.
        static let duplicateZoomEditorKeyCode: UInt16 = 2
        /// Default modifiers for duplicating selected zooms in the editor.
        static let duplicateZoomEditorModifiers: NSEvent.ModifierFlags = [.control]
        /// Default key code for selecting all zooms in the editor. 0 is ANSI A.
        static let selectAllZoomsEditorKeyCode: UInt16 = 0
        /// Default modifiers for selecting all zooms in the editor.
        static let selectAllZoomsEditorModifiers: NSEvent.ModifierFlags = [.command]
    }
}
