import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation

fileprivate struct FramedLayerTransform {
    static let identity = FramedLayerTransform(affine: .identity)

    var affine: CGAffineTransform

    var isIdentity: Bool {
        affine == .identity
    }
}

final class ExportRenderer: ObservableObject {
    @Published var progress: Double = 0
    @Published var isRendering = false
    @Published var status = "Idle"

    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func render(session: RecordingSession, outputDirectory: URL? = nil) async throws -> URL {
        await MainActor.run {
            self.isRendering = true
            self.progress = 0
            self.status = "Preparing export..."
        }
        defer {
            Task { @MainActor in
                self.isRendering = false
            }
        }

        let asset = AVURLAsset(url: session.rawVideoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("The raw recording does not contain a video track.")
        }
        _ = try await asset.load(.duration)
        let outputURL = try Self.makeRenderedOutputURL(for: session, outputDirectory: outputDirectory)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(readerOutput) else {
            throw RecorderError.message("Could not read frames from the raw recording.")
        }
        reader.add(readerOutput)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = Int(session.settings.bitrateMbps * 1_000_000)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: session.width,
            AVVideoHeightKey: session.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: session.settings.frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: session.width,
            kCVPixelBufferHeightKey as String: session.height
        ])
        guard writer.canAdd(input) else {
            throw RecorderError.message("Could not create the export writer.")
        }
        writer.add(input)

        var audioCopies: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for audioTrack in audioTracks {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard reader.canAdd(audioOutput) else { continue }
            reader.add(audioOutput)

            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions.first
            )
            guard writer.canAdd(audioInput) else { continue }
            writer.add(audioInput)
            audioCopies.append((audioOutput, audioInput))
        }

        guard reader.startReading() else { throw reader.error ?? RecorderError.message("Could not start reading the recording.") }
        guard writer.startWriting() else { throw writer.error ?? RecorderError.message("Could not start export writing.") }
        writer.startSession(atSourceTime: .zero)

        let polish = PolishPipeline(session: session, context: context)

        let t0 = session.timelineContentStart
        let t1 = session.timelineContentEnd
        let visibleDuration = max(0.1, t1 - t0)

        while let sample = readerOutput.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 4_000_000)
            }
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample),
                  let pool = adaptor.pixelBufferPool
            else { continue }

            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let assetSeconds = CMTimeGetSeconds(pts)
            guard assetSeconds >= t0 - 1e-4 && assetSeconds <= t1 + 1e-2 else { continue }

            let processed = process(
                imageBuffer: imageBuffer,
                time: assetSeconds,
                session: session,
                polish: polish
            )

            var outBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
            guard let outBuffer else { continue }
            context.render(processed, to: outBuffer)
            let outPTS = CMTime(seconds: assetSeconds - t0, preferredTimescale: max(pts.timescale, 600))
            adaptor.append(outBuffer, withPresentationTime: outPTS)

            let current = min(1, (assetSeconds - t0) / visibleDuration)
            await MainActor.run {
                self.progress = current
                self.status = "Rendering \(Int(current * 100))%"
            }
        }

        input.markAsFinished()
        try await copyAudioTracks(audioCopies, session: session)
        await writer.finishWriting()
        if let error = writer.error { throw error }
        await MainActor.run {
            self.progress = 1
            self.status = "Exported \(outputURL.lastPathComponent)"
        }
        return outputURL
    }

    private func copyAudioTracks(
        _ audioCopies: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)],
        session: RecordingSession
    ) async throws {
        let t0 = session.timelineContentStart
        let t1 = session.timelineContentEnd
        for copy in audioCopies {
            while let sample = copy.output.copyNextSampleBuffer() {
                while !copy.input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 4_000_000)
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let sec = CMTimeGetSeconds(pts)
                guard sec >= t0 - 1e-3 && sec <= t1 + 1e-2 else { continue }
                let newPTS = CMTimeSubtract(pts, CMTime(seconds: t0, preferredTimescale: max(pts.timescale, 6000)))
                if let rebased = Self.sampleBufferRetimedToPresentation(sample, presentation: newPTS) {
                    copy.input.append(rebased)
                }
            }
            copy.input.markAsFinished()
        }
    }

    private static func sampleBufferRetimedToPresentation(_ sample: CMSampleBuffer, presentation: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        timing.presentationTimeStamp = presentation
        timing.decodeTimeStamp = presentation
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        guard status == noErr else { return nil }
        return out
    }

    func previewImage(session: RecordingSession, time: Double) async throws -> NSImage {
        let output = try await previewCGImage(session: session, time: time, quality: .previewHighFidelity)
        return NSImage(cgImage: output, size: NSSize(width: session.width, height: session.height))
    }

    func previewCGImage(session: RecordingSession, time: Double, quality: RenderQuality) async throws -> CGImage {
        let asset = AVURLAsset(url: session.rawVideoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0 / Double(max(1, session.settings.frameRate)), preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0 / Double(max(1, session.settings.frameRate)), preferredTimescale: 600)
        let cgImage = try await Self.generatedImage(generator: generator, time: CMTime(seconds: max(0, time), preferredTimescale: 600))
        let source = CIImage(cgImage: cgImage)
        let normalized = source
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(session.width) / max(1, source.extent.width),
                y: CGFloat(session.height) / max(1, source.extent.height)
            ))
            .cropped(to: CGRect(x: 0, y: 0, width: session.width, height: session.height))
        let polish = PolishPipeline(session: session, context: context)
        var screen = normalized
        if session.edit.showClickRipples {
            for click in session.clicks {
                let elapsed = time - click.time
                guard elapsed >= 0, elapsed < ExportRippleParams.window else { continue }
                let radius = ExportRippleParams.radius(forElapsed: elapsed)
                let alpha = ExportRippleParams.alpha(forElapsed: elapsed)
                screen = polish.compositeRipple(over: screen, at: CGPoint(x: click.x, y: click.y), radius: radius, alpha: alpha)
                    .cropped(to: CGRect(x: 0, y: 0, width: session.width, height: session.height))
            }
        }
        let processed = applyFramingWithMotionBlurIfNeeded(to: screen, time: time, session: session, polish: polish)
        guard let output = context.createCGImage(processed, from: CGRect(x: 0, y: 0, width: session.width, height: session.height)) else {
            throw RecorderError.message("Could not render preview frame.")
        }
        return output
    }

    private static func generatedImage(generator: AVAssetImageGenerator, time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? RecorderError.message("Could not read a preview frame."))
                }
            }
        }
    }

    private func process(imageBuffer: CVPixelBuffer, time: Double, session: RecordingSession, polish: PolishPipeline) -> CIImage {
        let frameRect = CGRect(x: 0, y: 0, width: session.width, height: session.height)
        let base = CIImage(cvPixelBuffer: imageBuffer).cropped(to: frameRect)
        var screen = base
        if session.edit.showClickRipples {
            for click in session.clicks {
                let elapsed = time - click.time
                guard elapsed >= 0, elapsed < ExportRippleParams.window else { continue }
                let radius = ExportRippleParams.radius(forElapsed: elapsed)
                let alpha = ExportRippleParams.alpha(forElapsed: elapsed)
                screen = polish.compositeRipple(over: screen, at: CGPoint(x: click.x, y: click.y), radius: radius, alpha: alpha)
                    .cropped(to: frameRect)
            }
        }
        return applyFramingWithMotionBlurIfNeeded(to: screen, time: time, session: session, polish: polish)
    }

    /// Cursor layer for a single export time (position, shape, pulse, spring match that instant).
    private func cursorLayerForExport(session: RecordingSession, time: Double) -> CIImage? {
        guard session.edit.showCursor,
              let cursor = smoothedCursor(
                at: time,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
              )
        else { return nil }
        let shape = cursorShape(at: time, samples: session.cursorShapes)
        let pulse = session.settings.cursorClickPulse
            ? cursorPulseScale(at: time, clicks: session.clicks, strength: session.settings.cursorClickPulseStrength)
            : 1.0
        return CursorOverlay.shared.imageLayer(
            at: cursor,
            scale: CGFloat(session.settings.cursorScale) * pulse,
            sprite: session.settings.cursorSprite,
            settings: session.settings,
            opacity: CGFloat(session.settings.cursorOpacity),
            shape: shape,
            springRotation: cursorSpringRotation(
                at: time,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow,
                strength: session.settings.cursorSpring,
                sprite: session.settings.cursorSprite,
                shape: shape
            ),
            canvasHeight: CGFloat(session.height)
        )
    }

    /// Approximate on-screen cursor speed (pixels/sec) for motion-blur gating.
    private func cursorPixelSpeed(at time: Double, session: RecordingSession) -> Double {
        guard session.edit.showCursor, session.cursorSamples.count >= 2 else { return 0 }
        let frameDuration = 1.0 / Double(max(1, session.settings.frameRate))
        let dt = max(0.004, frameDuration * 0.45)
        let t0 = max(0, time - dt)
        let t1 = min(session.approximateDuration, time + dt)
        guard let a = smoothedCursor(
            at: t0,
            samples: session.cursorSamples,
            smoothing: session.settings.cursorSmoothing,
            window: session.settings.cursorSmoothingWindow
        ),
            let b = smoothedCursor(
                at: t1,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
            )
        else { return 0 }
        return hypot(b.x - a.x, b.y - a.y) / max(0.000_1, t1 - t0)
    }

    private func applyFramingWithMotionBlurIfNeeded(
        to screen: CIImage,
        time: Double,
        session: RecordingSession,
        polish: PolishPipeline
    ) -> CIImage {
        let strength = min(max(session.edit.motionBlur, 0), 1)
        let zoomMoving = activeZoom(at: time, zooms: session.zooms).map { zoomIsMoving(zoom: $0, at: time) } ?? false
        let cursorSpeed = cursorPixelSpeed(at: time, session: session)
        // Threshold scales with motion-blur strength: at strength 1.0 even gentle motion blurs
        // (~80 px/s), at strength 0.1 only fast flicks do (~300 px/s). This keeps idle frames cheap
        // while making the slider's effect on cursor motion clearly visible.
        let cursorThreshold = 320 - 240 * strength
        let cursorMovingFast = cursorSpeed > cursorThreshold
        guard strength > 0.001, zoomMoving || cursorMovingFast else {
            let transform = framedLayerTransform(at: time, session: session, polish: polish)
            let cursorLayer = cursorLayerForExport(session: session, time: time)
            return polish.applyFraming(to: screen, cursorLayer: cursorLayer, transform: transform)
        }

        let frameDuration = 1.0 / Double(max(1, session.settings.frameRate))
        // A short shutter gives a polished camera smear without the heavy ghosting that made the
        // previous multi-sample blur feel mushy during zooms.
        let shutter = min(0.07, frameDuration * (1.2 + strength * 4.0))
        let sampleCount = strength > 0.66 ? 7 : (strength > 0.33 ? 5 : 3)
        let weights = (0..<sampleCount).map { index in
            let unit = sampleCount == 1 ? 0 : Double(index) / Double(sampleCount - 1)
            return gaussianWeight(unit: unit, strength: strength)
        }
        let totalWeight = max(0.000_001, weights.reduce(0, +))

        // Composite using weighted source-over on a black backdrop. Each layer carries premultiplied
        // alpha = weight, so as weights sum to 1 the final pixel restores full RGB without dimming.
        var accumulated: CIImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: session.width, height: session.height))

        for index in 0..<sampleCount {
            let unit = sampleCount == 1 ? 0 : Double(index) / Double(sampleCount - 1)
            let offset = (unit - 0.5) * shutter
            let sampleTime = min(max(0, time + offset), session.approximateDuration)
            let transform = framedLayerTransform(at: sampleTime, session: session, polish: polish)
            let cursorSample = cursorLayerForExport(session: session, time: sampleTime)
            let transformed = polish.applyFraming(to: screen, cursorLayer: cursorSample, transform: transform)
                .cropped(to: CGRect(x: 0, y: 0, width: session.width, height: session.height))
            let weight = weights[index] / totalWeight
            let weighted = premultipliedWeighted(transformed, weight: weight)
            let add = CIFilter.additionCompositing()
            add.inputImage = weighted
            add.backgroundImage = accumulated
            accumulated = (add.outputImage ?? accumulated).cropped(to: CGRect(x: 0, y: 0, width: session.width, height: session.height))
        }
        return forceOpaque(accumulated)
    }

    private func framedLayerTransform(at time: Double, session: RecordingSession, polish: PolishPipeline) -> FramedLayerTransform {
        guard let zoom = activeZoom(at: time, zooms: session.zooms) else { return .identity }
        let t = min(max((time - zoom.start) / max(0.001, zoom.duration), 0), 1)
        let envelope = zoomEnvelope(progress: t, zoom: zoom)
        let scale = CGFloat(pow(zoom.scale, envelope))
        guard scale > 1.001 else { return .identity }

        let zoomCenter = polish.canvasPoint(forVideoPoint: resolvedZoomCenter(for: zoom, time: time, session: session))
        let canvasCenter = polish.canvasCenter
        let panAmount = zoomPanAmount(progress: t, zoom: zoom)
        let desiredZoomCenter = CGPoint(
            x: zoomCenter.x + (canvasCenter.x - zoomCenter.x) * panAmount,
            y: zoomCenter.y + (canvasCenter.y - zoomCenter.y) * panAmount
        )
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: desiredZoomCenter.x - scale * zoomCenter.x,
            ty: desiredZoomCenter.y - scale * zoomCenter.y
        )
        return FramedLayerTransform(affine: transform)
    }

    private func activeZoom(at time: Double, zooms: [ZoomKeyframe]) -> ZoomKeyframe? {
        zooms.first { time >= $0.start && time <= $0.start + $0.duration }
    }

    private func resolvedZoomCenter(for zoom: ZoomKeyframe, time: Double, session: RecordingSession) -> CGPoint {
        cinematicZoomCameraCenter(for: zoom, at: time, session: session)
    }

    private func zoomIsMoving(zoom: ZoomKeyframe, at time: Double) -> Bool {
        let elapsed = min(max(time - zoom.start, 0), zoom.duration)
        let timings = zoomAnimationTimings(for: zoom)
        return elapsed <= timings.zoomIn || elapsed >= zoom.duration - timings.zoomOut
    }

    private func gaussianWeight(unit: Double, strength: Double) -> Double {
        let centered = unit - 0.5
        // Wider sigma keeps the contribution distributed (proper smear) rather than spiking
        // weight on the center sample (which would visually erase the blur).
        let sigma = max(0.25, 0.42 - strength * 0.12)
        return exp(-(centered * centered) / (2 * sigma * sigma))
    }

    /// Returns an image whose RGB channels are unchanged (straight color) and whose alpha is
    /// multiplied by `weight`. Core Image premultiplies before `additionCompositing`, so summing
    /// these layers (with weights normalized to 1) yields premultiplied (sum(RGB·w), 1) — i.e.
    /// the proper motion-blurred frame at full brightness. The original implementation scaled RGB
    /// while leaving alpha at 1, which made the accumulated alpha = N and Core Image then
    /// unpremultiplied by N, producing the near-black image the user reported.
    private func premultipliedWeighted(_ image: CIImage, weight: Double) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        let w = CGFloat(weight)
        matrix.inputImage = image
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: w)
        return matrix.outputImage ?? image
    }

    private func forceOpaque(_ image: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return matrix.outputImage ?? image
    }

    private static func makeRenderedOutputURL(for session: RecordingSession, outputDirectory: URL?) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let baseName = session.rawVideoURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "-raw", with: "-rendered")
        let directory = outputDirectory ?? session.rawVideoURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent("\(baseName)-\(formatter.string(from: Date()))")
            .appendingPathExtension("mp4")
    }
}

