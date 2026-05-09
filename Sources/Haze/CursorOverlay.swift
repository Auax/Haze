import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Pre-positioned cursor sprite used by both the live editor preview and the export pipeline.
/// Sharing a single NSImage between sides guarantees pixel-level identical sprites.
struct CursorSpriteRender {
    /// Rendered cursor sprite (no spring rotation, no opacity baked in).
    let nsImage: NSImage
    /// Size of the sprite in **session pixels**. Match the size you'd see in an exported video at
    /// recording resolution.
    let size: CGSize
    /// Hotspot location measured from the **top-left** of the sprite, in session pixels.
    let hotspotTopLeft: CGPoint
}

/// Internal asset describing a cursor sprite in Core Image space (bottom-up coords).
fileprivate struct CursorSpriteAsset {
    /// Base sprite CIImage, scaled to the requested user scale, without rotation or translation.
    let image: CIImage
    /// Hotspot location in CIImage coordinates (bottom-up), within `image.extent`.
    let hotspotCI: CGPoint
}

final class CursorOverlay {
    static let shared = CursorOverlay()
    static let renderVerticalLift: CGFloat = 10

    private struct CustomKey: Hashable {
        let path: String
        let modificationDate: Date
    }

    private struct SpriteCacheKey: Hashable {
        let sprite: CursorSprite
        let shape: CursorShape
        let scaleHash: Int
        let customPath: String?
        let customHX: Int
        let customHY: Int
    }

    private var customImages: [CustomKey: CIImage] = [:]
    private var spriteRenderCache: [SpriteCacheKey: CursorSpriteRender] = [:]
    private var reportedFailures = Set<String>()
    private let reportedFailuresLock = NSLock()
    private let renderContext = CIContext(options: [.workingColorSpace: NSNull()])

    private init() {}

    func composited(
        over base: CIImage,
        at point: CGPoint,
        scale: CGFloat,
        sprite: CursorSprite,
        settings: RecordingSettings,
        opacity: CGFloat = 1.0,
        shape: CursorShape = .default,
        springRotation: CGFloat = 0
    ) -> CIImage {
        guard let layer = imageLayer(
            at: point,
            scale: scale,
            sprite: sprite,
            settings: settings,
            opacity: opacity,
            shape: shape,
            springRotation: springRotation,
            canvasHeight: base.extent.height
        ) else { return base }
        return layer.composited(over: base)
    }

    func imageLayer(
        at point: CGPoint,
        scale: CGFloat,
        sprite: CursorSprite,
        settings: RecordingSettings,
        opacity: CGFloat = 1.0,
        shape: CursorShape = .default,
        springRotation: CGFloat = 0,
        canvasHeight: CGFloat
    ) -> CIImage? {
        guard let asset = baseSpriteAsset(scale: scale, sprite: sprite, settings: settings, shape: shape) else { return nil }
        let sprung = applySpringRotation(to: asset.image, screenRotation: springRotation, pivot: asset.hotspotCI)
        let positioned = sprung.transformed(by: CGAffineTransform(
            translationX: point.x - asset.hotspotCI.x,
            y: canvasHeight - point.y - asset.hotspotCI.y
        ))
        return applyOpacity(positioned, opacity: opacity)
    }

