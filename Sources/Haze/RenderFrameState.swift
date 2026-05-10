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

struct RenderTimelineIndex {
    private struct IndexedZoom {
        let index: Int
        let zoom: ZoomKeyframe
    }

    private struct IndexedClick {
        let index: Int
        let click: MouseClickEvent
    }

    let session: RecordingSession
    private let zoomsByStart: [IndexedZoom]
    private let cursorShapeSamples: [CursorShapeSample]
    private let clicksByTime: [IndexedClick]

    init(session: RecordingSession) {
        self.session = session
        self.zoomsByStart = session.zooms.enumerated()
            .map { IndexedZoom(index: $0.offset, zoom: $0.element) }
            .sorted {
                if $0.zoom.start == $1.zoom.start { return $0.index < $1.index }
                return $0.zoom.start < $1.zoom.start
            }
        self.cursorShapeSamples = session.cursorShapes.sorted { $0.time < $1.time }
        self.clicksByTime = session.clicks.enumerated()
            .map { IndexedClick(index: $0.offset, click: $0.element) }
            .sorted {
                if $0.click.time == $1.click.time { return $0.index < $1.index }
                return $0.click.time < $1.click.time
            }
    }

    func activeZoom(at sourceTime: Double) -> ZoomKeyframe? {
        let tolerance = 0.001
        let upper = upperBoundZoomStart(sourceTime + tolerance)
        var best: IndexedZoom?
        for candidate in zoomsByStart[..<upper] {
            guard sourceTime <= candidate.zoom.start + candidate.zoom.duration + tolerance else { continue }
            if best == nil || candidate.index < best!.index {
                best = candidate
            }
        }
        return best?.zoom
    }

    func cursorPosition(at sourceTime: Double) -> CGPoint? {
        smoothedCursor(
            at: sourceTime,
            samples: session.cursorSamples,
            smoothing: session.settings.cursorSmoothing,
            window: session.settings.cursorSmoothingWindow
        )
    }

    func cursorShape(at sourceTime: Double) -> CursorShape {
        guard !cursorShapeSamples.isEmpty else { return .default }
        let threshold = max(0, HazeDefaults.Cursor.shapeChangeMinimumDuration)
        var stableShape = cursorShapeSamples.first?.shape ?? .default
        let upper = upperBoundCursorShapeTime(sourceTime)
        guard upper > 0 else { return stableShape }

        for index in 0..<upper {
            let sample = cursorShapeSamples[index]
            let nextTime = index + 1 < cursorShapeSamples.count ? cursorShapeSamples[index + 1].time : nil
            let segmentEnd = nextTime ?? sourceTime
            let segmentDuration = max(0, segmentEnd - sample.time)
            let isCurrentOpenSegment = nextTime == nil

            if segmentDuration >= threshold || (isCurrentOpenSegment && sourceTime - sample.time >= threshold) {
                stableShape = sample.shape
            }
        }
        return stableShape
    }

    func cursorPulseScale(at sourceTime: Double) -> CGFloat {
        guard session.settings.cursorClickPulse else { return 1 }
        let amount = max(0, min(1, session.settings.cursorClickPulseStrength))
        guard amount > 0.001 else { return 1 }

        var offset: Double = 0
        let duration = 0.68
        let dipDepth = 0.13 + amount * 0.20
        let rebound = 0.025 + amount * 0.045
        let lower = lowerBoundClickTime(sourceTime - duration)
        let upper = upperBoundClickTime(sourceTime)
        guard lower < upper else { return 1 }

        for indexedClick in clicksByTime[lower..<upper] {
            let elapsed = sourceTime - indexedClick.click.time
            guard elapsed >= 0, elapsed <= duration else { continue }
            let p = elapsed / duration
            let contribution: Double
            if p < 0.18 {
                contribution = -dipDepth * renderIndexEaseOutCubic(p / 0.18)
            } else if p < 0.52 {
                let u = (p - 0.18) / 0.34
                contribution = -dipDepth + (dipDepth + rebound) * renderIndexEaseOutCubic(u)
            } else {
                let u = (p - 0.52) / 0.48
                contribution = rebound * (1 - renderIndexEaseInOutCubic(u))
            }
            offset += contribution
        }
        return CGFloat(min(max(1 + offset, 1 - dipDepth), 1 + rebound))
    }