func smoothedCursor(
    at time: Double,
    samples: [CursorSample],
    smoothing: Double,
    window: Double = 0.34
) -> CGPoint? {
    guard !samples.isEmpty else { return nil }
    guard let interpolated = interpolatedCursor(at: time, samples: samples) else { return nil }
    let amount = min(max(smoothing, 0), 2)
    guard amount > 0.02 else { return interpolated }

    let windowSeconds = min(max(window, 0.04), 0.9)
    let radius = 0.018 + amount * windowSeconds
    let sigma = max(0.006, radius * 0.42)
    let start = time - radius
    let end = time + radius

    let lowIndex = lowerBound(samples: samples, time: start)
    var totalWeight = 0.0
    var x = 0.0
    var y = 0.0
    var index = lowIndex
    while index < samples.count, samples[index].time <= end {
        let sample = samples[index]
        let d = sample.time - time
        let weight = exp(-(d * d) / (2 * sigma * sigma))
        totalWeight += weight
        x += sample.x * weight
        y += sample.y * weight
        index += 1
    }

    guard totalWeight > 0 else { return interpolated }
    let smoothed = CGPoint(x: x / totalWeight, y: y / totalWeight)
    let blend = min(0.97, amount * 0.78)
    return CGPoint(
        x: interpolated.x + (smoothed.x - interpolated.x) * blend,
        y: interpolated.y + (smoothed.y - interpolated.y) * blend
    )
}