    /// Renders the same un-rotated sprite the export pipeline uses, returning an `NSImage` and the
    /// hotspot location measured from the top-left of the bitmap. Cached so the editor can call it
    /// every frame cheaply. Spring rotation is intentionally NOT baked in: callers apply it on top
    /// (the export uses a CI affine transform around the hotspot pivot, the editor uses
    /// `.rotationEffect` around the corresponding SwiftUI anchor — both rotate the same content
    /// around the same point and therefore land the hotspot on the same screen pixel).
    func spriteRender(
        scale: CGFloat,
        sprite: CursorSprite,
        settings: RecordingSettings,
        shape: CursorShape = .default
    ) -> CursorSpriteRender? {
        let key = SpriteCacheKey(
            sprite: sprite,
            shape: shape,
            scaleHash: Int((scale * 1000).rounded()),
            customPath: sprite == .custom ? settings.customCursorPath : nil,
            customHX: sprite == .custom ? Int((settings.customCursorHotspotX * 1000).rounded()) : 0,
            customHY: sprite == .custom ? Int((settings.customCursorHotspotY * 1000).rounded()) : 0
        )
        if let cached = spriteRenderCache[key] { return cached }

        guard let asset = baseSpriteAsset(scale: scale, sprite: sprite, settings: settings, shape: shape) else { return nil }
        let extent = asset.image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // Translate to origin so the rendered NSImage starts at (0, 0).
        let zeroed = asset.image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let renderRect = CGRect(origin: .zero, size: extent.size)
        guard let cg = renderContext.createCGImage(zeroed, from: renderRect) else { return nil }
        let nsImage = NSImage(cgImage: cg, size: extent.size)
        // Hotspot in CI coords (bottom-up) within the zeroed image. Convert to top-left origin.
        let hsCIInsideZeroed = CGPoint(x: asset.hotspotCI.x - extent.minX, y: asset.hotspotCI.y - extent.minY)
        let hotspotTL = CGPoint(x: hsCIInsideZeroed.x, y: extent.size.height - hsCIInsideZeroed.y)
        let result = CursorSpriteRender(nsImage: nsImage, size: extent.size, hotspotTopLeft: hotspotTL)
        // Bound cache to a few hundred entries so changing scale/customs in editor doesn't grow forever.
        if spriteRenderCache.count > 256 {
            spriteRenderCache.removeAll(keepingCapacity: true)
        }
        spriteRenderCache[key] = result
        return result
    }

    /// Builds the un-rotated, un-translated sprite shared by `imageLayer` (export) and
    /// `spriteRender` (editor). The returned image's extent has its hotspot at `hotspotCI`.
    fileprivate func baseSpriteAsset(
        scale: CGFloat,
        sprite: CursorSprite,
        settings: RecordingSettings,
        shape: CursorShape
    ) -> CursorSpriteAsset? {
        if sprite == .system {
            guard let image = LionCursorAssets.shared.image(for: shape) else {
                reportCursorAssetFailure(
                    id: "system-\(shape.assetName)",
                    message: "Haze could not load the bundled cursor asset '\(shape.assetName).svg'. The cursor will be hidden until the cursor resources are bundled correctly."
                )
                return nil
            }
            let pixelSize = LionCursorAssets.shared.pixelSize(for: shape)
            // Display each cursor at a uniform on-screen height so different shapes feel
            // consistent despite different SVG viewBox dimensions.
            let displayHeight: CGFloat = 36 * scale
            let displayScale = displayHeight / max(1, pixelSize.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: displayScale, y: displayScale))
            let hot = shape.hotspot
            let scaledW = pixelSize.width * displayScale
            let scaledH = pixelSize.height * displayScale
            // hot.{x,y} are fractions from the top-left of the visible image (SwiftUI convention).
            // CI image extents are bottom-up, so the hotspot's CI-y is (1 - hot.y) * height.
            let hotspotCI = CGPoint(x: hot.x * scaledW, y: (1 - hot.y) * scaledH)
            return CursorSpriteAsset(image: scaled, hotspotCI: hotspotCI)
        }

        if sprite == .custom {
            guard let image = customImage(path: settings.customCursorPath) else {
                reportCursorAssetFailure(
                    id: "custom-\(settings.customCursorPath ?? "missing")",
                    message: "Haze could not load the selected custom cursor image. Choose a valid PNG or switch the cursor sprite back to System."
                )
                return nil
            }
            let displayHeight: CGFloat = 36 * scale
            let sourceH = max(1, image.extent.height)
            let displayScale = displayHeight / sourceH
            let scaled = image.transformed(by: CGAffineTransform(scaleX: displayScale, y: displayScale))
            let scaledW = image.extent.width * displayScale
            let scaledH = sourceH * displayScale
            let hx = min(max(settings.customCursorHotspotX, 0), 1)
            let hy = min(max(settings.customCursorHotspotY, 0), 1)
            let hotspotCI = CGPoint(x: hx * scaledW, y: (1 - hy) * scaledH)
            return CursorSpriteAsset(image: scaled, hotspotCI: hotspotCI)
        }

