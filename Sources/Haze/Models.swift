import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI

enum CaptureKind: String, CaseIterable, Identifiable, Codable {
    case display = "Display"
    case window = "Window"
    case region = "Region"

    var id: String { rawValue }
}

enum ResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case native = "Native"
    case p1080 = "1080p"
    case p1440 = "1440p"
    case p2160 = "4K"

    var id: String { rawValue }
}

enum CursorSprite: String, Identifiable, Codable {
    case system
    case arrow
    case dot
    case ring
    case spotlight
    case custom

    static let allCases: [CursorSprite] = [.system, .custom]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .custom: return "Custom PNG"
        default: return rawValue.capitalized
        }
    }

    var symbolName: String {
        switch self {
        case .custom: return "photo"
        default: return "cursorarrow"
        }
    }
}

/// Mac OS X Lion cursor shapes. Tracked from `NSCursor.currentSystem` during recording so the
/// rendered video can swap between bundled SVGs as the user hovers over text fields, links, etc.
enum CursorShape: String, CaseIterable, Codable {
    case `default`
    case pointer
    case type
    case drag
    case screenshot
    case option
    case zoomIn = "zoom-in"
    case zoomOut = "zoom-out"

    /// Bundled SVG asset name (without extension).
    var assetName: String {
        switch self {
        case .default: return "default"
        case .pointer: return "handpointing"
        case .type: return "textcursor"
        case .drag: return "handgrabbing"
        case .screenshot: return "screenshotselection"
        case .option: return "copy"
        case .zoomIn: return "zoomin"
        case .zoomOut: return "zoomout"
        }
    }

    /// Hotspot inside the cursor as fractions of its size (0 = top/left, 1 = bottom/right).
    var hotspot: CGPoint {
        switch self {
        case .default, .option:
            return CGPoint(x: 0.325, y: 0.25)
        case .pointer:
            return CGPoint(x: 0.42, y: 0.2)
        case .type:
            return CGPoint(x: 0.5, y: 0.5)
        case .drag:
            return CGPoint(x: 0.5, y: 0.5)
        case .screenshot:
            return CGPoint(x: 0.5, y: 0.5)
        case .zoomIn, .zoomOut:
            return CGPoint(x: 0.42, y: 0.42)
        }
    }
}

struct CursorShapeSample: Codable, Hashable {
    var time: Double
    var shape: CursorShape
}

