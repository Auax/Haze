import AppKit
import AVFoundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import SwiftUI

struct MetalPreviewHostView: NSViewRepresentable {
    let session: RecordingSession
    let player: AVPlayer
    let enabled: Bool

    func makeNSView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView()
        view.update(session: session, player: player, enabled: enabled)
        return view
    }

    func updateNSView(_ nsView: MetalPreviewView, context: Context) {
        nsView.update(session: session, player: player, enabled: enabled)
    }

    static func dismantleNSView(_ nsView: MetalPreviewView, coordinator: ()) {
        nsView.stop()
    }
}

final class MetalPreviewView: NSView {
    private let fallbackPlayerView = PlayerHostNSView()
    private let mtkView: MTKView?
    private let renderer: MetalPreviewRenderer?
    private var session: RecordingSession?

    override init(frame frameRect: NSRect) {
        if let device = MTLCreateSystemDefaultDevice(),
           let renderer = MetalPreviewRenderer(device: device) {
            let view = MTKView(frame: .zero, device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.framebufferOnly = true
            view.enableSetNeedsDisplay = false
            view.isPaused = false
            view.preferredFramesPerSecond = 60
            view.autoResizeDrawable = true
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.delegate = renderer
            self.mtkView = view
            self.renderer = renderer
        } else {
            self.mtkView = nil
            self.renderer = nil
        }

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        fallbackPlayerView.wantsLayer = true
        fallbackPlayerView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(fallbackPlayerView)
        if let mtkView {
            addSubview(mtkView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        renderer?.detach()
    }

    override func layout() {
        super.layout()
        if let session {
            fallbackPlayerView.frame = Self.framedVideoRect(session: session, in: bounds.size)
        } else {
            fallbackPlayerView.frame = bounds
        }
        mtkView?.frame = bounds
    }

    func update(session: RecordingSession, player: AVPlayer, enabled: Bool) {
        self.session = session
        if fallbackPlayerView.player !== player {
            fallbackPlayerView.player = player
        }
        renderer?.update(session: session)
        renderer?.setPlayer(player)
        renderer?.setEnabled(enabled)
        mtkView?.isPaused = !enabled
        mtkView?.preferredFramesPerSecond = max(30, min(120, session.settings.frameRate))
        needsLayout = true
    }

    func stop() {
        renderer?.setEnabled(false)
        renderer?.detach()
        mtkView?.isPaused = true
    }

    private static func framedVideoRect(session: RecordingSession, in size: CGSize) -> CGRect {
        guard size.width > 1, size.height > 1 else { return .zero }
        let aspect = CGFloat(session.width) / max(1, CGFloat(session.height))
        let videoOnly = session.edit.background == .none
        let clampedPadding = videoOnly ? 0 : max(0, min(0.18, session.edit.padding))
        let pad = CGFloat(clampedPadding) * min(size.width, size.height) * 1.6
        let availableW = max(40, size.width - pad * 2)
        let availableH = max(40, size.height - pad * 2)
        let frameH = min(availableH, availableW / aspect)
        let frameW = frameH * aspect
        return CGRect(
            x: (size.width - frameW) / 2,
            y: (size.height - frameH) / 2,
            width: frameW,
            height: frameH
        )
    }
}

private final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let ripplePipeline: MTLRenderPipelineState
    private let videoSampler: MTLSamplerState
    private let cursorSampler: MTLSamplerState
    private let fullscreenBuffer: MTLBuffer
    private let dynamicQuadBuffer: MTLBuffer
    private let fallbackTexture: MTLTexture
    private let cursorAtlas: MetalCursorAtlas
    private let videoOutput: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    private weak var player: AVPlayer?
    private weak var attachedItem: AVPlayerItem?
    private var lastCVTexture: CVMetalTexture?
    private var lastVideoTexture: MTLTexture?
    private var lastVideoTime: Double?
    private var enabled = true

    private let stateLock = NSLock()
    private var session: RecordingSession?
    private var cameraState: CameraState?
    private var lastZoomID: UUID?
    private var lastMediaTime: Double?
    private var lastHostTime: CFTimeInterval?
    private var lastBlurCameraCenter: CGPoint?
    private var lastBlurTime: Double?

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "previewVertex"),
              let scene = library.makeFunction(name: "sceneFragment"),
              let cursor = library.makeFunction(name: "cursorFragment"),
              let ripple = library.makeFunction(name: "rippleFragment")
        else {
            return nil
        }

        self.commandQueue = queue

        func makePipeline(fragment: MTLFunction, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let scenePipeline = try? makePipeline(fragment: scene, blending: false),
              let cursorPipeline = try? makePipeline(fragment: cursor, blending: true),
              let ripplePipeline = try? makePipeline(fragment: ripple, blending: true)
        else {
            return nil
        }

        self.scenePipeline = scenePipeline
        self.cursorPipeline = cursorPipeline
        self.ripplePipeline = ripplePipeline

        let videoSamplerDescriptor = MTLSamplerDescriptor()
        videoSamplerDescriptor.minFilter = .linear
        videoSamplerDescriptor.magFilter = .linear
        videoSamplerDescriptor.mipFilter = .notMipmapped
        videoSamplerDescriptor.sAddressMode = .clampToEdge
        videoSamplerDescriptor.tAddressMode = .clampToEdge
        guard let videoSampler = device.makeSamplerState(descriptor: videoSamplerDescriptor) else { return nil }
        self.videoSampler = videoSampler

        let cursorSamplerDescriptor = MTLSamplerDescriptor()
        cursorSamplerDescriptor.minFilter = .linear
        cursorSamplerDescriptor.magFilter = .linear
        cursorSamplerDescriptor.mipFilter = .notMipmapped
        cursorSamplerDescriptor.sAddressMode = .clampToEdge
        cursorSamplerDescriptor.tAddressMode = .clampToEdge
        guard let cursorSampler = device.makeSamplerState(descriptor: cursorSamplerDescriptor) else { return nil }
        self.cursorSampler = cursorSampler

        let fullscreenVertices = [
            MetalPreviewVertex(position: SIMD2<Float>(-1,  1), uv: SIMD2<Float>(0, 0)),
            MetalPreviewVertex(position: SIMD2<Float>( 1,  1), uv: SIMD2<Float>(1, 0)),
            MetalPreviewVertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
            MetalPreviewVertex(position: SIMD2<Float>( 1, -1), uv: SIMD2<Float>(1, 1))
        ]
        guard let fullscreenBuffer = device.makeBuffer(
            bytes: fullscreenVertices,
            length: MemoryLayout<MetalPreviewVertex>.stride * fullscreenVertices.count,
            options: [.storageModeShared]
        ),
            let dynamicQuadBuffer = device.makeBuffer(
                length: MemoryLayout<MetalPreviewVertex>.stride * 4,
                options: [.storageModeShared]
            )
        else {
            return nil
        }
        self.fullscreenBuffer = fullscreenBuffer
        self.dynamicQuadBuffer = dynamicQuadBuffer

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = [.shaderRead]
        guard let fallback = device.makeTexture(descriptor: fallbackDescriptor) else { return nil }
        var black: UInt32 = 0xff000000
        fallback.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)
        self.fallbackTexture = fallback

        self.cursorAtlas = MetalCursorAtlas(device: device)
        let outputAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: outputAttributes)

        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    deinit {
        detach()
    }