        // Procedural sprites (legacy, no longer surfaced in the picker).
        reportCursorAssetFailure(
            id: "unsupported-\(sprite.rawValue)",
            message: "Haze no longer supports the legacy '\(sprite.label)' procedural cursor. Switch the cursor sprite to System or choose a custom image."
        )
        return nil
    }

    private func reportCursorAssetFailure(id: String, message: String) {
        reportedFailuresLock.lock()
        let shouldReport = reportedFailures.insert(id).inserted
        reportedFailuresLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .hazeCursorAssetFailed,
                object: nil,
                userInfo: ["message": message]
            )
        }
    }

    private func applySpringRotation(to image: CIImage, screenRotation: CGFloat, pivot: CGPoint) -> CIImage {
        guard abs(screenRotation) > 0.0001 else { return image }
        // CI uses a bottom-left coordinate system, so invert the screen-space angle to match the
        // SwiftUI editor overlay while keeping the hotspot anchored.
        let angle = -screenRotation
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        let transform = CGAffineTransform(
            a: cosAngle,
            b: sinAngle,
            c: -sinAngle,
            d: cosAngle,
            tx: pivot.x - cosAngle * pivot.x + sinAngle * pivot.y,
            ty: pivot.y - sinAngle * pivot.x - cosAngle * pivot.y
        )
        return image.transformed(by: transform)
    }

    private func applyOpacity(_ image: CIImage, opacity: CGFloat) -> CIImage {
        let clamped = max(0, min(1, opacity))
        guard clamped < 0.999 else { return image }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: clamped, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: clamped, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: clamped, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: clamped)
        return matrix.outputImage ?? image
    }

    private func customImage(path: String?) -> CIImage? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        let key = CustomKey(path: path, modificationDate: modDate)
        if let cached = customImages[key] { return cached }
        // Drop entries with the same path but stale modification dates so the cache stays small.
        for entry in customImages.keys where entry.path == path && entry.modificationDate != modDate {
            customImages.removeValue(forKey: entry)
        }
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ciImage = CIImage(cgImage: cg)
        customImages[key] = ciImage
        return ciImage
    }
}

/// Loads a custom cursor image and returns it as an `NSImage` ready for SwiftUI display.
/// Used by the editor's live overlay (CI is used for export).
final class CustomCursorImageCache {
    static let shared = CustomCursorImageCache()
    private var cache: [String: NSImage] = [:]
    private var modificationDates: [String: Date] = [:]
    private init() {}

    func image(for path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        if let existing = cache[path], modificationDates[path] == modDate {
            return existing
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = image
        modificationDates[path] = modDate
        return image
    }
}

/// Returns the cursor click animation multiplier. The cursor eases into a soft press, rebounds
/// slightly, then settles. Close clicks restart the impulse without stacking into a harsh flicker.
func cursorPulseScale(at time: Double, clicks: [MouseClickEvent], strength: Double) -> CGFloat {
    let amount = max(0, min(1, strength))
    guard amount > 0.001 else { return 1 }
    var offset: Double = 0
    let duration = 0.68
    let dipDepth = 0.13 + amount * 0.20
    let rebound = 0.025 + amount * 0.045
    for click in clicks {
        let elapsed = time - click.time
        guard elapsed >= 0, elapsed <= duration else { continue }
        let p = elapsed / duration
        let contribution: Double
        if p < 0.18 {
            contribution = -dipDepth * easeOutCubic(p / 0.18)
        } else if p < 0.52 {
            let u = (p - 0.18) / 0.34
            contribution = -dipDepth + (dipDepth + rebound) * easeOutCubic(u)
        } else {
            let u = (p - 0.52) / 0.48
            contribution = rebound * (1 - easeInOutCubic(u))
        }
        offset += contribution
    }
    return CGFloat(min(max(1 + offset, 1 - dipDepth), 1 + rebound))
}

private func easeOutCubic(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    return 1 - pow(1 - t, 3)
}

private func easeInOutCubic(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    if t < 0.5 {
        return 4 * t * t * t
    }
    return 1 - pow(-2 * t + 2, 3) / 2
}

/// Maps `NSCursor.currentSystem` to a `CursorShape` by comparing the cursor image bytes against
/// the known system cursor instances. Cached to keep sampling cheap (called every cursor frame).
final class CursorShapeDetector {
    static let shared = CursorShapeDetector()

    private struct ShapeMapping {
        let shape: CursorShape
        let signature: Data
    }