struct CaptureSource: Identifiable, Hashable {
    let id: String
    let kind: CaptureKind
    let title: String
    let subtitle: String
    let width: Int
    let height: Int
    /// Global AppKit screen-space bounds in points. Used to map cursor samples into video coordinates.
    let frame: CGRect
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct RecordingSettings: Codable {
    var captureKind: CaptureKind = .display
    var resolutionPreset: ResolutionPreset = .native
    var bitrateMbps: Double = 60
    var frameRate: Int = 60
    var region: CGRect = CGRect(x: 120, y: 120, width: 1280, height: 720)
    /// Cursor smoothing strength. 0 = raw, 2 = very smooth.
    var cursorSmoothing: Double = 1.3
    /// Half-window (in seconds) used to weight neighboring cursor samples for smoothing.
    var cursorSmoothingWindow: Double = 0.34
    /// Hotspot-anchored cursor tilt from fast movement. 0 = off, 2 = strongest.
    var cursorSpring: Double = 2.0
    /// Render-time cursor opacity 0...1.
    var cursorOpacity: Double = 1.0
    /// If true, cursor pulses (grows briefly) on each click.
    var cursorClickPulse: Bool = true
    /// Strength of the click pulse 0...1.
    var cursorClickPulseStrength: Double = 0.55
    var cursorScale: Double = 2.5
    var cursorSprite: CursorSprite = .system
    var recordMicrophone: Bool = false
    var microphoneDeviceID: String? = nil
    var recordSystemAudio: Bool = false
    /// Path to a user-supplied image used when `cursorSprite == .custom`.
    var customCursorPath: String? = nil
    /// Hotspot inside the custom cursor as fractions of its size (0,0 = upper-left).
    var customCursorHotspotX: Double = 0.5
    var customCursorHotspotY: Double = 0.5
    var automaticZooms: Bool = true
    var automaticZoomScale: Double = 1.4
    var detectClicks: Bool = true
    var detectKeystrokes: Bool = true

    enum CodingKeys: String, CodingKey {
        case captureKind, resolutionPreset, bitrateMbps, frameRate, region, cursorSmoothing, cursorScale, cursorSprite
        case recordMicrophone, microphoneDeviceID, recordSystemAudio
        case cursorSmoothingWindow, cursorSpring, cursorOpacity, cursorClickPulse, cursorClickPulseStrength
        case customCursorPath, customCursorHotspotX, customCursorHotspotY
        case automaticZooms, automaticZoomScale, detectClicks, detectKeystrokes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let fallback = RecordingSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureKind = try container.decodeIfPresent(CaptureKind.self, forKey: .captureKind) ?? fallback.captureKind
        resolutionPreset = try container.decodeIfPresent(ResolutionPreset.self, forKey: .resolutionPreset) ?? fallback.resolutionPreset
        bitrateMbps = try container.decodeIfPresent(Double.self, forKey: .bitrateMbps) ?? fallback.bitrateMbps
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? fallback.frameRate
        region = try container.decodeIfPresent(CGRect.self, forKey: .region) ?? fallback.region
        cursorSmoothing = try container.decodeIfPresent(Double.self, forKey: .cursorSmoothing) ?? fallback.cursorSmoothing
        cursorSmoothingWindow = try container.decodeIfPresent(Double.self, forKey: .cursorSmoothingWindow) ?? fallback.cursorSmoothingWindow
        cursorSpring = try container.decodeIfPresent(Double.self, forKey: .cursorSpring) ?? fallback.cursorSpring
        cursorOpacity = try container.decodeIfPresent(Double.self, forKey: .cursorOpacity) ?? fallback.cursorOpacity
        cursorClickPulse = try container.decodeIfPresent(Bool.self, forKey: .cursorClickPulse) ?? fallback.cursorClickPulse
        cursorClickPulseStrength = try container.decodeIfPresent(Double.self, forKey: .cursorClickPulseStrength) ?? fallback.cursorClickPulseStrength
        cursorScale = try container.decodeIfPresent(Double.self, forKey: .cursorScale) ?? fallback.cursorScale
        cursorSprite = try container.decodeIfPresent(CursorSprite.self, forKey: .cursorSprite) ?? fallback.cursorSprite
        recordMicrophone = try container.decodeIfPresent(Bool.self, forKey: .recordMicrophone) ?? fallback.recordMicrophone
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        recordSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .recordSystemAudio) ?? fallback.recordSystemAudio
        customCursorPath = try container.decodeIfPresent(String.self, forKey: .customCursorPath)
        customCursorHotspotX = try container.decodeIfPresent(Double.self, forKey: .customCursorHotspotX) ?? fallback.customCursorHotspotX
        customCursorHotspotY = try container.decodeIfPresent(Double.self, forKey: .customCursorHotspotY) ?? fallback.customCursorHotspotY
        automaticZooms = try container.decodeIfPresent(Bool.self, forKey: .automaticZooms) ?? fallback.automaticZooms
        automaticZoomScale = try container.decodeIfPresent(Double.self, forKey: .automaticZoomScale) ?? fallback.automaticZoomScale
        detectClicks = try container.decodeIfPresent(Bool.self, forKey: .detectClicks) ?? fallback.detectClicks
        detectKeystrokes = try container.decodeIfPresent(Bool.self, forKey: .detectKeystrokes) ?? fallback.detectKeystrokes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(captureKind, forKey: .captureKind)
        try container.encode(resolutionPreset, forKey: .resolutionPreset)
        try container.encode(bitrateMbps, forKey: .bitrateMbps)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(region, forKey: .region)
        try container.encode(cursorSmoothing, forKey: .cursorSmoothing)
        try container.encode(cursorSmoothingWindow, forKey: .cursorSmoothingWindow)
        try container.encode(cursorSpring, forKey: .cursorSpring)
        try container.encode(cursorOpacity, forKey: .cursorOpacity)
        try container.encode(cursorClickPulse, forKey: .cursorClickPulse)
        try container.encode(cursorClickPulseStrength, forKey: .cursorClickPulseStrength)
        try container.encode(cursorScale, forKey: .cursorScale)
        try container.encode(cursorSprite, forKey: .cursorSprite)
        try container.encode(recordMicrophone, forKey: .recordMicrophone)
        try container.encodeIfPresent(microphoneDeviceID, forKey: .microphoneDeviceID)
        try container.encode(recordSystemAudio, forKey: .recordSystemAudio)
        try container.encodeIfPresent(customCursorPath, forKey: .customCursorPath)
        try container.encode(customCursorHotspotX, forKey: .customCursorHotspotX)
        try container.encode(customCursorHotspotY, forKey: .customCursorHotspotY)
        try container.encode(automaticZooms, forKey: .automaticZooms)
        try container.encode(automaticZoomScale, forKey: .automaticZoomScale)
        try container.encode(detectClicks, forKey: .detectClicks)
        try container.encode(detectKeystrokes, forKey: .detectKeystrokes)
    }
}

struct CursorSample: Codable, Identifiable {
    var id = UUID()
    var time: Double
    var x: Double
    var y: Double
}

struct MouseClickEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var x: Double
    var y: Double
    var isRightClick: Bool = false
}

struct KeystrokeEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var isModifier: Bool = false
}