    func update(session: RecordingSession) {
        stateLock.lock()
        self.session = session
        stateLock.unlock()
    }

    func setPlayer(_ player: AVPlayer?) {
        self.player = player
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            lastMediaTime = nil
            lastHostTime = nil
            lastBlurCameraCenter = nil
            lastBlurTime = nil
        }
    }

    func detach() {
        if let attachedItem {
            attachedItem.remove(videoOutput)
        }
        attachedItem = nil
        lastCVTexture = nil
        lastVideoTexture = nil
        lastVideoTime = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard enabled,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            return
        }

        stateLock.lock()
        let session = self.session
        stateLock.unlock()
        guard let session,
              view.drawableSize.width >= 2,
              view.drawableSize.height >= 2
        else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        attachVideoOutputIfNeeded()
        let hostTime = CACurrentMediaTime()
        let videoFrame = currentVideoFrame(hostTime: hostTime)
        let renderTime = videoFrame.time ?? currentPlayerTime()
        let layout = MetalPreviewLayout(session: session, drawableSize: view.drawableSize)
        let frameState = makeFrameState(session: session, layout: layout, time: renderTime, hostTime: hostTime)
        let videoTexture = videoFrame.texture ?? lastVideoTexture

        if let videoTexture {
            drawScene(
                encoder: encoder,
                texture: videoTexture,
                layout: layout,
                frameState: frameState
            )
        }

        if session.edit.showClickRipples {
            drawRipples(
                encoder: encoder,
                session: session,
                layout: layout,
                frameState: frameState,
                time: renderTime
            )
        }

        if session.edit.showCursor {
            drawCursor(
                encoder: encoder,
                session: session,
                layout: layout,
                frameState: frameState,
                time: renderTime
            )
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func attachVideoOutputIfNeeded() {
        guard let item = player?.currentItem, attachedItem !== item else { return }
        if let attachedItem {
            attachedItem.remove(videoOutput)
        }
        attachedItem = item
        item.add(videoOutput)
        videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        lastCVTexture = nil
        lastVideoTexture = nil
        lastVideoTime = nil
    }

    private func currentVideoFrame(hostTime: CFTimeInterval) -> (texture: MTLTexture?, time: Double?) {
        guard let cache = textureCache else { return (lastVideoTexture, nil) }
        let itemTime = videoOutput.itemTime(forHostTime: hostTime)
        let fallbackTime = player?.currentItem?.currentTime() ?? .zero
        let time = itemTime.isValid ? itemTime : fallbackTime
        guard time.isValid else { return (lastVideoTexture, nil) }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return (lastVideoTexture, nil) }

        let shouldCopy = videoOutput.hasNewPixelBuffer(forItemTime: time)
            || lastVideoTexture == nil
            || lastVideoTime.map { abs($0 - seconds) > 0.002 } ?? true
        guard shouldCopy,
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else {
            return (lastVideoTexture, seconds)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture)
        else {
            return (lastVideoTexture, seconds)
        }
        lastCVTexture = cvTexture
        lastVideoTexture = texture
        lastVideoTime = seconds
        return (texture, seconds)
    }

    private func currentPlayerTime() -> Double {
        guard let time = player?.currentItem?.currentTime() ?? player?.currentTime() else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private func makeFrameState(
        session: RecordingSession,
        layout: MetalPreviewLayout,
        time: Double,
        hostTime: CFTimeInterval
    ) -> MetalPreviewFrame {
        let mediaDt = lastMediaTime.map { time - $0 }
        let hostDt = lastHostTime.map { hostTime - $0 }
        let dt = validFrameDelta(mediaDt) ?? validFrameDelta(hostDt) ?? (1.0 / Double(max(30, session.settings.frameRate)))
        lastMediaTime = time
        lastHostTime = hostTime

        let activeZoom = session.zooms.first { time >= $0.start - 0.001 && time <= $0.start + $0.duration + 0.001 }
        let zoomValue = activeZoom.map { zoomScale(for: $0, at: time) } ?? 1
        let panAmount = activeZoom.map {
            zoomPanAmount(
                progress: min(max((time - $0.start) / max(0.001, $0.duration), 0), 1),
                zoom: $0
            )
        } ?? 0
        let sourceSize = CGSize(width: session.width, height: session.height)
        let cameraCenter = resolveCameraCenter(
            zoom: activeZoom,
            zoomValue: zoomValue,
            session: session,
            time: time,
            sourceSize: sourceSize,
            dt: dt
        )
        let transform = layerTransform(
            layout: layout,
            sourceSize: sourceSize,
            cameraCenter: cameraCenter,
            zoomValue: CGFloat(zoomValue),
            panAmount: panAmount
        )

        let cursor = session.edit.showCursor
            ? smoothedCursor(
                at: time,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
            )
            : nil
        let cursorShape = cursorShape(at: time, samples: session.cursorShapes)
        let cursorPulse = (session.settings.cursorClickPulse && session.edit.showCursor)
            ? cursorPulseScale(at: time, clicks: session.clicks, strength: session.settings.cursorClickPulseStrength)
            : 1
        let cursorRotation = session.edit.showCursor
            ? cursorSpringRotation(
                at: time,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow,
                strength: session.settings.cursorSpring,
                sprite: session.settings.cursorSprite,
                shape: cursorShape
            )
            : 0

        let blurVector = previewBlurVector(
            session: session,
            time: time,
            cameraCenter: cameraCenter,
            dt: dt
        )

        return MetalPreviewFrame(
            time: time,
            zoomValue: CGFloat(zoomValue),
            cameraCenter: cameraCenter,
            transformScale: transform.scale,
            transformTranslate: transform.translate,
            cursorPosition: cursor,
            cursorShape: cursorShape,
            cursorPulse: cursorPulse,
            cursorRotation: cursorRotation,
            blurVectorSource: blurVector
        )
    }

    private func validFrameDelta(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value < 0.20 else { return nil }
        return value
    }

    private func resolveCameraCenter(
        zoom: ZoomKeyframe?,
        zoomValue: Double,
        session: RecordingSession,
        time: Double,
        sourceSize: CGSize,
        dt: Double
    ) -> CGPoint {
        guard let zoom else {
            lastZoomID = nil
            cameraState = nil
            return CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)
        }

        let base = clampedCameraCenter(
            CGPoint(x: zoom.centerX, y: zoom.centerY),
            screenWidth: Double(sourceSize.width),
            screenHeight: Double(sourceSize.height),
            zoomScale: zoomValue
        )

        guard zoom.followCursor else {
            lastZoomID = zoom.id
            cameraState = CameraState(center: base)
            return base
        }

        if lastZoomID != zoom.id || cameraState == nil {
            cameraState = CameraState(center: base)
            lastZoomID = zoom.id
        }

        let cursor = smoothedCursor(
            at: max(0, time - zoom.followCursorDelay),
            samples: session.cursorSamples,
            smoothing: zoom.followCursorSmoothing,
            window: session.settings.cursorSmoothingWindow
        )
        let current = cameraState ?? CameraState(center: base)
        let followSpeed = cinematicFollowSpeed(forSmoothing: zoom.followCursorSmoothing)
        let updated: CameraState
        switch zoom.followCursorStyle {
        case .cinematic:
            updated = updateCamera(
                current: current,
                cursor: cursor,
                zoom: zoomValue,
                screenSize: sourceSize,
                dt: dt,
                followSpeed: followSpeed,
                deadZoneFraction: CGSize(
                    width: zoom.followCursorDeadZoneWidth,
                    height: zoom.followCursorDeadZoneHeight
                )
            )
        case .centered:
            updated = updateCursorAnchorCamera(
                current: current,
                cursor: cursor,
                zoom: zoomValue,
                screenSize: sourceSize,
                dt: dt,
                followSpeed: followSpeed,
                anchor: CGPoint(x: zoom.followCursorAnchorX, y: zoom.followCursorAnchorY)
            )
        }
        cameraState = updated
        return updated.center
    }

    private func layerTransform(
        layout: MetalPreviewLayout,
        sourceSize: CGSize,
        cameraCenter: CGPoint,
        zoomValue: CGFloat,
        panAmount: CGFloat
    ) -> (scale: CGFloat, translate: CGPoint) {
        guard zoomValue > 1.001 else { return (1, .zero) }
        let frame = layout.frameRect
        let framePoint = CGPoint(
            x: frame.minX + cameraCenter.x / max(1, sourceSize.width) * frame.width,
            y: frame.minY + cameraCenter.y / max(1, sourceSize.height) * frame.height
        )
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        let desired = CGPoint(
            x: framePoint.x + (frameCenter.x - framePoint.x) * panAmount,
            y: framePoint.y + (frameCenter.y - framePoint.y) * panAmount
        )
        return (
            zoomValue,
            CGPoint(
                x: desired.x - zoomValue * framePoint.x,
                y: desired.y - zoomValue * framePoint.y
            )
        )
    }

    private func previewBlurVector(
        session: RecordingSession,
        time: Double,
        cameraCenter: CGPoint,
        dt: Double
    ) -> CGPoint {
        defer {
            lastBlurCameraCenter = cameraCenter
            lastBlurTime = time
        }

        guard session.edit.previewMotionBlurEnabled,
              session.edit.motionBlur > 0.001,
              let lastCenter = lastBlurCameraCenter,
              let lastTime = lastBlurTime,
              abs(time - lastTime) < 0.20
        else {
            return .zero
        }

        let safeDt = max(0.000_001, dt)
        let dx = Double(cameraCenter.x - lastCenter.x) / safeDt
        let dy = Double(cameraCenter.y - lastCenter.y) / safeDt
        let speed = hypot(dx, dy)
        guard speed > 80 else { return .zero }
        let strength = min(max(session.edit.motionBlur, 0), 1)
        let pixels = min(8, max(0, (speed - 80) * 0.0045 * strength))
        guard pixels > 0.15 else { return .zero }
        return CGPoint(x: dx / speed * pixels, y: dy / speed * pixels)
    }

    private func drawScene(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        layout: MetalPreviewLayout,
        frameState: MetalPreviewFrame
    ) {
        var uniforms = SceneUniforms(
            drawableSize: SIMD2<Float>(Float(layout.drawableSize.width), Float(layout.drawableSize.height)),
            frameOrigin: SIMD2<Float>(Float(layout.frameRect.minX), Float(layout.frameRect.minY)),
            frameSize: SIMD2<Float>(Float(layout.frameRect.width), Float(layout.frameRect.height)),
            sourceSize: SIMD2<Float>(Float(layout.sourceSize.width), Float(layout.sourceSize.height)),
            transform: SIMD4<Float>(
                Float(frameState.transformScale),
                Float(frameState.transformTranslate.x),
                Float(frameState.transformTranslate.y),
                Float(layout.cornerRadius)
            ),
            backgroundTop: layout.backgroundTop,
            backgroundBottom: layout.backgroundBottom,
            options: SIMD4<Float>(
                Float(layout.backgroundKind),
                Float(min(max(layout.motionBlurEnabled ? hypot(frameState.blurVectorSource.x, frameState.blurVectorSource.y) : 0, 0), 8) / 8),
                Float(frameState.blurVectorSource.x / max(1, layout.sourceSize.width)),
                Float(frameState.blurVectorSource.y / max(1, layout.sourceSize.height))
            )
        )

        encoder.setRenderPipelineState(scenePipeline)
        encoder.setVertexBuffer(fullscreenBuffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(videoSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawRipples(
        encoder: MTLRenderCommandEncoder,
        session: RecordingSession,
        layout: MetalPreviewLayout,
        frameState: MetalPreviewFrame,
        time: Double
    ) {
        encoder.setRenderPipelineState(ripplePipeline)
        encoder.setVertexBuffer(dynamicQuadBuffer, offset: 0, index: 0)
        let ratio = layout.frameRect.width / max(1, layout.sourceSize.width)
        for click in session.clicks {
            let elapsed = time - click.time
            guard elapsed >= 0, elapsed < ExportRippleParams.window else { continue }
            let progress = min(max(elapsed / ExportRippleParams.window, 0), 1)
            let radius = CGFloat(ExportRippleParams.radius(forElapsed: elapsed)) * ratio
            let lineWidth = ExportRippleParams.lineWidth * ratio
            let outer = radius + lineWidth * 2
            let localCenter = CGPoint(
                x: CGFloat(click.x) / max(1, layout.sourceSize.width) * layout.frameRect.width,
                y: CGFloat(click.y) / max(1, layout.sourceSize.height) * layout.frameRect.height
            )
            let rect = CGRect(
                x: layout.frameRect.minX + localCenter.x - outer,
                y: layout.frameRect.minY + localCenter.y - outer,
                width: outer * 2,
                height: outer * 2
            )
            let transformed = transformedRectCorners(
                rect: rect,
                scale: frameState.transformScale,
                translate: frameState.transformTranslate
            )
            writeQuad(corners: transformed, uvRect: CGRect(x: 0, y: 0, width: 1, height: 1), drawableSize: layout.drawableSize)
            var uniforms = RippleUniforms(
                geometry: SIMD4<Float>(
                    Float(rect.width * frameState.transformScale),
                    Float(rect.height * frameState.transformScale),
                    Float(radius * frameState.transformScale),
                    Float(lineWidth * frameState.transformScale)
                ),
                color: SIMD4<Float>(1, 1, 1, Float(max(0, 1 - progress)))
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func drawCursor(
        encoder: MTLRenderCommandEncoder,
        session: RecordingSession,
        layout: MetalPreviewLayout,
        frameState: MetalPreviewFrame,
        time: Double
    ) {
        guard let cursorPosition = frameState.cursorPosition,
              let entry = cursorAtlas.entry(for: session.settings, shape: frameState.cursorShape)
        else {
            return
        }

        encoder.setRenderPipelineState(cursorPipeline)
        encoder.setVertexBuffer(dynamicQuadBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(cursorAtlas.texture, index: 0)
        encoder.setFragmentSamplerState(cursorSampler, index: 0)

        if session.edit.previewMotionBlurEnabled,
           session.edit.motionBlur > 0.001,
           let previous = smoothedCursor(
                at: max(0, time - 1.0 / Double(max(30, session.settings.frameRate))),
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
           ) {
            let distance = hypot(previous.x - cursorPosition.x, previous.y - cursorPosition.y)
            if distance > 3 {
                drawCursorSprite(
                    encoder: encoder,
                    entry: entry,
                    position: previous,
                    opacity: CGFloat(session.settings.cursorOpacity) * CGFloat(session.edit.motionBlur) * 0.16,
                    pulse: 1,
                    rotation: frameState.cursorRotation,
                    layout: layout,
                    frameState: frameState
                )
            }
        }

        drawCursorSprite(
            encoder: encoder,
            entry: entry,
            position: cursorPosition,
            opacity: CGFloat(session.settings.cursorOpacity),
            pulse: frameState.cursorPulse,
            rotation: frameState.cursorRotation,
            layout: layout,
            frameState: frameState
        )
    }

    private func drawCursorSprite(
        encoder: MTLRenderCommandEncoder,
        entry: MetalCursorAtlas.Entry,
        position: CGPoint,
        opacity: CGFloat,
        pulse: CGFloat,
        rotation: CGFloat,
        layout: MetalPreviewLayout,
        frameState: MetalPreviewFrame
    ) {
        let ratio = layout.frameRect.width / max(1, layout.sourceSize.width)
        let size = CGSize(width: entry.size.width * ratio * pulse, height: entry.size.height * ratio * pulse)
        let hotspot = CGPoint(x: entry.hotspot.x * ratio * pulse, y: entry.hotspot.y * ratio * pulse)
        let center = CGPoint(
            x: layout.frameRect.minX + position.x / max(1, layout.sourceSize.width) * layout.frameRect.width,
            y: layout.frameRect.minY + position.y / max(1, layout.sourceSize.height) * layout.frameRect.height
        )
        let unrotated = [
            CGPoint(x: center.x - hotspot.x, y: center.y - hotspot.y),
            CGPoint(x: center.x - hotspot.x + size.width, y: center.y - hotspot.y),
            CGPoint(x: center.x - hotspot.x, y: center.y - hotspot.y + size.height),
            CGPoint(x: center.x - hotspot.x + size.width, y: center.y - hotspot.y + size.height)
        ]
        let rotated = unrotated.map { rotate(point: $0, around: center, radians: rotation) }
        let transformed = rotated.map {
            CGPoint(
                x: $0.x * frameState.transformScale + frameState.transformTranslate.x,
                y: $0.y * frameState.transformScale + frameState.transformTranslate.y
            )
        }
        writeQuad(corners: transformed, uvRect: entry.uvRect, drawableSize: layout.drawableSize)
        var uniforms = SpriteUniforms(options: SIMD4<Float>(Float(max(0, min(1, opacity))), 0, 0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SpriteUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func rotate(point: CGPoint, around pivot: CGPoint, radians: CGFloat) -> CGPoint {
        guard abs(radians) > 0.0001 else { return point }
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        let c = cos(radians)
        let s = sin(radians)
        return CGPoint(
            x: pivot.x + dx * c - dy * s,
            y: pivot.y + dx * s + dy * c
        )
    }

    private func transformedRectCorners(rect: CGRect, scale: CGFloat, translate: CGPoint) -> [CGPoint] {
        [
            CGPoint(x: rect.minX * scale + translate.x, y: rect.minY * scale + translate.y),
            CGPoint(x: rect.maxX * scale + translate.x, y: rect.minY * scale + translate.y),
            CGPoint(x: rect.minX * scale + translate.x, y: rect.maxY * scale + translate.y),
            CGPoint(x: rect.maxX * scale + translate.x, y: rect.maxY * scale + translate.y)
        ]
    }

    private func writeQuad(corners: [CGPoint], uvRect: CGRect, drawableSize: CGSize) {
        guard corners.count == 4 else { return }
        let vertices = dynamicQuadBuffer.contents().bindMemory(to: MetalPreviewVertex.self, capacity: 4)
        let u0 = Float(uvRect.minX)
        let u1 = Float(uvRect.maxX)
        let v0 = Float(uvRect.minY)
        let v1 = Float(uvRect.maxY)
        let uvs = [
            SIMD2<Float>(u0, v0),
            SIMD2<Float>(u1, v0),
            SIMD2<Float>(u0, v1),
            SIMD2<Float>(u1, v1)
        ]
        for index in 0..<4 {
            vertices[index] = MetalPreviewVertex(
                position: normalizedDeviceCoordinate(corners[index], drawableSize: drawableSize),
                uv: uvs[index]
            )
        }
    }

    private func normalizedDeviceCoordinate(_ point: CGPoint, drawableSize: CGSize) -> SIMD2<Float> {
        SIMD2<Float>(
            Float(point.x / max(1, drawableSize.width) * 2 - 1),
            Float(1 - point.y / max(1, drawableSize.height) * 2)
        )
    }
}

private struct MetalPreviewLayout {
    let drawableSize: CGSize
    let sourceSize: CGSize
    let frameRect: CGRect
    let cornerRadius: CGFloat
    let backgroundKind: Int
    let backgroundTop: SIMD4<Float>
    let backgroundBottom: SIMD4<Float>
    let motionBlurEnabled: Bool

    init(session: RecordingSession, drawableSize: CGSize) {
        self.drawableSize = drawableSize
        self.sourceSize = CGSize(width: session.width, height: session.height)
        let aspect = CGFloat(session.width) / max(1, CGFloat(session.height))
        let videoOnly = session.edit.background == .none
        let clampedPadding = videoOnly ? 0 : max(0, min(0.18, session.edit.padding))
        let pad = CGFloat(clampedPadding) * min(drawableSize.width, drawableSize.height) * 1.6
        let availableW = max(40, drawableSize.width - pad * 2)
        let availableH = max(40, drawableSize.height - pad * 2)
        let frameH = min(availableH, availableW / aspect)
        let frameW = frameH * aspect
        self.frameRect = CGRect(
            x: (drawableSize.width - frameW) / 2,
            y: (drawableSize.height - frameH) / 2,
            width: frameW,
            height: frameH
        )
        self.cornerRadius = videoOnly ? 0 : max(0, CGFloat(session.edit.cornerRadius)) * min(frameW, frameH) * 1.4
        self.motionBlurEnabled = session.edit.previewMotionBlurEnabled

        switch session.edit.background {
        case .none:
            self.backgroundKind = 0
            self.backgroundTop = SIMD4<Float>(0, 0, 0, 0)
            self.backgroundBottom = SIMD4<Float>(0, 0, 0, 0)
        case .solid(let r, let g, let b):
            self.backgroundKind = 1
            let color = SIMD4<Float>(Float(r), Float(g), Float(b), 1)
            self.backgroundTop = color
            self.backgroundBottom = color
        case .gradient(let top, let bottom):
            self.backgroundKind = 2
            self.backgroundTop = SIMD4<Float>(Float(top.red), Float(top.green), Float(top.blue), 1)
            self.backgroundBottom = SIMD4<Float>(Float(bottom.red), Float(bottom.green), Float(bottom.blue), 1)
        }
    }
}

private struct MetalPreviewFrame {
    let time: Double
    let zoomValue: CGFloat
    let cameraCenter: CGPoint
    let transformScale: CGFloat
    let transformTranslate: CGPoint
    let cursorPosition: CGPoint?
    let cursorShape: CursorShape
    let cursorPulse: CGFloat
    let cursorRotation: CGFloat
    let blurVectorSource: CGPoint
}

private struct MetalPreviewVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private struct SceneUniforms {
    var drawableSize: SIMD2<Float>
    var frameOrigin: SIMD2<Float>
    var frameSize: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var transform: SIMD4<Float>
    var backgroundTop: SIMD4<Float>
    var backgroundBottom: SIMD4<Float>
    var options: SIMD4<Float>
}

private struct SpriteUniforms {
    var options: SIMD4<Float>
}

private struct RippleUniforms {
    var geometry: SIMD4<Float>
    var color: SIMD4<Float>
}

private final class MetalCursorAtlas {
    struct Entry {
        let uvRect: CGRect
        let size: CGSize
        let hotspot: CGPoint
    }

    private struct Key: Hashable {
        let sprite: String
        let shape: String
        let scaleHash: Int
        let customPath: String?
        let customHX: Int
        let customHY: Int
    }

    let texture: MTLTexture
    private let atlasSize = 2048
    private var entries: [Key: Entry] = [:]
    private var nextX = 1
    private var nextY = 1
    private var rowHeight = 0

    init(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: descriptor)!
        clear()
    }

    func entry(for settings: RecordingSettings, shape: CursorShape) -> Entry? {
        let key = Key(
            sprite: settings.cursorSprite.rawValue,
            shape: shape.rawValue,
            scaleHash: Int((settings.cursorScale * 1000).rounded()),
            customPath: settings.cursorSprite == .custom ? settings.customCursorPath : nil,
            customHX: settings.cursorSprite == .custom ? Int((settings.customCursorHotspotX * 1000).rounded()) : 0,
            customHY: settings.cursorSprite == .custom ? Int((settings.customCursorHotspotY * 1000).rounded()) : 0
        )
        if let entry = entries[key] { return entry }
        guard let render = CursorOverlay.shared.spriteRender(
            scale: CGFloat(settings.cursorScale),
            sprite: settings.cursorSprite,
            settings: settings,
            shape: shape
        ),
            let cgImage = render.nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let bytes = rgbaBytes(from: cgImage)
        else {
            return nil
        }

        let width = max(1, cgImage.width)
        let height = max(1, cgImage.height)
        if width + 2 >= atlasSize || height + 2 >= atlasSize {
            return nil
        }
        if nextX + width + 2 >= atlasSize {
            nextX = 1
            nextY += rowHeight + 2
            rowHeight = 0
        }
        if nextY + height + 2 >= atlasSize {
            entries.removeAll(keepingCapacity: true)
            nextX = 1
            nextY = 1
            rowHeight = 0
            clear()
        }

        let originX = nextX
        let originY = nextY
        texture.replace(
            region: MTLRegionMake2D(originX, originY, width, height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: width * 4
        )
        nextX += width + 2
        rowHeight = max(rowHeight, height)

        let sizeScaleX = CGFloat(width) / max(1, render.size.width)
        let sizeScaleY = CGFloat(height) / max(1, render.size.height)
        let entry = Entry(
            uvRect: CGRect(
                x: CGFloat(originX) / CGFloat(atlasSize),
                y: CGFloat(originY) / CGFloat(atlasSize),
                width: CGFloat(width) / CGFloat(atlasSize),
                height: CGFloat(height) / CGFloat(atlasSize)
            ),
            size: CGSize(width: CGFloat(width) / sizeScaleX, height: CGFloat(height) / sizeScaleY),
            hotspot: CGPoint(x: render.hotspotTopLeft.x, y: render.hotspotTopLeft.y)
        )
        entries[key] = entry
        return entry
    }

    private func clear() {
        let zero = [UInt8](repeating: 0, count: atlasSize * atlasSize * 4)
        texture.replace(
            region: MTLRegionMake2D(0, 0, atlasSize, atlasSize),
            mipmapLevel: 0,
            withBytes: zero,
            bytesPerRow: atlasSize * 4
        )
    }

    private func rgbaBytes(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drew = bytes.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  )
            else {
                return false
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? bytes : nil
    }
}

private extension MetalPreviewRenderer {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 uv;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct SceneUniforms {
        float2 drawableSize;
        float2 frameOrigin;
        float2 frameSize;
        float2 sourceSize;
        float4 transform;
        float4 backgroundTop;
        float4 backgroundBottom;
        float4 options;
    };

    struct SpriteUniforms {
        float4 options;
    };

    struct RippleUniforms {
        float4 geometry;
        float4 color;
    };

    vertex VertexOut previewVertex(uint vertexID [[vertex_id]],
                                   const device VertexIn *vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.uv = vertices[vertexID].uv;
        return out;
    }

    static float roundedRectAlpha(float2 local, float2 size, float radius) {
        if (radius <= 0.001) {
            return all(local >= float2(0.0)) && all(local <= size) ? 1.0 : 0.0;
        }
        float2 halfSize = size * 0.5;
        float2 q = abs(local - halfSize) - (halfSize - float2(radius));
        float distance = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        return 1.0 - smoothstep(-1.0, 1.0, distance);
    }

    fragment half4 sceneFragment(VertexOut in [[stage_in]],
                                 texture2d<half> videoTexture [[texture(0)]],
                                 sampler videoSampler [[sampler(0)]],
                                 constant SceneUniforms &u [[buffer(0)]]) {
        uint backgroundKind = uint(u.options.x + 0.5);
        float4 background = float4(0.0);
        if (backgroundKind == 1u) {
            background = u.backgroundTop;
        } else if (backgroundKind == 2u) {
            background = mix(u.backgroundTop, u.backgroundBottom, clamp(in.uv.y, 0.0, 1.0));
        }

        float scale = max(u.transform.x, 0.0001);
        float2 translate = u.transform.yz;
        float2 pixel = in.uv * u.drawableSize;
        float2 untransformed = (pixel - translate) / scale;
        float2 local = untransformed - u.frameOrigin;
        float mask = roundedRectAlpha(local, u.frameSize, u.transform.w);
        if (mask <= 0.001) {
            return half4(background);
        }

        float2 source = local / max(u.frameSize, float2(1.0)) * u.sourceSize;
        float2 texCoord = source / max(u.sourceSize, float2(1.0));
        texCoord = clamp(texCoord, float2(0.0), float2(1.0));
        half4 video = videoTexture.sample(videoSampler, texCoord);
        float blurStrength = clamp(u.options.y, 0.0, 1.0);
        float2 blurVector = u.options.zw;
        if (blurStrength > 0.001 && length(blurVector) > 0.00001) {
            half4 a = videoTexture.sample(videoSampler, clamp(texCoord - blurVector, float2(0.0), float2(1.0)));
            half4 b = videoTexture.sample(videoSampler, clamp(texCoord + blurVector, float2(0.0), float2(1.0)));
            video = mix(video, video * half(0.60) + (a + b) * half(0.20), half(blurStrength));
        }

        float alpha = clamp(mask, 0.0, 1.0);
        return half4(mix(background.rgb, float3(video.rgb), alpha), mix(background.a, 1.0, alpha));
    }

    fragment half4 cursorFragment(VertexOut in [[stage_in]],
                                  texture2d<half> atlas [[texture(0)]],
                                  sampler atlasSampler [[sampler(0)]],
                                  constant SpriteUniforms &u [[buffer(0)]]) {
        half4 color = atlas.sample(atlasSampler, in.uv);
        half opacity = half(clamp(u.options.x, 0.0, 1.0));
        return color * opacity;
    }

    fragment half4 rippleFragment(VertexOut in [[stage_in]],
                                  constant RippleUniforms &u [[buffer(0)]]) {
        float2 quadSize = max(u.geometry.xy, float2(1.0));
        float radius = max(u.geometry.z, 0.0);
        float lineWidth = max(u.geometry.w, 0.5);
        float2 p = (in.uv - float2(0.5)) * quadSize;
        float distanceToRing = abs(length(p) - radius);
        float alpha = (1.0 - smoothstep(lineWidth * 0.5, lineWidth * 0.5 + 1.25, distanceToRing)) * clamp(u.color.a, 0.0, 1.0);
        return half4(half3(u.color.rgb * alpha), half(alpha));
    }
    """
}