func cursorSpringRotation(
    at time: Double,
    samples: [CursorSample],
    smoothing: Double,
    window: Double = 0.34,
    strength: Double,
    sprite: CursorSprite,
    shape: CursorShape = .default
) -> CGFloat {
    let amount = min(max(strength, 0), 1)
    guard amount > 0.001,
          samples.count >= 2,
          cursorSpringResponse(sprite: sprite, shape: shape) > 0
    else { return 0 }

    let lag = 0.045 + amount * 0.035
    let previousTime = max(0, time - lag)
    guard previousTime < time,
          let current = smoothedCursor(at: time, samples: samples, smoothing: smoothing, window: window),
          let previous = smoothedCursor(at: previousTime, samples: samples, smoothing: smoothing, window: window)
    else { return 0 }

    let dx = current.x - previous.x
    let dy = current.y - previous.y
    let distance = hypot(dx, dy)
    guard distance > 0.25 else { return 0 }

    // Horizontal motion creates the visible "tail lags behind the hotspot" rotation. Vertical
    // motion contributes only to the speed gate, keeping the effect subtle during straight climbs.
    let horizontalShare = dx / max(distance, 0.0001)
    let speed = distance / max(0.001, time - previousTime)
    let speedResponse = smoothstep(edge0: 140, edge1: 1_650, value: speed)
    guard speedResponse > 0.001 else { return 0 }

    let maxAngle = Double.pi / 18 * amount * cursorSpringResponse(sprite: sprite, shape: shape)
    return CGFloat(horizontalShare * speedResponse * maxAngle)
}