enum ZoomEasing: String, Codable, CaseIterable, Identifiable {
    case smooth
    case snappy
    case gentle
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smooth:  return "Smooth"
        case .snappy:  return "Snappy"
        case .gentle:  return "Gentle"
        case .custom:  return "Custom"
        }
    }

    /// Approximate fraction of duration consumed by the ease-in/out ramp.
    var rampFraction: Double {
        switch self {
        case .snappy: return 0.18
        case .smooth: return 0.30
        case .gentle: return 0.42
        case .custom: return 0.30
        }
    }

    var curve: CubicBezier {
        switch self {
        case .snappy:
            return CubicBezier(x1: 0.18, y1: 0.94, x2: 0.24, y2: 1.0)
        case .smooth:
            return CubicBezier(x1: 0.33, y1: 0.0, x2: 0.20, y2: 1.0)
        case .gentle:
            return CubicBezier(x1: 0.45, y1: 0.0, x2: 0.35, y2: 1.0)
        case .custom:
            return .smooth
        }
    }
}

enum CursorFollowStyle: String, Codable, CaseIterable, Identifiable {
    case cinematic
    case centered

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cinematic: return "Cinematic"
        case .centered: return "Cursor centered"
        }
    }
}

struct CubicBezier: Codable, Hashable, Equatable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double

    static let smooth = CubicBezier(x1: 0.33, y1: 0.0, x2: 0.20, y2: 1.0)

    func clamped() -> CubicBezier {
        CubicBezier(
            x1: min(max(x1, 0), 1),
            y1: min(max(y1, 0), 1),
            x2: min(max(x2, 0), 1),
            y2: min(max(y2, 0), 1)
        )
    }

    func value(at progress: Double) -> Double {
        let x = min(max(progress, 0), 1)
        let t = solveT(forX: x)
        return cubic(t, 0, y1, y2, 1)
    }

    private func solveT(forX x: Double) -> Double {
        var t = x
        for _ in 0..<6 {
            let estimate = cubic(t, 0, x1, x2, 1) - x
            let slope = cubicDerivative(t, 0, x1, x2, 1)
            guard abs(slope) > 0.000_001 else { break }
            let next = t - estimate / slope
            if next < 0 || next > 1 { break }
            t = next
        }

        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let estimate = cubic(t, 0, x1, x2, 1)
            if estimate < x {
                low = t
            } else {
                high = t
            }
            t = (low + high) * 0.5
        }
        return t
    }

    private func cubic(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
        let mt = 1 - t
        return mt * mt * mt * p0
            + 3 * mt * mt * t * p1
            + 3 * mt * t * t * p2
            + t * t * t * p3
    }

    private func cubicDerivative(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
        let mt = 1 - t
        return 3 * mt * mt * (p1 - p0)
            + 6 * mt * t * (p2 - p1)
            + 3 * t * t * (p3 - p2)
    }
}

struct ZoomKeyframe: Codable, Identifiable, Hashable {
    static let defaultFollowCursorSmoothing = 1.5
    static let defaultFollowCursorDelay = 0.2

