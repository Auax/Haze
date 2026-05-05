import CoreGraphics
import Foundation

struct CursorRenderState {
    let position: CGPoint
    let shape: CursorShape
    let pulse: CGFloat
    let rotation: CGFloat
    let opacity: CGFloat
    let scale: CGFloat
}

struct ClickEffectState {
    let position: CGPoint
    let age: TimeInterval
    let duration: TimeInterval
}

struct RenderFrameState {
    let outputTime: Double
    let sourceTime: Double
    let sourceSize: CGSize
    let canvasSize: CGSize
    let zoom: Double
    let cameraCenter: CGPoint
    let sourceRect: CGRect
    let cursor: CursorRenderState?
    let activeClicks: [ClickEffectState]
    let motionBlurAmount: Double
    let panAmount: CGFloat
}

enum RenderFrameStateBuilder {
    static func make(
        session: RecordingSession,
        outputTime: Double? = nil,
        sourceTime: Double,
        canvasSize: CGSize? = nil
    ) -> RenderFrameState {
        let sourceSize = CGSize(width: session.width, height: session.height)
        let canvasSize = canvasSize ?? sourceSize
        let activeZoom = session.zooms.first {
            sourceTime >= $0.start - 0.001 && sourceTime <= $0.start + $0.duration + 0.001
        }
        let zoomValue = activeZoom.map { zoomScale(for: $0, at: sourceTime) } ?? 1
        let progress = activeZoom.map {
            min(max((sourceTime - $0.start) / max(0.001, $0.duration), 0), 1)
        } ?? 0
        let panAmount = activeZoom.map { zoomPanAmount(progress: progress, zoom: $0) } ?? 0
        let cameraCenter = activeZoom.map {
            cinematicZoomCameraCenter(for: $0, at: sourceTime, session: session)
        } ?? CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)

        let cursor = makeCursorState(session: session, sourceTime: sourceTime)
        let clicks = makeClickStates(session: session, sourceTime: sourceTime)
        let sourceRect = visibleSourceRect(
            sourceSize: sourceSize,
            cameraCenter: cameraCenter,
            zoom: zoomValue
        )

        return RenderFrameState(
            outputTime: outputTime ?? sourceTime,
            sourceTime: sourceTime,
            sourceSize: sourceSize,
            canvasSize: canvasSize,
            zoom: zoomValue,
            cameraCenter: cameraCenter,
            sourceRect: sourceRect,
            cursor: cursor,
            activeClicks: clicks,
            motionBlurAmount: min(max(session.edit.motionBlur, 0), 2),
            panAmount: panAmount
        )
    }

    private static func makeCursorState(session: RecordingSession, sourceTime: Double) -> CursorRenderState? {
        guard session.edit.showCursor,
              let position = smoothedCursor(
                at: sourceTime,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
              )
        else {
            return nil
        }

        let shape = cursorShape(at: sourceTime, samples: session.cursorShapes)
        let pulse = session.settings.cursorClickPulse
            ? cursorPulseScale(at: sourceTime, clicks: session.clicks, strength: session.settings.cursorClickPulseStrength)
            : 1
        let rotation = cursorSpringRotation(
            at: sourceTime,
            samples: session.cursorSamples,
            smoothing: session.settings.cursorSmoothing,
            window: session.settings.cursorSmoothingWindow,
            strength: session.settings.cursorSpring,
            sprite: session.settings.cursorSprite,
            shape: shape
        )

        return CursorRenderState(
            position: position,
            shape: shape,
            pulse: pulse,
            rotation: rotation,
            opacity: CGFloat(session.settings.cursorOpacity),
            scale: CGFloat(session.settings.cursorScale) * pulse
        )
    }

    private static func makeClickStates(session: RecordingSession, sourceTime: Double) -> [ClickEffectState] {
        guard session.edit.showClickRipples else { return [] }
        return session.clicks.compactMap { click in
            let age = sourceTime - click.time
            guard age >= 0, age < ExportRippleParams.window else { return nil }
            return ClickEffectState(
                position: CGPoint(x: click.x, y: click.y),
                age: age,
                duration: ExportRippleParams.window
            )
        }
    }

    private static func visibleSourceRect(sourceSize: CGSize, cameraCenter: CGPoint, zoom: Double) -> CGRect {
        guard zoom > 1.001 else {
            return CGRect(origin: .zero, size: sourceSize)
        }

        let width = sourceSize.width / CGFloat(max(zoom, 0.001))
        let height = sourceSize.height / CGFloat(max(zoom, 0.001))
        let origin = CGPoint(
            x: min(max(cameraCenter.x - width / 2, 0), max(0, sourceSize.width - width)),
            y: min(max(cameraCenter.y - height / 2, 0), max(0, sourceSize.height - height))
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