private func cursorSpringResponse(sprite: CursorSprite, shape: CursorShape) -> Double {
    switch sprite {
    case .dot, .ring, .spotlight:
        return 0
    case .system:
        switch shape {
        case .type, .drag, .screenshot:
            return 0
        case .zoomIn, .zoomOut:
            return 0.45
        case .default, .pointer, .option:
            return 1
        }
    case .arrow, .custom:
        return 1
    }
}

private func smoothstep(edge0: Double, edge1: Double, value: Double) -> Double {
    guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
    let x = min(max((value - edge0) / (edge1 - edge0), 0), 1)
    return x * x * (3 - 2 * x)
}

private func lowerBound(samples: [CursorSample], time: Double) -> Int {
    var low = 0
    var high = samples.count
    while low < high {
        let mid = (low + high) / 2
        if samples[mid].time < time {
            low = mid + 1
        } else {
            high = mid
        }
    }
    return low
}

private func interpolatedCursor(at time: Double, samples: [CursorSample]) -> CGPoint? {
    guard let first = samples.first else { return nil }
    if time <= first.time { return CGPoint(x: first.x, y: first.y) }
    guard let last = samples.last, time < last.time else {
        let sample = samples.last ?? first
        return CGPoint(x: sample.x, y: sample.y)
    }

    let low = lowerBound(samples: samples, time: time)
    let next = samples[low]
    let previous = samples[max(0, low - 1)]
    let span = max(0.000_001, next.time - previous.time)
    let t = min(max((time - previous.time) / span, 0), 1)
    return CGPoint(
        x: previous.x + (next.x - previous.x) * t,
        y: previous.y + (next.y - previous.y) * t
    )
}