    var id = UUID()
    var start: Double
    var duration: Double
    var scale: Double
    var centerX: Double
    var centerY: Double
    var easing: ZoomEasing = .smooth
    var rampFraction: Double = ZoomEasing.smooth.rampFraction
    var zoomInDuration: Double
    var zoomOutDuration: Double
    var bezier: CubicBezier = .smooth
    var followCursor: Bool = false
    var followCursorStyle: CursorFollowStyle = .cinematic
    /// Time-based smoothing for follow-cursor zoom center tracking. 0 tracks tightly, 2 is very smooth.
    var followCursorSmoothing: Double = Self.defaultFollowCursorSmoothing
    /// Intentional camera lag in seconds while the zoom center follows the cursor.
    var followCursorDelay: Double = Self.defaultFollowCursorDelay
    /// Fraction of the zoomed viewport where the cursor can move before the cinematic camera follows.
    var followCursorDeadZoneWidth: Double = 0.35
    var followCursorDeadZoneHeight: Double = 0.30
    /// Viewport anchor used by centered cursor follow. 0.5,0.5 keeps the cursor visually centered.
    var followCursorAnchorX: Double = 0.5
    var followCursorAnchorY: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case id, start, duration, scale, centerX, centerY, easing, rampFraction, zoomInDuration, zoomOutDuration, bezier
        case followCursor, followCursorStyle, followCursorSmoothing, followCursorDelay
        case followCursorDeadZoneWidth, followCursorDeadZoneHeight, followCursorAnchorX, followCursorAnchorY
    }

    init(
        id: UUID = UUID(),
        start: Double,
        duration: Double,
        scale: Double,
        centerX: Double,
        centerY: Double,
        easing: ZoomEasing = .smooth,
        rampFraction: Double? = nil,
        zoomInDuration: Double? = nil,
        zoomOutDuration: Double? = nil,
        bezier: CubicBezier? = nil,
        followCursor: Bool = false,
        followCursorStyle: CursorFollowStyle = .cinematic,
        followCursorSmoothing: Double = ZoomKeyframe.defaultFollowCursorSmoothing,
        followCursorDelay: Double = ZoomKeyframe.defaultFollowCursorDelay,
        followCursorDeadZoneWidth: Double = 0.35,
        followCursorDeadZoneHeight: Double = 0.30,
        followCursorAnchorX: Double = 0.5,
        followCursorAnchorY: Double = 0.5
    ) {
        self.id = id
        self.start = start
        self.duration = duration
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
        self.easing = easing
        self.rampFraction = rampFraction ?? easing.rampFraction
        let rampDuration = duration * self.rampFraction
        self.zoomInDuration = zoomInDuration ?? rampDuration
        self.zoomOutDuration = zoomOutDuration ?? rampDuration
        self.bezier = (bezier ?? easing.curve).clamped()
        self.followCursor = followCursor
        self.followCursorStyle = followCursorStyle
        self.followCursorSmoothing = min(max(followCursorSmoothing, 0), 2)
        self.followCursorDelay = min(max(followCursorDelay, 0), 0.8)
        self.followCursorDeadZoneWidth = min(max(followCursorDeadZoneWidth, 0.08), 0.92)
        self.followCursorDeadZoneHeight = min(max(followCursorDeadZoneHeight, 0.08), 0.92)
        self.followCursorAnchorX = min(max(followCursorAnchorX, 0.12), 0.88)
        self.followCursorAnchorY = min(max(followCursorAnchorY, 0.12), 0.88)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decode(Double.self, forKey: .start)
        duration = try container.decode(Double.self, forKey: .duration)
        scale = try container.decode(Double.self, forKey: .scale)
        centerX = try container.decode(Double.self, forKey: .centerX)
        centerY = try container.decode(Double.self, forKey: .centerY)
        easing = try container.decodeIfPresent(ZoomEasing.self, forKey: .easing) ?? .smooth
        rampFraction = try container.decodeIfPresent(Double.self, forKey: .rampFraction) ?? easing.rampFraction
        let fallbackRampDuration = duration * rampFraction
        zoomInDuration = try container.decodeIfPresent(Double.self, forKey: .zoomInDuration) ?? fallbackRampDuration
        zoomOutDuration = try container.decodeIfPresent(Double.self, forKey: .zoomOutDuration) ?? fallbackRampDuration
        bezier = (try container.decodeIfPresent(CubicBezier.self, forKey: .bezier) ?? easing.curve).clamped()
        followCursor = try container.decodeIfPresent(Bool.self, forKey: .followCursor) ?? false
        followCursorStyle = try container.decodeIfPresent(CursorFollowStyle.self, forKey: .followCursorStyle) ?? .cinematic
        followCursorSmoothing = min(max(try container.decodeIfPresent(Double.self, forKey: .followCursorSmoothing) ?? Self.defaultFollowCursorSmoothing, 0), 2)
        followCursorDelay = min(max(try container.decodeIfPresent(Double.self, forKey: .followCursorDelay) ?? Self.defaultFollowCursorDelay, 0), 0.8)
        followCursorDeadZoneWidth = min(max(try container.decodeIfPresent(Double.self, forKey: .followCursorDeadZoneWidth) ?? 0.35, 0.08), 0.92)
        followCursorDeadZoneHeight = min(max(try container.decodeIfPresent(Double.self, forKey: .followCursorDeadZoneHeight) ?? 0.30, 0.08), 0.92)
        followCursorAnchorX = min(max(try container.decodeIfPresent(Double.self, forKey: .followCursorAnchorX) ?? 0.5, 0.12), 0.88)
        followCursorAnchorY = min(max(try container.decodeIfPresent(Double.self, forKey: .followCursorAnchorY) ?? 0.5, 0.12), 0.88)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
        try container.encode(scale, forKey: .scale)
        try container.encode(centerX, forKey: .centerX)
        try container.encode(centerY, forKey: .centerY)
        try container.encode(easing, forKey: .easing)
        try container.encode(rampFraction, forKey: .rampFraction)
        try container.encode(zoomInDuration, forKey: .zoomInDuration)
        try container.encode(zoomOutDuration, forKey: .zoomOutDuration)
        try container.encode(bezier, forKey: .bezier)
        try container.encode(followCursor, forKey: .followCursor)
        try container.encode(followCursorStyle, forKey: .followCursorStyle)
        try container.encode(followCursorSmoothing, forKey: .followCursorSmoothing)
        try container.encode(followCursorDelay, forKey: .followCursorDelay)
        try container.encode(followCursorDeadZoneWidth, forKey: .followCursorDeadZoneWidth)
        try container.encode(followCursorDeadZoneHeight, forKey: .followCursorDeadZoneHeight)
        try container.encode(followCursorAnchorX, forKey: .followCursorAnchorX)
        try container.encode(followCursorAnchorY, forKey: .followCursorAnchorY)
    }
}

