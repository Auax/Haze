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

protocol SourceFrameProvider: AnyObject {
    func prepare(asset: AVAsset, trimStart: Double, trimEnd: Double) async throws
    func frame(at sourceTime: Double) throws -> CVPixelBuffer
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
        guard try await asset.loadTracks(withMediaType: .video).first != nil else {
            throw RecorderError.message("The raw recording does not contain a video track.")
        }
        _ = try await asset.load(.duration)
        let outputURL = try Self.makeRenderedOutputURL(for: session, outputDirectory: outputDirectory)

        let trimStart = max(0, session.timelineContentStart)
        let trimEnd = max(trimStart + 0.1, session.timelineContentEnd)
        let visibleDuration = max(0.1, trimEnd - trimStart)
        let fps = max(1, session.settings.frameRate)
        let frameCount = max(1, Int(ceil(visibleDuration * Double(fps))))

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = Int(session.settings.bitrateMbps * 1_000_000)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: session.width,
            AVVideoHeightKey: session.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: session.settings.frameRate,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = CMTimeScale(fps)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: session.width,
            kCVPixelBufferHeightKey as String: session.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else {
            throw RecorderError.message("Could not create the export writer.")
        }
        writer.add(input)

        let audioCopies = try await makeAudioCopies(
            asset: asset,
            writer: writer,
            trimStart: trimStart,
            duration: visibleDuration
        )

        let frameProvider = SequentialAssetFrameProvider()
        try await frameProvider.prepare(asset: asset, trimStart: trimStart, trimEnd: trimEnd)

        guard writer.startWriting() else { throw writer.error ?? RecorderError.message("Could not start export writing.") }
        writer.startSession(atSourceTime: .zero)
        guard adaptor.pixelBufferPool != nil else {
            throw RecorderError.message("Could not create the export pixel buffer pool.")
        }