    private var signatures: [ShapeMapping] = []
    private var lastBytes: Data?
    private var lastShape: CursorShape = .default
    private var didBuildSignatures = false

    private init() {}

    /// Returns the shape currently displayed system-wide (or `.default` if it can't be matched).
    func currentShape() -> CursorShape {
        buildSignaturesIfNeeded()
        guard let bytes = signature(for: NSCursor.currentSystem) else { return lastShape }
        if let last = lastBytes, last == bytes { return lastShape }
        lastBytes = bytes
        if let match = signatures.first(where: { $0.signature == bytes }) {
            lastShape = match.shape
        } else {
            lastShape = .default
        }
        return lastShape
    }

    private func buildSignaturesIfNeeded() {
        guard !didBuildSignatures else { return }
        didBuildSignatures = true
        let candidates: [(CursorShape, NSCursor)] = [
            (.default, .arrow),
            (.pointer, .pointingHand),
            (.type, .iBeam),
            (.drag, .closedHand),
            (.drag, .openHand),
            (.screenshot, .crosshair)
        ]
        for (shape, cursor) in candidates {
            if let data = signature(for: cursor) {
                signatures.append(ShapeMapping(shape: shape, signature: data))
            }
        }
    }

    private func signature(for cursor: NSCursor?) -> Data? {
        guard let cursor else { return nil }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return nil }
        return tiff
    }
}

/// Loads the bundled Mac OS X Lion cursor SVGs (Resources/Cursors). Caches the CIImage per shape.
final class LionCursorAssets {
    static let shared = LionCursorAssets()
    private var images: [CursorShape: CIImage] = [:]
    private var pixelSizes: [CursorShape: CGSize] = [:]

    private init() {}

    func image(for shape: CursorShape) -> CIImage? {
        if let cached = images[shape] { return cached }
        guard let url = assetURL(for: shape),
              let nsImage = NSImage(contentsOf: url),
              let cg = rasterizedCGImage(from: nsImage)
        else { return nil }
        let ci = CIImage(cgImage: cg)
        images[shape] = ci
        pixelSizes[shape] = CGSize(width: cg.width, height: cg.height)
        return ci
    }

    func nsImage(for shape: CursorShape) -> NSImage? {
        guard let url = assetURL(for: shape) else { return nil }
        return NSImage(contentsOf: url)
    }

    func pixelSize(for shape: CursorShape) -> CGSize {
        if let cached = pixelSizes[shape] { return cached }
        _ = image(for: shape)
        return pixelSizes[shape] ?? CGSize(width: 24, height: 24)
    }

    private func assetURL(for shape: CursorShape) -> URL? {
        Bundle.module.url(forResource: shape.assetName, withExtension: "svg", subdirectory: "Cursors")
            ?? Bundle.main.url(forResource: shape.assetName, withExtension: "svg", subdirectory: "Cursors")
    }

    private func rasterizedCGImage(from image: NSImage) -> CGImage? {
        let imageSize = image.size
        let rasterScale: CGFloat = 8
        let width = max(1, Int(ceil(imageSize.width * rasterScale)))
        let height = max(1, Int(ceil(imageSize.height * rasterScale)))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

/// Returns the cursor shape that was active at the given time during recording.
/// The sample list stores transitions only. Very short cursor-shape segments are ignored so
/// transient hovers do not flash as distracting cursor changes in the rendered video.
func cursorShape(
    at time: Double,
    samples: [CursorShapeSample],
    minimumDuration: Double = HazeDefaults.Cursor.shapeChangeMinimumDuration
) -> CursorShape {
    guard !samples.isEmpty else { return .default }
    let sorted = samples.sorted { $0.time < $1.time }
    let threshold = max(0, minimumDuration)
    var stableShape = sorted.first?.shape ?? .default

    for index in sorted.indices {
        let sample = sorted[index]
        guard sample.time <= time else { break }
        let nextTime = index + 1 < sorted.count ? sorted[index + 1].time : nil
        let segmentEnd = nextTime ?? time
        let segmentDuration = max(0, segmentEnd - sample.time)
        let isCurrentOpenSegment = nextTime == nil

        if segmentDuration >= threshold || (isCurrentOpenSegment && time - sample.time >= threshold) {
            stableShape = sample.shape
        }
    }

    return stableShape
}