enum BackgroundStyle: Codable, Equatable {
    case none
    case solid(red: Double, green: Double, blue: Double)
    case gradient(top: RGB, bottom: RGB)
    case image(path: String)

    struct RGB: Codable, Equatable, Hashable {
        var red: Double
        var green: Double
        var blue: Double
    }

    static let presets: [(name: String, style: BackgroundStyle)] = [
        ("Video",     .none),
        ("Graphite",  .gradient(top: RGB(red: 0.18, green: 0.19, blue: 0.22),
                                bottom: RGB(red: 0.08, green: 0.09, blue: 0.11))),
        ("Sunset",    .gradient(top: RGB(red: 0.95, green: 0.45, blue: 0.40),
                                bottom: RGB(red: 0.55, green: 0.20, blue: 0.55))),
        ("Ocean",     .gradient(top: RGB(red: 0.20, green: 0.50, blue: 0.85),
                                bottom: RGB(red: 0.08, green: 0.18, blue: 0.45))),
        ("Forest",    .gradient(top: RGB(red: 0.20, green: 0.45, blue: 0.30),
                                bottom: RGB(red: 0.05, green: 0.18, blue: 0.12))),
        ("Mono",      .solid(red: 0.10, green: 0.10, blue: 0.12)),
        ("Snow",      .solid(red: 0.94, green: 0.94, blue: 0.96)),
        ("Lavender",  .gradient(top: RGB(red: 0.65, green: 0.55, blue: 0.95),
                                bottom: RGB(red: 0.30, green: 0.20, blue: 0.55)))
    ]
}

extension BackgroundStyle.RGB {
    var color: Color { Color(red: red, green: green, blue: blue) }
    var ciColor: CIColor { CIColor(red: red, green: green, blue: blue, alpha: 1) }
}

enum BackgroundImageFit: String, Codable, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit:  return "Fit"
        }
    }
}

struct EditSettings: Codable, Equatable {
    var background: BackgroundStyle = .gradient(
        top:    BackgroundStyle.RGB(red: 0.18, green: 0.19, blue: 0.22),
        bottom: BackgroundStyle.RGB(red: 0.08, green: 0.09, blue: 0.11)
    )
    /// Padding as a fraction of the smaller output dimension (0...0.18).
    var padding: Double = 0.05
    /// Corner radius as a fraction of the smaller output dimension (0...0.08).
    var cornerRadius: Double = 0.018
    /// Shadow strength 0...1.
    var shadow: Double = 0.55
    var showCursor: Bool = true
    var showClickRipples: Bool = true
    /// Strength of zoom/frame motion blur. 0 disables the effect.
    var motionBlur: Double = 0
    /// How the image background fits into the canvas (fill or fit). Only used for `.image` style.
    var imageFit: BackgroundImageFit = .fill
    /// Horizontal focal point (0 = left, 0.5 = center, 1 = right) for cropping/positioning the image.
    var imageFocusX: Double = 0.5
    /// Vertical focal point (0 = top, 0.5 = center, 1 = bottom) for cropping/positioning the image.
    var imageFocusY: Double = 0.5

    enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, showCursor, showClickRipples, motionBlur,
             imageFit, imageFocusX, imageFocusY
    }

    init() {}

    init(from decoder: Decoder) throws {
        let fallback = EditSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        background = try container.decodeIfPresent(BackgroundStyle.self, forKey: .background) ?? fallback.background
        padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? fallback.padding
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? fallback.cornerRadius
        shadow = try container.decodeIfPresent(Double.self, forKey: .shadow) ?? fallback.shadow
        showCursor = try container.decodeIfPresent(Bool.self, forKey: .showCursor) ?? fallback.showCursor
        showClickRipples = try container.decodeIfPresent(Bool.self, forKey: .showClickRipples) ?? fallback.showClickRipples
        motionBlur = try container.decodeIfPresent(Double.self, forKey: .motionBlur) ?? fallback.motionBlur
        imageFit = try container.decodeIfPresent(BackgroundImageFit.self, forKey: .imageFit) ?? fallback.imageFit
        imageFocusX = try container.decodeIfPresent(Double.self, forKey: .imageFocusX) ?? fallback.imageFocusX
        imageFocusY = try container.decodeIfPresent(Double.self, forKey: .imageFocusY) ?? fallback.imageFocusY
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(background, forKey: .background)
        try container.encode(padding, forKey: .padding)
        try container.encode(cornerRadius, forKey: .cornerRadius)
        try container.encode(shadow, forKey: .shadow)
        try container.encode(showCursor, forKey: .showCursor)
        try container.encode(showClickRipples, forKey: .showClickRipples)
        try container.encode(motionBlur, forKey: .motionBlur)
        try container.encode(imageFit, forKey: .imageFit)
        try container.encode(imageFocusX, forKey: .imageFocusX)
        try container.encode(imageFocusY, forKey: .imageFocusY)
    }
}