    func cursorSpringRotation(at sourceTime: Double, shape: CursorShape) -> CGFloat {
        Haze.cursorSpringRotation(
            at: sourceTime,
            samples: session.cursorSamples,
            smoothing: session.settings.cursorSmoothing,
            window: session.settings.cursorSmoothingWindow,
            strength: session.settings.cursorSpring,
            sprite: session.settings.cursorSprite,
            shape: shape
        )
    }

    func activeClickStates(at sourceTime: Double) -> [ClickEffectState] {
        guard session.edit.showClickRipples else { return [] }
        let lower = lowerBoundClickTime(sourceTime - ExportRippleParams.window)
        let upper = upperBoundClickTime(sourceTime)
        guard lower < upper else { return [] }
        return clicksByTime[lower..<upper]
            .sorted { $0.index < $1.index }
            .compactMap { indexedClick in
                let click = indexedClick.click
                let age = sourceTime - click.time
                guard age >= 0, age < ExportRippleParams.window else { return nil }
                return ClickEffectState(
                    position: CGPoint(x: click.x, y: click.y),
                    age: age,
                    duration: ExportRippleParams.window
                )
            }
    }

    private func upperBoundZoomStart(_ time: Double) -> Int {
        var low = 0
        var high = zoomsByStart.count
        while low < high {
            let mid = (low + high) / 2
            if zoomsByStart[mid].zoom.start <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func upperBoundCursorShapeTime(_ time: Double) -> Int {
        var low = 0
        var high = cursorShapeSamples.count
        while low < high {
            let mid = (low + high) / 2
            if cursorShapeSamples[mid].time <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func lowerBoundClickTime(_ time: Double) -> Int {
        var low = 0
        var high = clicksByTime.count
        while low < high {
            let mid = (low + high) / 2
            if clicksByTime[mid].click.time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func upperBoundClickTime(_ time: Double) -> Int {
        var low = 0
        var high = clicksByTime.count
        while low < high {
            let mid = (low + high) / 2
            if clicksByTime[mid].click.time <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

enum RenderFrameStateBuilder {
    static func make(
        session: RecordingSession,
        outputTime: Double? = nil,
        sourceTime: Double,
        canvasSize: CGSize? = nil
    ) -> RenderFrameState {
        make(
            timelineIndex: RenderTimelineIndex(session: session),
            outputTime: outputTime,
            sourceTime: sourceTime,
            canvasSize: canvasSize
        )
    }

    static func make(
        timelineIndex: RenderTimelineIndex,
        outputTime: Double? = nil,
        sourceTime: Double,
        canvasSize: CGSize? = nil
    ) -> RenderFrameState {
        let session = timelineIndex.session
        let sourceSize = CGSize(width: session.width, height: session.height)
        let canvasSize = canvasSize ?? sourceSize
        let activeZoom = timelineIndex.activeZoom(at: sourceTime)
        let zoomValue = activeZoom.map { zoomScale(for: $0, at: sourceTime) } ?? 1
        let progress = activeZoom.map {
            min(max((sourceTime - $0.start) / max(0.001, $0.duration), 0), 1)
        } ?? 0
        let panAmount = activeZoom.map { zoomPanAmount(progress: progress, zoom: $0) } ?? 0
        let cameraCenter = activeZoom.map {
            cinematicZoomCameraCenter(for: $0, at: sourceTime, session: session)
        } ?? CGPoint(x: sourceSize.width / 2, y: sourceSize.height / 2)

        let cursor = makeCursorState(timelineIndex: timelineIndex, sourceTime: sourceTime)
        let clicks = timelineIndex.activeClickStates(at: sourceTime)
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

    private static func makeCursorState(timelineIndex: RenderTimelineIndex, sourceTime: Double) -> CursorRenderState? {
        let session = timelineIndex.session
        guard session.edit.showCursor,
              let position = timelineIndex.cursorPosition(at: sourceTime)
        else {
            return nil
        }

        let shape = timelineIndex.cursorShape(at: sourceTime)
        let pulse = timelineIndex.cursorPulseScale(at: sourceTime)
        let rotation = timelineIndex.cursorSpringRotation(at: sourceTime, shape: shape)

        return CursorRenderState(
            position: position,
            shape: shape,
            pulse: pulse,
            rotation: rotation,
            opacity: CGFloat(session.settings.cursorOpacity),
            scale: CGFloat(session.settings.cursorScale) * regionCursorOutputScale(for: session) * pulse
        )
    }

    private static func regionCursorOutputScale(for session: RecordingSession) -> CGFloat {
        guard session.settings.captureKind == .region else { return 1 }
        let region = session.settings.region.standardized
        guard region.width > 0, region.height > 0 else { return 1 }

        let scaleX = CGFloat(session.width) / max(1, region.width)
        let scaleY = CGFloat(session.height) / max(1, region.height)
        return min(max(1, min(scaleX, scaleY)), 3)
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

    #if DEBUG
    static func debugIndexedStateMatchesLegacy(
        session: RecordingSession,
        sourceTimes: [Double],
        canvasSize: CGSize? = nil
    ) -> Bool {
        let timelineIndex = RenderTimelineIndex(session: session)
        return sourceTimes.allSatisfy { sourceTime in
            let indexed = make(timelineIndex: timelineIndex, sourceTime: sourceTime, canvasSize: canvasSize)
            let legacy = legacyMake(session: session, sourceTime: sourceTime, canvasSize: canvasSize)
            return statesMatch(indexed, legacy)
        }
    }

    private static func legacyMake(
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

        let cursor = legacyCursorState(session: session, sourceTime: sourceTime)
        let clicks = legacyClickStates(session: session, sourceTime: sourceTime)
        let sourceRect = visibleSourceRect(sourceSize: sourceSize, cameraCenter: cameraCenter, zoom: zoomValue)

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

    private static func legacyCursorState(session: RecordingSession, sourceTime: Double) -> CursorRenderState? {
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
        let rotation = Haze.cursorSpringRotation(
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
            scale: CGFloat(session.settings.cursorScale) * regionCursorOutputScale(for: session) * pulse
        )
    }

    private static func legacyClickStates(session: RecordingSession, sourceTime: Double) -> [ClickEffectState] {
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

    private static func statesMatch(_ lhs: RenderFrameState, _ rhs: RenderFrameState) -> Bool {
        nearlyEqual(lhs.outputTime, rhs.outputTime)
            && nearlyEqual(lhs.sourceTime, rhs.sourceTime)
            && nearlyEqual(lhs.sourceSize, rhs.sourceSize)
            && nearlyEqual(lhs.canvasSize, rhs.canvasSize)
            && nearlyEqual(lhs.zoom, rhs.zoom)
            && nearlyEqual(lhs.cameraCenter, rhs.cameraCenter)
            && nearlyEqual(lhs.sourceRect, rhs.sourceRect)
            && cursorsMatch(lhs.cursor, rhs.cursor)
            && clicksMatch(lhs.activeClicks, rhs.activeClicks)
            && nearlyEqual(lhs.motionBlurAmount, rhs.motionBlurAmount)
            && nearlyEqual(lhs.panAmount, rhs.panAmount)
    }

    private static func cursorsMatch(_ lhs: CursorRenderState?, _ rhs: CursorRenderState?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return nearlyEqual(lhs.position, rhs.position)
                && lhs.shape == rhs.shape
                && nearlyEqual(lhs.pulse, rhs.pulse)
                && nearlyEqual(lhs.rotation, rhs.rotation)
                && nearlyEqual(lhs.opacity, rhs.opacity)
                && nearlyEqual(lhs.scale, rhs.scale)
        default:
            return false
        }
    }

    private static func clicksMatch(_ lhs: [ClickEffectState], _ rhs: [ClickEffectState]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy {
            nearlyEqual($0.position, $1.position)
                && nearlyEqual($0.age, $1.age)
                && nearlyEqual($0.duration, $1.duration)
        }
    }

    private static func nearlyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        nearlyEqual(lhs.width, rhs.width) && nearlyEqual(lhs.height, rhs.height)
    }

    private static func nearlyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        nearlyEqual(lhs.x, rhs.x) && nearlyEqual(lhs.y, rhs.y)
    }

    private static func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        nearlyEqual(lhs.origin, rhs.origin) && nearlyEqual(lhs.size, rhs.size)
    }

    private static func nearlyEqual<T: BinaryFloatingPoint>(_ lhs: T, _ rhs: T) -> Bool {
        abs(Double(lhs - rhs)) <= 0.000_001
    }
    #endif
}

private func renderIndexEaseOutCubic(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    return 1 - pow(1 - t, 3)
}

private func renderIndexEaseInOutCubic(_ value: Double) -> Double {
    let t = min(max(value, 0), 1)
    if t < 0.5 {
        return 4 * t * t * t
    }
    return 1 - pow(-2 * t + 2, 3) / 2
}