        let polish = PolishPipeline(session: session, context: context)
        try await writeVideoFrames(
            frameProvider: frameProvider,
            adaptor: adaptor,
            input: input,
            writer: writer,
            polish: polish,
            session: session,
            trimStart: trimStart,
            trimEnd: trimEnd,
            fps: fps,
            frameCount: frameCount
        )
        try await copyAudioTracks(audioCopies, trimStart: trimStart, duration: visibleDuration, writer: writer)
        writer.endSession(atSourceTime: CMTime(seconds: visibleDuration, preferredTimescale: 600))
        await writer.finishWriting()
        switch writer.status {
        case .completed:
            break
        case .failed, .cancelled:
            throw writer.error ?? RecorderError.message("Export writing did not complete.")
        default:
            if let error = writer.error { throw error }
        }
        await MainActor.run {
            self.progress = 1
            self.status = "Exported \(outputURL.lastPathComponent)"
        }
        return outputURL
    }

    private struct AudioCopy {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }

    private final class VideoFrameWritePump: @unchecked Sendable {
        let renderer: ExportRenderer
        let frameProvider: SourceFrameProvider
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let input: AVAssetWriterInput
        let writer: AVAssetWriter
        let polish: PolishPipeline
        let session: RecordingSession
        let trimStart: Double
        let trimEnd: Double
        let fps: Int
        let frameCount: Int
        let pool: CVPixelBufferPool
        let continuation: CheckedContinuation<Void, Error>
        var frameIndex = 0
        var didFinish = false

        init(
            renderer: ExportRenderer,
            frameProvider: SourceFrameProvider,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            input: AVAssetWriterInput,
            writer: AVAssetWriter,
            polish: PolishPipeline,
            session: RecordingSession,
            trimStart: Double,
            trimEnd: Double,
            fps: Int,
            frameCount: Int,
            pool: CVPixelBufferPool,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.renderer = renderer
            self.frameProvider = frameProvider
            self.adaptor = adaptor
            self.input = input
            self.writer = writer
            self.polish = polish
            self.session = session
            self.trimStart = trimStart
            self.trimEnd = trimEnd
            self.fps = fps
            self.frameCount = frameCount
            self.pool = pool
            self.continuation = continuation
        }

        func pump() {
            do {
                while input.isReadyForMoreMediaData && frameIndex < frameCount {
                    try ExportRenderer.checkWriter(writer)
                    let outputTime = Double(frameIndex) / Double(fps)
                    let sourceTime = min(trimEnd, trimStart + outputTime)
                    let sourceFrame = try frameProvider.frame(at: sourceTime)
                    let frameState = RenderFrameStateBuilder.make(
                        session: session,
                        outputTime: outputTime,
                        sourceTime: sourceTime,
                        canvasSize: CGSize(width: session.width, height: session.height)
                    )
                    let processed = renderer.renderFrame(
                        imageBuffer: sourceFrame,
                        state: frameState,
                        session: session,
                        polish: polish,
                        trimStart: trimStart,
                        trimEnd: trimEnd,
                        fps: fps
                    )

                    var outBuffer: CVPixelBuffer?
                    let bufferStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                    guard bufferStatus == kCVReturnSuccess, let outBuffer else {
                        throw RecorderError.message("Could not allocate an export video frame.")
                    }
                    renderer.context.render(processed, to: outBuffer)

                    let outputPTS = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
                    guard adaptor.append(outBuffer, withPresentationTime: outputPTS) else {
                        throw writer.error ?? RecorderError.message("Could not append video frame at \(outputPTS.seconds)s.")
                    }

                    frameIndex += 1
                    let current = min(1, Double(frameIndex) / Double(max(1, frameCount)))
                    Task { @MainActor in
                        self.renderer.progress = current
                        self.renderer.status = "Rendering \(Int(current * 100))%"
                    }
                }

                if frameIndex >= frameCount {
                    finish(.success(()))
                }
            } catch {
                finish(.failure(error))
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard !didFinish else { return }
            didFinish = true
            input.markAsFinished()
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private final class AudioWritePump: @unchecked Sendable {
        let copy: AudioCopy
        let trimStart: Double
        let duration: Double
        let writer: AVAssetWriter
        let continuation: CheckedContinuation<Void, Error>
        var didFinish = false

        init(copy: AudioCopy, trimStart: Double, duration: Double, writer: AVAssetWriter, continuation: CheckedContinuation<Void, Error>) {
            self.copy = copy
            self.trimStart = trimStart
            self.duration = duration
            self.writer = writer
            self.continuation = continuation
        }

        func pump() {
            do {
                while copy.input.isReadyForMoreMediaData {
                    try ExportRenderer.checkWriter(writer)
                    guard let sample = copy.output.copyNextSampleBuffer() else {
                        if copy.reader.status == .failed {
                            throw copy.reader.error ?? RecorderError.message("Audio export failed while reading.")
                        }
                        finish(.success(()))
                        return
                    }

                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let shifted = CMTimeSubtract(
                        pts,
                        CMTime(seconds: trimStart, preferredTimescale: max(pts.timescale, 6000))
                    )
                    let shiftedSeconds = CMTimeGetSeconds(shifted)
                    guard shiftedSeconds >= -0.01 else { continue }
                    guard shiftedSeconds <= duration + 0.01 else {
                        finish(.success(()))
                        return
                    }
                    let presentation = shiftedSeconds < 0 ? .zero : shifted
                    guard let rebased = ExportRenderer.sampleBufferRetimedToPresentation(sample, presentation: presentation) else {
                        throw RecorderError.message("Could not retime an audio sample for export.")
                    }
                    guard copy.input.append(rebased) else {
                        throw writer.error ?? RecorderError.message("Could not append audio sample at \(presentation.seconds)s.")
                    }
                }
            } catch {
                finish(.failure(error))
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard !didFinish else { return }
            didFinish = true
            copy.input.markAsFinished()
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func makeAudioCopies(
        asset: AVAsset,
        writer: AVAssetWriter,
        trimStart: Double,
        duration: Double
    ) async throws -> [AudioCopy] {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        var copies: [AudioCopy] = []
        for audioTrack in audioTracks {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)

            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions.first
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            copies.append(AudioCopy(reader: reader, output: output, input: input))
        }
        return copies
    }

    private func writeVideoFrames(
        frameProvider: SourceFrameProvider,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        polish: PolishPipeline,
        session: RecordingSession,
        trimStart: Double,
        trimEnd: Double,
        fps: Int,
        frameCount: Int
    ) async throws {
        guard let pool = adaptor.pixelBufferPool else {
            throw RecorderError.message("Could not create the export pixel buffer pool.")
        }

        let queue = DispatchQueue(label: "FocusRecorder.Export.VideoWriter", qos: .userInitiated)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pump = VideoFrameWritePump(
                renderer: self,
                frameProvider: frameProvider,
                adaptor: adaptor,
                input: input,
                writer: writer,
                polish: polish,
                session: session,
                trimStart: trimStart,
                trimEnd: trimEnd,
                fps: fps,
                frameCount: frameCount,
                pool: pool,
                continuation: continuation
            )
            input.requestMediaDataWhenReady(on: queue) {
                pump.pump()
            }
        }

        try Self.checkWriter(writer)
    }

    private func copyAudioTracks(
        _ audioCopies: [AudioCopy],
        trimStart: Double,
        duration: Double,
        writer: AVAssetWriter
    ) async throws {
        for copy in audioCopies {
            try await copyAudioTrack(copy, trimStart: trimStart, duration: duration, writer: writer)
        }
    }

    private func copyAudioTrack(
        _ copy: AudioCopy,
        trimStart: Double,
        duration: Double,
        writer: AVAssetWriter
    ) async throws {
        guard copy.reader.startReading() else {
            throw copy.reader.error ?? RecorderError.message("Could not start reading audio for export.")
        }

        let queue = DispatchQueue(label: "FocusRecorder.Export.AudioWriter", qos: .userInitiated)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pump = AudioWritePump(
                copy: copy,
                trimStart: trimStart,
                duration: duration,
                writer: writer,
                continuation: continuation
            )
            copy.input.requestMediaDataWhenReady(on: queue) {
                pump.pump()
            }
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
        let output = try await previewCGImage(session: session, time: time)
        return NSImage(cgImage: output, size: NSSize(width: session.width, height: session.height))
    }

    func previewCGImage(session: RecordingSession, time: Double) async throws -> CGImage {
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
        let frameState = RenderFrameStateBuilder.make(
            session: session,
            outputTime: max(0, time - session.timelineContentStart),
            sourceTime: time,
            canvasSize: CGSize(width: session.width, height: session.height)
        )
        let processed = renderFrame(
            sourceImage: normalized,
            state: frameState,
            session: session,
            polish: polish,
            trimStart: session.timelineContentStart,
            trimEnd: session.timelineContentEnd,
            fps: session.settings.frameRate
        )
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

    private func renderFrame(
        imageBuffer: CVPixelBuffer,
        state: RenderFrameState,
        session: RecordingSession,
        polish: PolishPipeline,
        trimStart: Double,
        trimEnd: Double,
        fps: Int
    ) -> CIImage {
        let frameRect = CGRect(x: 0, y: 0, width: session.width, height: session.height)
        let base = CIImage(cvPixelBuffer: imageBuffer).cropped(to: frameRect)
        return renderFrame(
            sourceImage: base,
            state: state,
            session: session,
            polish: polish,
            trimStart: trimStart,
            trimEnd: trimEnd,
            fps: fps
        )
    }

    private func renderFrame(
        sourceImage: CIImage,
        state: RenderFrameState,
        session: RecordingSession,
        polish: PolishPipeline,
        trimStart: Double,
        trimEnd: Double,
        fps: Int
    ) -> CIImage {
        guard shouldApplyMotionBlur(state: state, session: session, fps: fps) else {
            return renderSinglePass(sourceImage: sourceImage, state: state, session: session, polish: polish)
        }

        let strength = state.motionBlurAmount
        let frameDuration = 1.0 / Double(max(1, fps))
        let shutter = frameDuration * min(1.25, 0.20 + strength * 0.45)
        let sampleCount = strength > 1.35 ? 9 : (strength > 0.75 ? 7 : (strength > 0.33 ? 5 : 3))
        let weights = (0..<sampleCount).map { index in
            let unit = sampleCount == 1 ? 0.5 : Double(index) / Double(sampleCount - 1)
            return gaussianWeight(unit: unit, strength: strength)
        }
        let totalWeight = max(0.000_001, weights.reduce(0, +))
        let frameRect = CGRect(x: 0, y: 0, width: session.width, height: session.height)
        var accumulated = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: frameRect)

        for index in 0..<sampleCount {
            let unit = sampleCount == 1 ? 0.5 : Double(index) / Double(sampleCount - 1)
            let offset = (unit - 0.5) * shutter
            let sampleSourceTime = min(max(trimStart, state.sourceTime + offset), trimEnd)
            let sampleState = RenderFrameStateBuilder.make(
                session: session,
                outputTime: max(0, state.outputTime + offset),
                sourceTime: sampleSourceTime,
                canvasSize: state.canvasSize
            )
            let image = renderSinglePass(sourceImage: sourceImage, state: sampleState, session: session, polish: polish)
                .cropped(to: frameRect)
            let weighted = premultipliedWeighted(image, weight: weights[index] / totalWeight)
            let add = CIFilter.additionCompositing()
            add.inputImage = weighted
            add.backgroundImage = accumulated
            accumulated = (add.outputImage ?? accumulated).cropped(to: frameRect)
        }
        return forceOpaque(accumulated)
    }

    private func renderSinglePass(
        sourceImage: CIImage,
        state: RenderFrameState,
        session: RecordingSession,
        polish: PolishPipeline
    ) -> CIImage {
        let frameRect = CGRect(x: 0, y: 0, width: session.width, height: session.height)
        var screen = sourceImage.cropped(to: frameRect)
        for click in state.activeClicks {
            let radius = ExportRippleParams.radius(forElapsed: click.age)
            let alpha = ExportRippleParams.alpha(forElapsed: click.age)
            screen = polish.compositeRipple(over: screen, at: click.position, radius: radius, alpha: alpha)
                .cropped(to: frameRect)
        }
        let transform = framedLayerTransform(state: state, polish: polish)
        let cursorLayer = cursorLayerForExport(session: session, state: state)
        return polish.applyFraming(to: screen, cursorLayer: cursorLayer, transform: transform)
    }

    /// Cursor layer for a single export time (position, shape, pulse, spring match that instant).
    private func cursorLayerForExport(session: RecordingSession, state: RenderFrameState) -> CIImage? {
        guard let cursor = state.cursor
        else { return nil }
        let liftedPosition = CGPoint(
            x: cursor.position.x,
            y: max(0, cursor.position.y - CursorOverlay.renderVerticalLift)
        )
        return CursorOverlay.shared.imageLayer(
            at: liftedPosition,
            scale: cursor.scale,
            sprite: session.settings.cursorSprite,
            settings: session.settings,
            opacity: cursor.opacity,
            shape: cursor.shape,
            springRotation: cursor.rotation,
            canvasHeight: CGFloat(session.height)
        )
    }

    private func shouldApplyMotionBlur(state: RenderFrameState, session: RecordingSession, fps: Int) -> Bool {
        let strength = state.motionBlurAmount
        guard strength > 0.001 else { return false }
        let dt = max(1.0 / Double(max(1, fps)), 0.001)
        let before = RenderFrameStateBuilder.make(
            session: session,
            outputTime: max(0, state.outputTime - dt * 0.5),
            sourceTime: max(0, state.sourceTime - dt * 0.5),
            canvasSize: state.canvasSize
        )
        let after = RenderFrameStateBuilder.make(
            session: session,
            outputTime: state.outputTime + dt * 0.5,
            sourceTime: min(session.approximateDuration, state.sourceTime + dt * 0.5),
            canvasSize: state.canvasSize
        )
        let cameraDelta = hypot(after.cameraCenter.x - before.cameraCenter.x, after.cameraCenter.y - before.cameraCenter.y)
        let zoomDelta = abs(after.zoom - before.zoom)
        let cursorDelta: CGFloat
        if let a = before.cursor?.position, let b = after.cursor?.position {
            cursorDelta = hypot(b.x - a.x, b.y - a.y)
        } else {
            cursorDelta = 0
        }
        let cameraMoving = cameraDelta > 0.35 || zoomDelta > 0.0008
        // Cursor-only blur is visually risky because it currently re-renders the whole scene
        // multiple times just to blur cursor movement. Keep the threshold higher so tiny cursor
        // jitter does not trigger expensive full-frame blur.
        let normalizedStrength = min(max(strength, 0), 1)
        let cursorMoving = cursorDelta > CGFloat(2.0 + (1 - normalizedStrength) * 3.0)

        return cameraMoving || cursorMoving
    }

    private func framedLayerTransform(state: RenderFrameState, polish: PolishPipeline) -> FramedLayerTransform {
        let scale = CGFloat(state.zoom)
        guard scale > 1.001 else { return .identity }

        let zoomCenter = polish.canvasPoint(forVideoPoint: state.cameraCenter)
        let canvasCenter = polish.canvasCenter
        let desiredZoomCenter = CGPoint(
            x: zoomCenter.x + (canvasCenter.x - zoomCenter.x) * state.panAmount,
            y: zoomCenter.y + (canvasCenter.y - zoomCenter.y) * state.panAmount
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
        let w = CGFloat(min(max(weight, 0), 1))

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image

        // Preserve RGB and scale alpha. With premultiplied compositing, this gives
        // weighted contribution without darkening the accumulated result.
        matrix.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
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

    private static func checkWriter(_ writer: AVAssetWriter) throws {
        switch writer.status {
        case .unknown, .writing:
            return
        case .failed:
            throw writer.error ?? RecorderError.message("Export writer failed.")
        case .cancelled:
            throw writer.error ?? RecorderError.message("Export writer was cancelled.")
        case .completed:
            throw RecorderError.message("Export writer finished before all frames were appended.")
        @unknown default:
            throw writer.error ?? RecorderError.message("Export writer entered an unknown state.")
        }
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

final class SequentialAssetFrameProvider: SourceFrameProvider {
    private struct DecodedFrame {
        let time: Double
        let buffer: CVPixelBuffer
    }

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var latestFrame: DecodedFrame?
    private var pendingFrame: DecodedFrame?
    private var didFinish = false

    func prepare(asset: AVAsset, trimStart: Double, trimEnd: Double) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.message("The raw recording does not contain a video track.")
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, trimStart), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.001, trimEnd - trimStart), preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw RecorderError.message("Could not read frames from the raw recording.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecorderError.message("Could not start reading the recording.")
        }

        self.reader = reader
        self.output = output
        self.latestFrame = nil
        self.pendingFrame = readNextFrame()
        self.didFinish = pendingFrame == nil
    }

    func frame(at sourceTime: Double) throws -> CVPixelBuffer {
        guard let reader else {
            throw RecorderError.message("Export frame provider was not prepared.")
        }
        if reader.status == .failed {
            throw reader.error ?? RecorderError.message("Could not decode a source frame.")
        }

        let target = sourceTime + 0.000_001
        if latestFrame == nil, let pendingFrame {
            latestFrame = pendingFrame
            self.pendingFrame = readNextFrame()
            didFinish = self.pendingFrame == nil
        }

        while let pendingFrame, pendingFrame.time <= target {
            latestFrame = pendingFrame
            self.pendingFrame = readNextFrame()
            didFinish = self.pendingFrame == nil
        }

        if let latestFrame {
            return latestFrame.buffer
        }
        if let pendingFrame {
            latestFrame = pendingFrame
            self.pendingFrame = readNextFrame()
            didFinish = self.pendingFrame == nil
            return pendingFrame.buffer
        }
        if didFinish, let latestFrame {
            return latestFrame.buffer
        }
        throw RecorderError.message("Could not decode any source video frames.")
    }

    private func readNextFrame() -> DecodedFrame? {
        guard let output else { return nil }
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample)
        else {
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = CMTimeGetSeconds(pts)
        return DecodedFrame(time: seconds.isFinite ? seconds : 0, buffer: buffer)
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
    let amount = min(max(strength, 0), 2)
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

        backgroundImage = Self.makeBackground(
            style: session.edit.background,
            size: canvasSize,
            imageFit: session.edit.imageFit,
            focusX: session.edit.imageFocusX,
            focusY: session.edit.imageFocusY
        )
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
        let normalizedBase = base.cropped(to: extent)
        let center = CGPoint(x: point.x, y: extent.height - point.y)
        let lineWidth = CGFloat(ExportRippleParams.lineWidth)
        let outer = CGFloat(radius) + lineWidth * 2 + 3
        let rippleExtent = CGRect(
            x: center.x - outer,
            y: center.y - outer,
            width: outer * 2,
            height: outer * 2
        ).intersection(extent)
        guard !rippleExtent.isNull, !rippleExtent.isEmpty else { return normalizedBase }
        let halfLine = lineWidth * 0.5
        let feather: CGFloat = 1.25

        let outerDisk = CIFilter.radialGradient()
        outerDisk.center = center
        outerDisk.radius0 = Float(max(0, CGFloat(radius) + halfLine))
        outerDisk.radius1 = Float(max(0, CGFloat(radius) + halfLine + feather))
        outerDisk.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: alpha)
        outerDisk.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)

        let innerDisk = CIFilter.radialGradient()
        innerDisk.center = center
        innerDisk.radius0 = Float(max(0, CGFloat(radius) - halfLine - feather))
        innerDisk.radius1 = Float(max(0, CGFloat(radius) - halfLine))
        innerDisk.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        innerDisk.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)

        let cutHole = CIFilter.sourceOutCompositing()
        cutHole.inputImage = outerDisk.outputImage?.cropped(to: rippleExtent)
        cutHole.backgroundImage = innerDisk.outputImage?.cropped(to: rippleExtent)
        let overlay = (cutHole.outputImage ?? CIImage.empty()).cropped(to: rippleExtent)
        return overlay.composited(over: normalizedBase).cropped(to: extent)
    }

    // MARK: - Asset builders

    private static func makeBackground(
        style: BackgroundStyle,
        size: CGSize,
        imageFit: BackgroundImageFit = .fill,
        focusX: Double = 0.5,
        focusY: Double = 0.5
    ) -> CIImage {
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
        case .image(let path):
            let target = CGRect(origin: .zero, size: size)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: target)
            guard
                !path.isEmpty,
                let image = CIImage(contentsOf: URL(fileURLWithPath: path)),
                image.extent.width > 0,
                image.extent.height > 0
            else {
                return black
            }
            // Normalize extent to origin so we can place it precisely.
            let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let imgW = normalized.extent.width
            let imgH = normalized.extent.height
            let scale: CGFloat
            switch imageFit {
            case .fill:
                scale = max(size.width / imgW, size.height / imgH)
            case .fit:
                scale = min(size.width / imgW, size.height / imgH)
            }
            let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let scaledW = scaled.extent.width
            let scaledH = scaled.extent.height

            // Core Image's Y axis is bottom-up, but the focus point is expressed top-down.
            let fx = CGFloat(min(max(focusX, 0), 1))
            let fyTopDown = CGFloat(min(max(focusY, 0), 1))
            let fy = 1 - fyTopDown

            let tx: CGFloat
            let ty: CGFloat
            if scaledW >= size.width {
                tx = -(scaledW - size.width) * fx
            } else {
                tx = (size.width - scaledW) * fx
            }
            if scaledH >= size.height {
                ty = -(scaledH - size.height) * fy
            } else {
                ty = (size.height - scaledH) * fy
            }
            let positioned = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
            // For .fit, composite over black so empty margins are filled.
            let composited = positioned.composited(over: black)
            return composited.cropped(to: target)
        }
    }

    private static func makeRoundedMask(size: CGSize, radius: CGFloat) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)

        guard size.width > 0, size.height > 0 else {
            return CIImage.empty()
        }

        let clampedRadius = min(
            max(0, radius),
            min(size.width, size.height) / 2
        )

        if clampedRadius <= 0.001 {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: rect)
        }

        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
                .cropped(to: rect)
        }

        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(clampedRadius, forKey: "inputRadius")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")

        return (filter.outputImage ?? CIImage.empty())
            .cropped(to: rect)
    }

    private static func makeShadow(maskSize: CGSize, radius: CGFloat, strength: Double) -> CIImage {
        let rect = CGRect(origin: .zero, size: maskSize)

        guard maskSize.width > 0, maskSize.height > 0, strength > 0.001 else {
            return CIImage.empty()
        }

        let clampedRadius = min(
            max(0, radius),
            min(maskSize.width, maskSize.height) / 2
        )

        let alpha = CGFloat(min(max(strength, 0), 1)) * 0.55
        let blurRadius = CGFloat(20 + strength * 30)
        let pad = blurRadius * 4 + 12
        let haloRect = rect.insetBy(dx: -pad, dy: -pad)

        let base: CIImage

        if clampedRadius <= 0.001 {
            base = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha))
                .cropped(to: rect)
        } else if let filter = CIFilter(name: "CIRoundedRectangleGenerator") {
            filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
            filter.setValue(clampedRadius, forKey: "inputRadius")
            filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: alpha), forKey: "inputColor")
            base = (filter.outputImage ?? CIImage.empty()).cropped(to: rect)
        } else {
            base = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha))
                .cropped(to: rect)
        }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = base
        blur.radius = Float(blurRadius)

        return (blur.outputImage ?? base)
            .cropped(to: haloRect)
    }
}