struct RecordingSession: Codable, Identifiable {
    var id = UUID()
    var createdAt: Date
    var rawVideoURL: URL
    var timelineURL: URL
    var renderedVideoURL: URL?
    var exportDirectoryURL: URL?
    var width: Int
    var height: Int
    var settings: RecordingSettings
    var cursorSamples: [CursorSample]
    var zooms: [ZoomKeyframe]
    var clicks: [MouseClickEvent] = []
    var keystrokes: [KeystrokeEvent] = []
    var cursorShapes: [CursorShapeSample] = []
    var edit: EditSettings = EditSettings()
    /// Recording's actual on-disk duration (set after stop). Falls back to last cursor sample if zero.
    var measuredDuration: Double = 0
    /// Seconds trimmed from the beginning of the timeline (zoom/cursor times stay absolute).
    var timelineTrimStart: Double = 0
    /// Seconds trimmed from the end of the timeline.
    var timelineTrimEnd: Double = 0

    var approximateDuration: Double {
        if measuredDuration > 0.1 { return measuredDuration }
        return max(cursorSamples.last?.time ?? 0, zooms.map { $0.start + $0.duration }.max() ?? 0)
    }

    /// Absolute time where exported / edited playback begins.
    var timelineContentStart: Double { timelineTrimStart }

    /// Absolute time where exported / edited playback ends (exclusive upper bound uses same units as cursor/zoom times).
    var timelineContentEnd: Double {
        max(timelineContentStart + 0.1, approximateDuration - timelineTrimEnd)
    }

    /// Length of the edited clip on the timeline.
    var timelineVisibleDuration: Double {
        max(0.1, timelineContentEnd - timelineContentStart)
    }

    mutating func normalizeTimelineTrims(minVisible: Double = 0.12) {
        let d = max(0.2, approximateDuration)
        timelineTrimStart = min(max(0, timelineTrimStart), d - minVisible)
        let maxEndTrim = max(0, d - timelineTrimStart - minVisible)
        timelineTrimEnd = min(max(0, timelineTrimEnd), maxEndTrim)
    }
}

extension CGSize {
    var integralEven: CGSize {
        CGSize(width: max(2, (Int(width) / 2) * 2), height: max(2, (Int(height) / 2) * 2))
    }
}

extension RecordingSettings {
    func outputSize(for source: CaptureSource?) -> CGSize {
        let native = CGSize(width: source?.width ?? Int(region.width), height: source?.height ?? Int(region.height))
        switch resolutionPreset {
        case .native:
            return native.integralEven
        case .p1080:
            return scaled(native, maxHeight: 1080)
        case .p1440:
            return scaled(native, maxHeight: 1440)
        case .p2160:
            return scaled(native, maxHeight: 2160)
        }
    }

    private func scaled(_ native: CGSize, maxHeight: CGFloat) -> CGSize {
        let ratio = maxHeight / native.height
        return CGSize(width: native.width * ratio, height: native.height * ratio).integralEven
    }
}

func zoomEnvelope(progress: Double, zoom: ZoomKeyframe) -> Double {
    let p = min(max(progress, 0), 1)
    let curve = zoom.easing == .custom ? zoom.bezier.clamped() : zoom.easing.curve
    let timings = zoomAnimationTimings(for: zoom)
    let elapsed = p * max(0.001, zoom.duration)
    if elapsed <= timings.zoomIn {
        return curve.value(at: elapsed / max(0.001, timings.zoomIn))
    }
    let outStart = max(0, zoom.duration - timings.zoomOut)
    if elapsed >= outStart {
        return curve.value(at: (zoom.duration - elapsed) / max(0.001, timings.zoomOut))
    }
    return 1
}

func zoomCenterEnvelope(progress: Double, zoom: ZoomKeyframe) -> Double {
    let p = min(max(progress, 0), 1)
    let curve = zoom.easing == .custom ? zoom.bezier.clamped() : zoom.easing.curve
    let timings = zoomAnimationTimings(for: zoom)
    let elapsed = p * max(0.001, zoom.duration)
    if elapsed <= timings.zoomIn {
        return curve.value(at: elapsed / max(0.001, timings.zoomIn))
    }
    return 1
}

func zoomPanAmount(progress: Double, zoom: ZoomKeyframe) -> CGFloat {
    CGFloat(zoomEnvelope(progress: progress, zoom: zoom))
}

func zoomAnimationTimings(for zoom: ZoomKeyframe) -> (zoomIn: Double, zoomOut: Double) {
    let duration = max(0.001, zoom.duration)
    var zoomIn = min(max(0.08, zoom.zoomInDuration), duration)
    var zoomOut = min(max(0.08, zoom.zoomOutDuration), duration)
    if zoomIn + zoomOut > duration {
        let factor = duration / max(0.001, zoomIn + zoomOut)
        zoomIn *= factor
        zoomOut *= factor
    }
    return (zoomIn, zoomOut)
}