// MARK: - Polish (background, padding, corner radius, shadow, ripples)

final class PolishPipeline {
    let session: RecordingSession
    let context: CIContext
    private let backgroundImage: CIImage
    private let cornerMask: CIImage
    private let shadowImage: CIImage?
    private let videoSize: CGSize
    private let canvasSize: CGSize
    private let framedRect: CGRect
    private let cornerRadiusPx: CGFloat
    private let rendersVideoOnly: Bool
    var canvasCenter: CGPoint {
        CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }

    var framedContentCenter: CGPoint {
        CGPoint(x: framedRect.midX, y: framedRect.midY)
    }

    init(session: RecordingSession, context: CIContext) {
        self.session = session
        self.context = context
        self.canvasSize = CGSize(width: session.width, height: session.height)
        self.rendersVideoOnly = session.edit.background == .none
        let pad = rendersVideoOnly ? 0 : max(0, min(0.18, session.edit.padding))
        let padPx = pad * Double(min(session.width, session.height)) * 1.6
        let availableW = max(40, Double(session.width) - padPx * 2)
        let availableH = max(40, Double(session.height) - padPx * 2)
        let aspect = Double(session.width) / max(1, Double(session.height))
        let frameH = min(availableH, availableW / aspect)
        let frameW = frameH * aspect
        let framedSize = CGSize(width: frameW, height: frameH)
        let frameOriginX = (Double(session.width) - frameW) / 2
        let frameOriginY = (Double(session.height) - frameH) / 2
        self.framedRect = CGRect(x: frameOriginX, y: frameOriginY, width: frameW, height: frameH)
        self.videoSize = framedSize
        let cr = rendersVideoOnly ? 0 : max(0, session.edit.cornerRadius) * Double(min(session.width, session.height)) * 1.4
        self.cornerRadiusPx = CGFloat(cr)

        backgroundImage = Self.makeBackground(style: session.edit.background, size: canvasSize)
        cornerMask = Self.makeRoundedMask(size: framedSize, radius: cornerRadiusPx)
        if !rendersVideoOnly, session.edit.shadow > 0.001 {
            shadowImage = Self.makeShadow(maskSize: framedSize,
                                          radius: cornerRadiusPx,
                                          strength: session.edit.shadow)
        } else {
            shadowImage = nil
        }
    }