func cinematicZoomCameraCenter(for zoom: ZoomKeyframe, at time: Double, session: RecordingSession) -> CGPoint {
    guard zoom.followCursor else {
        return clampedCameraCenter(
            CGPoint(x: zoom.centerX, y: zoom.centerY),
            screenWidth: Double(session.width),
            screenHeight: Double(session.height),
            zoomScale: zoomScale(for: zoom, at: time)
        )
    }

    let screenWidth = Double(session.width)
    let screenHeight = Double(session.height)
    let startTime = max(0, zoom.start)
    let endTime = min(max(time, startTime), zoom.start + zoom.duration)
    guard endTime > startTime else {
        return clampedCameraCenter(
            CGPoint(x: zoom.centerX, y: zoom.centerY),
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            zoomScale: zoomScale(for: zoom, at: startTime)
        )
    }

    let frameRate = Double(max(30, min(120, session.settings.frameRate)))
    let step = 1.0 / frameRate
    let followSpeed = cinematicFollowSpeed(forSmoothing: zoom.followCursorSmoothing)
    var camera = clampedCameraCenter(
        CGPoint(x: zoom.centerX, y: zoom.centerY),
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoomScale(for: zoom, at: startTime)
    )
    var currentTime = startTime

    while currentTime < endTime - 0.000_001 {
        let nextTime = min(endTime, currentTime + step)
        let dt = nextTime - currentTime
        let scale = zoomScale(for: zoom, at: nextTime)
        if let cursor = smoothedCursor(
            at: max(0, nextTime - zoom.followCursorDelay),
            samples: session.cursorSamples,
            smoothing: zoom.followCursorSmoothing,
            window: session.settings.cursorSmoothingWindow
        ) {
            let current = CameraState(center: camera)
            switch zoom.followCursorStyle {
            case .cinematic:
                camera = updateCamera(
                    current: current,
                    cursor: cursor,
                    zoom: scale,
                    screenSize: CGSize(width: screenWidth, height: screenHeight),
                    dt: dt,
                    followSpeed: followSpeed,
                    deadZoneFraction: CGSize(
                        width: zoom.followCursorDeadZoneWidth,
                        height: zoom.followCursorDeadZoneHeight
                    )
                ).center
            case .centered:
                camera = updateCursorAnchorCamera(
                    current: current,
                    cursor: cursor,
                    zoom: scale,
                    screenSize: CGSize(width: screenWidth, height: screenHeight),
                    dt: dt,
                    followSpeed: followSpeed,
                    anchor: CGPoint(x: zoom.followCursorAnchorX, y: zoom.followCursorAnchorY)
                ).center
            }
        } else {
            camera = clampedCameraCenter(
                camera,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                zoomScale: scale
            )
        }
        currentTime = nextTime
    }

    return clampedCameraCenter(
        camera,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoomScale(for: zoom, at: endTime)
    )
}

struct CameraState {
    var center: CGPoint
    var velocity: CGPoint = .zero
}

func updateCamera(
    current: CameraState,
    cursor: CGPoint?,
    zoom: Double,
    screenSize: CGSize,
    dt: Double,
    followSpeed: Double,
    deadZoneFraction: CGSize = CGSize(width: 0.35, height: 0.30)
) -> CameraState {
    let screenWidth = Double(screenSize.width)
    let screenHeight = Double(screenSize.height)
    let clampedCurrent = clampedCameraCenter(
        current.center,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoom
    )
    guard zoom > 1.001, let cursor else {
        let velocity = CGPoint(
            x: dt > 0 ? (clampedCurrent.x - current.center.x) / dt : 0,
            y: dt > 0 ? (clampedCurrent.y - current.center.y) / dt : 0
        )
        return CameraState(center: clampedCurrent, velocity: velocity)
    }

    let viewWidth = screenWidth / max(zoom, 0.001)
    let viewHeight = screenHeight / max(zoom, 0.001)
    let deadZoneWidth = viewWidth * min(max(Double(deadZoneFraction.width), 0.05), 0.95)
    let deadZoneHeight = viewHeight * min(max(Double(deadZoneFraction.height), 0.05), 0.95)

    var targetX = Double(clampedCurrent.x)
    var targetY = Double(clampedCurrent.y)
    let cursorX = Double(cursor.x)
    let cursorY = Double(cursor.y)
    let left = targetX - deadZoneWidth / 2
    let right = targetX + deadZoneWidth / 2
    let top = targetY - deadZoneHeight / 2
    let bottom = targetY + deadZoneHeight / 2

    if cursorX < left {
        targetX = cursorX + deadZoneWidth / 2
    } else if cursorX > right {
        targetX = cursorX - deadZoneWidth / 2
    }

    if cursorY < top {
        targetY = cursorY + deadZoneHeight / 2
    } else if cursorY > bottom {
        targetY = cursorY - deadZoneHeight / 2
    }

    let target = clampedCameraCenter(
        CGPoint(x: targetX, y: targetY),
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoom
    )
    let alpha = min(max(1 - exp(-followSpeed * max(0, dt)), 0), 1)
    let smoothed = clampedCameraCenter(
        CGPoint(
            x: Double(clampedCurrent.x) + (Double(target.x) - Double(clampedCurrent.x)) * alpha,
            y: Double(clampedCurrent.y) + (Double(target.y) - Double(clampedCurrent.y)) * alpha
        ),
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoom
    )
    let safeDt = max(0.000_001, dt)
    return CameraState(
        center: smoothed,
        velocity: CGPoint(
            x: (Double(smoothed.x) - Double(current.center.x)) / safeDt,
            y: (Double(smoothed.y) - Double(current.center.y)) / safeDt
        )
    )
}

func updateCursorAnchorCamera(
    current: CameraState,
    cursor: CGPoint?,
    zoom: Double,
    screenSize: CGSize,
    dt: Double,
    followSpeed: Double,
    anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
) -> CameraState {
    let screenWidth = Double(screenSize.width)
    let screenHeight = Double(screenSize.height)
    let clampedCurrent = clampedCameraCenter(
        current.center,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoom
    )
    guard zoom > 1.001, let cursor else {
        let velocity = CGPoint(
            x: dt > 0 ? (clampedCurrent.x - current.center.x) / dt : 0,
            y: dt > 0 ? (clampedCurrent.y - current.center.y) / dt : 0
        )
        return CameraState(center: clampedCurrent, velocity: velocity)
    }

    let viewWidth = screenWidth / max(zoom, 0.001)
    let viewHeight = screenHeight / max(zoom, 0.001)
    let anchorX = min(max(Double(anchor.x), 0.02), 0.98)
    let anchorY = min(max(Double(anchor.y), 0.02), 0.98)
    let target = clampedCameraCenter(
        CGPoint(
            x: Double(cursor.x) + (0.5 - anchorX) * viewWidth,
            y: Double(cursor.y) + (0.5 - anchorY) * viewHeight
        ),
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoom
    )
    let alpha = min(max(1 - exp(-followSpeed * max(0, dt)), 0), 1)
    let smoothed = clampedCameraCenter(
        CGPoint(
            x: Double(clampedCurrent.x) + (Double(target.x) - Double(clampedCurrent.x)) * alpha,
            y: Double(clampedCurrent.y) + (Double(target.y) - Double(clampedCurrent.y)) * alpha
        ),
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        zoomScale: zoom
    )
    let safeDt = max(0.000_001, dt)
    return CameraState(
        center: smoothed,
        velocity: CGPoint(
            x: (Double(smoothed.x) - Double(current.center.x)) / safeDt,
            y: (Double(smoothed.y) - Double(current.center.y)) / safeDt
        )
    )
}

func zoomScale(for zoom: ZoomKeyframe, at time: Double) -> Double {
    let progress = min(max((time - zoom.start) / max(0.001, zoom.duration), 0), 1)
    return pow(max(1, zoom.scale), zoomEnvelope(progress: progress, zoom: zoom))
}

private func cinematicCameraStep(
    camera: CGPoint,
    cursor: CGPoint,
    screenWidth: Double,
    screenHeight: Double,
    zoomScale: Double,
    followSpeed: Double,
    dt: Double
) -> CGPoint {
    updateCamera(
        current: CameraState(center: camera),
        cursor: cursor,
        zoom: zoomScale,
        screenSize: CGSize(width: screenWidth, height: screenHeight),
        dt: dt,
        followSpeed: followSpeed
    ).center
}

func clampedCameraCenter(
    _ point: CGPoint,
    screenWidth: Double,
    screenHeight: Double,
    zoomScale: Double
) -> CGPoint {
    guard screenWidth > 0, screenHeight > 0 else { return point }
    let scale = max(zoomScale, 1)
    let viewWidth = screenWidth / scale
    let viewHeight = screenHeight / scale
    let x = clampedCameraAxis(Double(point.x), screenSize: screenWidth, viewSize: viewWidth)
    let y = clampedCameraAxis(Double(point.y), screenSize: screenHeight, viewSize: viewHeight)
    return CGPoint(x: x, y: y)
}

private func clampedCameraAxis(_ value: Double, screenSize: Double, viewSize: Double) -> Double {
    guard screenSize > 0 else { return value }
    guard viewSize < screenSize else { return screenSize / 2 }
    let minValue = viewSize / 2
    let maxValue = screenSize - viewSize / 2
    guard minValue <= maxValue else { return screenSize / 2 }
    return min(max(value, minValue), maxValue)
}

func cinematicFollowSpeed(forSmoothing smoothing: Double) -> Double {
    let amount = min(max(smoothing, 0), 2)
    return 14 - amount * 3
}