    func canvasPoint(forVideoPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: framedRect.minX + point.x / CGFloat(max(1, session.width)) * framedRect.width,
            y: framedRect.maxY - point.y / CGFloat(max(1, session.height)) * framedRect.height
        )
    }

    /// Final framing: places the recording layer onto the canvas, then applies the editor camera
    /// transform to that layer so zooms move the styled screen instead of clipping inside it.
    fileprivate func applyFraming(
        to screen: CIImage,
        cursorLayer: CIImage? = nil,
        transform: FramedLayerTransform = .identity
    ) -> CIImage {
        // Resize content to framed size.
        let sx = videoSize.width / max(1, CGFloat(session.width))
        let sy = videoSize.height / max(1, CGFloat(session.height))
        let rawFrame = CGRect(x: 0, y: 0, width: session.width, height: session.height)
        let resized = screen
            .cropped(to: rawFrame)
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let resizedCursor = cursorLayer?.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        if rendersVideoOnly {
            var layer = resized
            if let resizedCursor {
                layer = resizedCursor.composited(over: layer)
            }
            if !transform.isIdentity {
                layer = layer.transformed(by: transform.affine)
            }
            return layer.cropped(to: CGRect(origin: .zero, size: canvasSize))
        }

        // Apply rounded mask.
        let maskBlend = CIFilter.blendWithMask()
        maskBlend.inputImage = resized
        maskBlend.maskImage = cornerMask
        maskBlend.backgroundImage = CIImage.empty()
        var framed = maskBlend.outputImage ?? resized

        // Translate framed to its position on the canvas.
        framed = framed.transformed(by: CGAffineTransform(translationX: framedRect.minX,
                                                          y: framedRect.minY))
        if !transform.isIdentity {
            framed = framed.transformed(by: transform.affine)
        }

        var cursor: CIImage?
        if let resizedCursor {
            cursor = resizedCursor.transformed(by: CGAffineTransform(translationX: framedRect.minX,
                                                                     y: framedRect.minY))
            if !transform.isIdentity {
                cursor = cursor?.transformed(by: transform.affine)
            }
        }

        var output = backgroundImage
        if let shadowImage {
            let shadowOffsetY = max(2, CGFloat(session.edit.shadow) * 14)
            var shadow = shadowImage.transformed(by: CGAffineTransform(
                translationX: framedRect.minX,
                y: framedRect.minY - shadowOffsetY
            ))
            if !transform.isIdentity {
                shadow = shadow.transformed(by: transform.affine)
            }
            output = shadow.composited(over: output)
        }
        output = framed.composited(over: output)
        if let cursor {
            output = cursor.composited(over: output)
        }
        return output.cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    /// Composite a click ripple in source video coordinates (pre-framing).
    func compositeRipple(over base: CIImage, at point: CGPoint, radius: Double, alpha: Double) -> CIImage {
        let extent = base.extent
        guard extent.width.isFinite,
              extent.height.isFinite,
              extent.width >= 2,
              extent.height >= 2,
              extent.width <= 16_384,
              extent.height <= 16_384,
              point.x.isFinite,
              point.y.isFinite,
              radius.isFinite,
              alpha.isFinite
        else {
            return base
        }
        let canvasW = min(16_384, max(2, Int(extent.width.rounded(.toNearestOrAwayFromZero))))
        let canvasH = min(16_384, max(2, Int(extent.height.rounded(.toNearestOrAwayFromZero))))
        let normalizedBase = base.cropped(to: CGRect(origin: .zero, size: CGSize(width: canvasW, height: canvasH)))
        let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: canvasW,
            pixelsHigh: canvasH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let imageRep else { return base }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: imageRep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()
        let cy = CGFloat(canvasH) - CGFloat(point.y)
        let path = NSBezierPath(ovalIn: NSRect(
            x: point.x - CGFloat(radius),
            y: cy - CGFloat(radius),
            width: CGFloat(radius * 2),
            height: CGFloat(radius * 2)
        ))
        path.lineWidth = ExportRippleParams.lineWidth
        NSColor.white.withAlphaComponent(CGFloat(alpha)).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = imageRep.cgImage else { return normalizedBase }
        let overlay = CIImage(cgImage: cg)
        return overlay.composited(over: normalizedBase)
            .cropped(to: CGRect(origin: .zero, size: CGSize(width: canvasW, height: canvasH)))
    }

    // MARK: - Asset builders

    private static func makeBackground(style: BackgroundStyle, size: CGSize) -> CIImage {
        switch style {
        case .none:
            return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: CGRect(origin: .zero, size: size))
        case .solid(let r, let g, let b):
            let color = CIColor(red: r, green: g, blue: b, alpha: 1)
            return CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
        case .gradient(let top, let bottom):
            let filter = CIFilter.linearGradient()
            // Core Image Y is up. Top of the canvas is y = size.height.
            filter.point0 = CGPoint(x: size.width / 2, y: size.height)
            filter.point1 = CGPoint(x: size.width / 2, y: 0)
            filter.color0 = top.ciColor
            filter.color1 = bottom.ciColor
            return (filter.outputImage ?? CIImage.empty()).cropped(to: CGRect(origin: .zero, size: size))
        }
    }

    private static func makeRoundedMask(size: CGSize, radius: CGFloat) -> CIImage {
        let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: imageRep)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                xRadius: radius,
                                yRadius: radius)
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        return CIImage(cgImage: imageRep.cgImage!)
    }

    private static func makeShadow(maskSize: CGSize, radius: CGFloat, strength: Double) -> CIImage {
        // Build solid shadow tile then blur.
        let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(maskSize.width),
            pixelsHigh: Int(maskSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: imageRep)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: maskSize).fill()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: maskSize),
                                xRadius: radius,
                                yRadius: radius)
        NSColor.black.withAlphaComponent(CGFloat(strength) * 0.55).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let base = CIImage(cgImage: imageRep.cgImage!)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = base
        let blurRadius = Float(20 + strength * 30)
        blur.radius = blurRadius
        guard let blurred = blur.outputImage else { return base }
        // Keep the soft halo: never crop back to the tight mask rect (that was cutting the shadow off).
        let pad = CGFloat(blurRadius) * 4 + 12
        let haloRect = base.extent.insetBy(dx: -pad, dy: -pad)
        return blurred.cropped(to: haloRect)
    }
}
