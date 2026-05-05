import AVFoundation
import AppKit
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor entry

struct EditorView: View {
    @EnvironmentObject private var model: AppViewModel
    @StateObject private var playback = EditorPlaybackHolder()
    @StateObject private var previewRender = PreviewRenderController()
    @State private var inspectorTab: InspectorTab = .zooms

    enum InspectorTab: Hashable, CaseIterable {
        case zooms, polish, cursor, export

        var title: String {
            switch self {
            case .zooms:  return "Zooms"
            case .polish: return "Polish"
            case .cursor: return "Cursor"
            case .export: return "Export"
            }
        }

        var icon: String {
            switch self {
            case .zooms:  return "plus.magnifyingglass"
            case .polish: return "paintpalette"
            case .cursor: return "cursorarrow"
            case .export: return "square.and.arrow.up"
            }
        }
    }

    var body: some View {
        Group {
            if let session = model.currentSession {
                content(session: session)
                    .onAppear {
                        playback.ensure(url: session.rawVideoURL)
                        previewRender.resetToApproximate(cache: model.previewCache)
                    }
                    .onChange(of: session.rawVideoURL) { _, newURL in
                        playback.ensure(url: newURL)
                        previewRender.resetToApproximate(cache: model.previewCache)
                    }
            } else {
                ContentUnavailableView(
                    "No recording loaded",
                    systemImage: "film",
                    description: Text("Record something in the recorder window first.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func content(session: RecordingSession) -> some View {
        VStack(spacing: 0) {
            EditorTopBar(session: session, previewRender: previewRender, playbackTime: $model.playbackTime)
                .environmentObject(model)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    if let controller = playback.controller {
                        EditorPreview(
                            session: session,
                            controller: controller,
                            playbackTime: $model.playbackTime,
                            selectedZoomID: $model.selectedZoomID,
                            previewRender: previewRender
                        )
                        .environmentObject(model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        TimelinePanel(
                            session: session,
                            controller: controller,
                            playbackTime: $model.playbackTime,
                            selectedZoomID: $model.selectedZoomID,
                            previewRender: previewRender
                        )
                        .environmentObject(model)
                        .frame(height: 260)
                        .onAppear {
                            syncPlaybackRange(session: session, controller: controller)
                        }
                        .onChange(of: session.timelineTrimStart) { _, _ in
                            syncPlaybackRange(session: session, controller: controller)
                        }
                        .onChange(of: session.timelineTrimEnd) { _, _ in
                            syncPlaybackRange(session: session, controller: controller)
                        }
                        .onChange(of: session.measuredDuration) { _, _ in
                            syncPlaybackRange(session: session, controller: controller)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 720)
                Inspector(tab: $inspectorTab, session: session, controller: playback.controller)
                    .environmentObject(model)
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
            }
        }
        .focusedSceneValue(\.editorActive, true)
        .background(KeyEventCatcher(action: handleKey(_:)))
    }

    private func syncPlaybackRange(session: RecordingSession, controller: PlaybackController) {
        let a = session.timelineContentStart
        let b = session.timelineContentEnd
        controller.playableTimeRange = a...b
        let t = controller.currentTime
        if t < a || t > b {
            controller.seek(to: min(max(t, a), b))
            model.playbackTime = controller.currentTime
        }
    }

    private func handleKey(_ key: KeyEventCatcher.Key) -> Bool {
        guard let controller = playback.controller, let session = model.currentSession else { return false }
        switch key {
        case .space:
            controller.togglePlay()
            return true
        case .leftArrow:
            controller.pause()
            controller.step(by: -1)
            model.playbackTime = controller.currentTime
            return true
        case .rightArrow:
            controller.pause()
            controller.step(by: 1)
            model.playbackTime = controller.currentTime
            return true
        case .shiftLeft:
            controller.seek(to: max(0, controller.currentTime - 1))
            model.playbackTime = controller.currentTime
            return true
        case .shiftRight:
            controller.seek(to: controller.currentTime + 1)
            model.playbackTime = controller.currentTime
            return true
        case .home:
            controller.seek(to: session.timelineContentStart)
            model.playbackTime = controller.currentTime
            return true
        case .end:
            controller.seek(to: max(session.timelineContentStart, session.timelineContentEnd - 0.02))
            model.playbackTime = controller.currentTime
            return true
        case .z:
            model.addZoomAtPlayhead()
            return true
        case .duplicateZoom:
            model.duplicateSelectedZoom()
            return true
        case .c:
            model.centerSelectedZoomOnCursor()
            return true
        case .delete:
            model.deleteSelectedZooms()
            return true
        case .s:
            model.splitZoomAtPlayhead()
            return true
        case .undo:
            model.undo()
            return true
        case .redo:
            model.redo()
            return true
        }
    }
}

@MainActor
final class EditorPlaybackHolder: ObservableObject {
    @Published var controller: PlaybackController?
    private var url: URL?

    func ensure(url: URL) {
        if self.url == url, controller != nil { return }
        if let existing = controller {
            existing.replace(url: url)
            self.url = url
            return
        }
        controller = PlaybackController(url: url)
        self.url = url
    }
}

struct EditorActiveKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var editorActive: Bool? {
        get { self[EditorActiveKey.self] }
        set { self[EditorActiveKey.self] = newValue }
    }
}

// MARK: - Top bar

private struct EditorTopBar: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession
    @ObservedObject var previewRender: PreviewRenderController
    @Binding var playbackTime: Double

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.rawVideoURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.rawVideoURL.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Toggle(isOn: Binding(
                get: { previewRender.mode == .highFidelity },
                set: { enabled in
                    previewRender.setMode(
                        enabled ? .highFidelity : .approximate,
                        cache: model.previewCache
                    )
                }
            )) {
                Label("Live Preview", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Enable Metal-based real-time live preview.")

            Button {
                previewRender.requestSingleFrame(
                    session: session,
                    time: playbackTime,
                    cache: model.previewCache,
                    renderer: model.renderer
                )
            } label: {
                Label("Preview Frame", systemImage: "eye")
            }
            .help("Render a final-quality preview of the current frame")

            Divider().frame(height: 22)

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Undo (⌘Z)")
            .disabled(!model.canUndo)
            .buttonStyle(.borderless)

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("Redo (⌘⇧Z)")
            .disabled(!model.canRedo)
            .buttonStyle(.borderless)

            Divider().frame(height: 22)

            if model.renderer.isRendering {
                ProgressView(value: model.renderer.progress) {
                    Text(model.renderer.status).font(.caption)
                }
                .frame(width: 180)
            }

            if let rendered = session.renderedVideoURL {
                Button {
                    model.revealRenderedFile()
                } label: {
                    Label("Reveal", systemImage: "doc.on.doc")
                }
                .help(rendered.lastPathComponent)
            }

            Button {
                model.exportRendered()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.renderer.isRendering)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview area

private struct EditorPreview: View {
    @EnvironmentObject private var model: AppViewModel
    let session: RecordingSession
    @ObservedObject var controller: PlaybackController
    @Binding var playbackTime: Double
    @Binding var selectedZoomID: UUID?
    @ObservedObject var previewRender: PreviewRenderController

    var body: some View {
        ZStack {
            background
            GeometryReader { proxy in
                if previewRender.mode == .highFidelity {
                    MetalPreviewHostView(session: session, player: controller.player, enabled: true)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    framedVideo(in: proxy.size)
                }
            }
            if previewRender.mode != .highFidelity, previewRender.finalPreviewVisible {
                finalPreviewLayer
            }
        }
        .onAppear {
            updatePreviewFrameState(time: playbackTime)
            model.previewCache.clearCurrentFrame()
        }
        .onDisappear {
            previewRender.dismissFinalPreview(cache: model.previewCache)
        }
        .onChange(of: playbackTime) { _, newTime in
            if previewRender.mode != .highFidelity {
                updatePreviewFrameState(time: newTime)
            }
            previewRender.dismissFinalPreview(cache: model.previewCache)
        }
        .onChange(of: controller.isPlaying) { _, _ in
            if previewRender.mode != .highFidelity {
                updatePreviewFrameState(time: playbackTime)
            }
            previewRender.dismissFinalPreview(cache: model.previewCache)
        }
        .clipped()
    }

    @ViewBuilder
    private var finalPreviewLayer: some View {
        ZStack {
            Color.black.opacity(0.18)
            if let image = model.previewCache.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ProgressView()
            }
            if let previewStatus = model.previewCache.status {
                VStack {
                    Spacer()
                    Text(previewStatus)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 14)
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch session.edit.background {
        case .none:
            Color.clear
        case .solid(let r, let g, let b):
            Color(red: r, green: g, blue: b)
        case .gradient(let top, let bottom):
            LinearGradient(
                colors: [top.color, bottom.color],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private func framedVideo(in size: CGSize) -> some View {
        let aspect = CGFloat(session.width) / max(1, CGFloat(session.height))
        let videoOnly = session.edit.background == .none
        // Mirror PolishPipeline (export): clamp padding to 0.18 max, take min(canvas dims) * 1.6.
        let clampedPadding = videoOnly ? 0 : max(0, min(0.18, session.edit.padding))
        let pad = CGFloat(clampedPadding) * min(size.width, size.height) * 1.6
        let availableW = max(40, size.width - pad * 2)
        let availableH = max(40, size.height - pad * 2)
        let frameH = min(availableH, availableW / aspect)
        let frameW = frameH * aspect
        // Reference frame at zero padding so cursor and ripples keep a constant
        // on-screen size regardless of the padding slider.
        let referenceFrameH = min(size.height, size.width / aspect)
        let referenceFrameW = referenceFrameH * aspect
        let cursorScreenRatio = referenceFrameW / max(1, CGFloat(session.width))
        let radius = videoOnly ? 0 : max(0, CGFloat(session.edit.cornerRadius)) * min(frameW, frameH) * 1.4
        let zoom = activeZoom(at: playbackTime, zooms: session.zooms)
        let live = liveZoom(zoom: zoom, time: playbackTime)
        let center = resolvedZoomCenter(zoom: zoom, time: playbackTime)
        let panAmount = zoomCenterAmount(zoom: zoom, time: playbackTime)
        let frameCenter = CGPoint(x: frameW / 2, y: frameH / 2)
        let focalPoint = CGPoint(
            x: CGFloat(center.x) / CGFloat(max(1, session.width)) * frameW,
            y: CGFloat(center.y) / CGFloat(max(1, session.height)) * frameH
        )
        let desiredFocalPoint = CGPoint(
            x: focalPoint.x + (frameCenter.x - focalPoint.x) * panAmount,
            y: focalPoint.y + (frameCenter.y - focalPoint.y) * panAmount
        )
        let scaledFocalPoint = CGPoint(
            x: frameCenter.x + (focalPoint.x - frameCenter.x) * live,
            y: frameCenter.y + (focalPoint.y - frameCenter.y) * live
        )
        let layerOffset = CGSize(width: desiredFocalPoint.x - scaledFocalPoint.x,
                                 height: desiredFocalPoint.y - scaledFocalPoint.y)
        let cursorTime = playbackTime
        let cursor: CGPoint? = session.edit.showCursor
            ? smoothedCursor(
                at: cursorTime,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
              )
            : nil
        let cursorShape = cursorShape(at: playbackTime, samples: session.cursorShapes)
        let cursorSpring = session.edit.showCursor
            ? cursorSpringRotation(
                at: cursorTime,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow,
                strength: session.settings.cursorSpring,
                sprite: session.settings.cursorSprite,
                shape: cursorShape
              )
            : 0
        let cursorPulse = (session.edit.showCursor && session.settings.cursorClickPulse)
            ? cursorPulseScale(at: playbackTime, clicks: session.clicks, strength: session.settings.cursorClickPulseStrength)
            : 1.0
        // Drop the heavy SwiftUI shadow during playback. The static shadow is recomputed every
        // frame because of scaleEffect, which tanks FPS - especially at high resolutions.
        let isPlaying = controller.isPlaying
        let shadowRadius = videoOnly || isPlaying ? 0 : max(2, CGFloat(session.edit.shadow) * 30)
        let shadowOpacity = videoOnly || isPlaying ? 0 : session.edit.shadow * 0.6
        let shadowOffsetY = videoOnly || isPlaying ? 0 : max(0, CGFloat(session.edit.shadow) * 16)
        let cursorOpacity = session.settings.cursorOpacity
        ZStack {
            ZStack {
                PlayerHostView(player: controller.player)
                    .frame(width: frameW, height: frameH)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .shadow(
                        color: Color.black.opacity(shadowOpacity),
                        radius: shadowRadius,
                        x: 0,
                        y: shadowOffsetY
                    )
                if !videoOnly {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                        .frame(width: frameW, height: frameH)
                }
                if session.edit.showClickRipples {
                    ForEach(activeRipples(at: playbackTime, clicks: session.clicks)) { ripple in
                        RippleMarker(elapsed: ripple.elapsed, frameToSessionRatio: cursorScreenRatio)
                            .position(
                                x: ripple.x / Double(session.width) * frameW,
                                y: ripple.y / Double(session.height) * frameH
                            )
                            .allowsHitTesting(false)
                    }
                }
                if session.edit.showCursor, let point = cursor {
                    CursorMarker(
                        sprite: session.settings.cursorSprite,
                        scale: CGFloat(session.settings.cursorScale) * cursorPulse,
                        settings: session.settings,
                        systemShape: cursorShape,
                        springRotation: cursorSpring,
                        frameToSessionRatio: cursorScreenRatio
                    )
                        .opacity(cursorOpacity)
                        .position(
                            x: point.x / Double(session.width) * frameW,
                            y: point.y / Double(session.height) * frameH
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(width: frameW, height: frameH)
            .scaleEffect(live, anchor: .center)
            .offset(layerOffset)
        }
        .frame(width: size.width, height: size.height)
    }

    private func activeZoom(at time: Double, zooms: [ZoomKeyframe]) -> ZoomKeyframe? {
        zooms.first { time >= $0.start - 0.001 && time <= $0.start + $0.duration + 0.001 }
    }

    private func liveZoom(zoom: ZoomKeyframe?, time: Double) -> CGFloat {
        guard let zoom else { return 1 }
        let t = min(max((time - zoom.start) / max(0.001, zoom.duration), 0), 1)
        let envelope = zoomEnvelope(progress: t, zoom: zoom)
        return CGFloat(pow(zoom.scale, envelope))
    }

    private func zoomCenterAmount(zoom: ZoomKeyframe?, time: Double) -> CGFloat {
        guard let zoom else { return 0 }
        let t = min(max((time - zoom.start) / max(0.001, zoom.duration), 0), 1)
        return zoomPanAmount(progress: t, zoom: zoom)
    }

    private func resolvedZoomCenter(zoom: ZoomKeyframe?, time: Double) -> CGPoint {
        guard let zoom else {
            return CGPoint(x: Double(session.width) / 2, y: Double(session.height) / 2)
        }
        return cinematicZoomCameraCenter(for: zoom, at: time, session: session)
    }

    private func updatePreviewFrameState(time: Double) {
        let zoom = activeZoom(at: time, zooms: session.zooms)
        let cursor = session.edit.showCursor
            ? smoothedCursor(
                at: time,
                samples: session.cursorSamples,
                smoothing: session.settings.cursorSmoothing,
                window: session.settings.cursorSmoothingWindow
              )
            : nil
        let clicks = session.edit.showClickRipples
            ? session.clicks.compactMap { click -> ClickEffectState? in
                let age = time - click.time
                guard age >= 0, age < ExportRippleParams.window else { return nil }
                return ClickEffectState(
                    position: CGPoint(x: click.x, y: click.y),
                    age: age,
                    duration: ExportRippleParams.window
                )
              }
            : []
        previewRender.update(state: PreviewFrameState(
            time: time,
            isPlaying: controller.isPlaying,
            isScrubbing: previewRender.isScrubbing,
            zoom: Double(liveZoom(zoom: zoom, time: time)),
            cameraCenter: resolvedZoomCenter(zoom: zoom, time: time),
            cursorPosition: cursor,
            activeClicks: clicks,
            motionBlurAmount: session.edit.motionBlur,
            previewMotionBlurEnabled: session.edit.previewMotionBlurEnabled
        ))
    }
}

/// Editor-side cursor marker. Renders the *exact same* NSImage that the export pipeline uses,
/// then scales it down by the editor's framed-rect ratio. This guarantees pixel-level fidelity
/// between the live preview and the final exported video for both sprite shape and hotspot
/// position.
private struct CursorMarker: View {
    let sprite: CursorSprite
    let scale: CGFloat
    let settings: RecordingSettings
    let systemShape: CursorShape
    let springRotation: CGFloat
    /// Ratio between the framed video shown in the editor and the recording's session pixels.
    let frameToSessionRatio: CGFloat

    var body: some View {
        if let render = CursorOverlay.shared.spriteRender(
            scale: scale,
            sprite: sprite,
            settings: settings,
            shape: systemShape
        ) {
            let ratio = max(0.0001, frameToSessionRatio)
            // Render at editor-frame pixels (session px × frame/session ratio).
            let w = render.size.width * ratio
            let h = render.size.height * ratio
            let hx = render.hotspotTopLeft.x * ratio
            let hy = render.hotspotTopLeft.y * ratio
            // After `.position(cx, cy)` SwiftUI centers the image at (cx, cy). To make the hotspot
            // (at top-left coords (hx, hy)) land on (cx, cy), shift by (w/2 - hx, h/2 - hy).
            // Spring rotation is applied around the hotspot anchor so it doesn't move the hotspot.
            Image(nsImage: render.nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: w, height: h)
                .rotationEffect(
                    .radians(springRotation),
                    anchor: UnitPoint(
                        x: w > 0 ? hx / w : 0.5,
                        y: h > 0 ? hy / h : 0.5
                    )
                )
                .offset(x: w * 0.5 - hx, y: h * 0.5 - hy)
        }
    }
}

private struct RippleEvent: Identifiable {
    var id: UUID
    var x: Double
    var y: Double
    var elapsed: Double
}

/// Editor click ripple. Uses the **same parameters** as `PolishPipeline.compositeRipple` in
/// `ExportRenderer.swift` (session-pixel radius and lineWidth), then scales by the editor's
/// frame-to-session ratio so the ripple looks identical in the live preview and exported video.
private struct RippleMarker: View {
    let elapsed: Double
    let frameToSessionRatio: CGFloat

    var body: some View {
        let window = ExportRippleParams.window
        let progress = min(max(elapsed / window, 0), 1)
        let radiusSession = ExportRippleParams.radius(forElapsed: elapsed)
        let diameter = 2 * radiusSession * Double(frameToSessionRatio)
        let lineWidth = ExportRippleParams.lineWidth * frameToSessionRatio
        let alpha = max(0, 1 - progress)
        Circle()
            .stroke(Color.white.opacity(alpha), lineWidth: lineWidth)
            .frame(width: diameter, height: diameter)
    }
}

/// Single source of truth for click-ripple sizing/timing. Used by both `RippleMarker` (editor)
/// and `PolishPipeline.compositeRipple` (export) so the live preview and exported video match.
enum ExportRippleParams {
    static let window: Double = 0.55
    static let lineWidth: CGFloat = 4
    static func radius(forElapsed elapsed: Double) -> Double {
        30 + elapsed * 110
    }
    static func alpha(forElapsed elapsed: Double) -> Double {
        max(0, 1 - elapsed / window)
    }
}

// MARK: - Timeline

private struct TimelinePanel: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession
    @ObservedObject var controller: PlaybackController
    @Binding var playbackTime: Double
    @Binding var selectedZoomID: UUID?
    @ObservedObject var previewRender: PreviewRenderController
    @State private var filmstripSelected = false
    @State private var timelineZoomScale: Double = 1.0

    var body: some View {
        VStack(spacing: 8) {
            playbackBar
            timelineHeader
            GeometryReader { proxy in
                let timelineWidth = max(800, proxy.size.width) * timelineZoomScale
                ScrollViewReader { _ in
                    ScrollView(.horizontal, showsIndicators: true) {
                        timelineTracks(width: timelineWidth)
                            .frame(width: timelineWidth)
                    }
                }
            }
            .frame(height: 152)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.seek(to: session.timelineContentStart)
                playbackTime = controller.currentTime
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .help("Jump to clip start")

            Button {
                controller.pause()
                controller.step(by: -1)
                playbackTime = controller.currentTime
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.borderless)
            .help("Frame back (←)")

            Button {
                controller.togglePlay()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28)
            }
            .buttonStyle(.borderedProminent)
            .help("Play/Pause (Space)")

            Button {
                controller.pause()
                controller.step(by: 1)
                playbackTime = controller.currentTime
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.borderless)
            .help("Frame forward (→)")

            Button {
                controller.seek(to: max(session.timelineContentStart, session.timelineContentEnd - 0.02))
                playbackTime = controller.currentTime
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 22)

            Text(timecode(max(0, playbackTime - session.timelineContentStart)))
                .font(.system(.body, design: .monospaced))
            Text("/")
                .foregroundStyle(.secondary)
            Text(timecode(session.timelineVisibleDuration))
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))

            Spacer()

            Button {
                model.splitZoomAtPlayhead()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .controlSize(.small)
            .help("Split zoom at playhead, or trim clip after playhead (S)")

            Button {
                model.clearAllZooms()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(session.zooms.isEmpty)
            .help("Remove all zooms")
        }
        .onChange(of: controller.currentTime) { _, newTime in
            if abs(newTime - playbackTime) > 0.005 {
                playbackTime = newTime
            }
        }
        .onChange(of: playbackTime) { oldValue, newValue in
            // Only seek on user-driven changes (not the periodic observer above).
            if !controller.isPlaying, abs(newValue - controller.currentTime) > 0.05 {
                controller.seek(to: newValue)
            }
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 10) {
            Text("Timeline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            timelineZoomControls
        }
    }

    private var timelineZoomControls: some View {
        HStack(spacing: 6) {
            Button {
                timelineZoomScale = max(0.5, (timelineZoomScale - 0.25).rounded(toPlaces: 2))
            } label: {
                Image(systemName: "minus")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom timeline out")

            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: $timelineZoomScale, in: 0.5...4, step: 0.05)
                .frame(width: 120)
                .help("Timeline horizontal zoom")

            Button {
                timelineZoomScale = min(4, (timelineZoomScale + 0.25).rounded(toPlaces: 2))
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help("Zoom timeline in")

            Text("\(timelineZoomScale, specifier: "%.1f")×")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .controlSize(.small)
    }

    private func timelineTracks(width: Double) -> some View {
        VStack(spacing: 6) {
            let duration = max(1, session.approximateDuration)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 5) {
                    PreviewCacheStrip(
                        cachedBuckets: model.previewCache.cachedBuckets,
                        renderingBuckets: model.previewCache.renderingBuckets,
                        bucketDuration: model.previewCache.bucketDuration,
                        duration: duration,
                        width: width,
                        height: 5
                    )
                    FilmstripTimelineTrack(
                        session: session,
                        duration: duration,
                        width: width,
                        height: 68,
                        filmstripSelected: $filmstripSelected,
                        onScrubBegan: {
                            previewRender.setScrubbing(true, cache: model.previewCache)
                        },
                        scrubTo: { t in
                            playbackTime = t
                            controller.pause()
                            controller.seek(to: t, precise: false)
                        },
                        onScrubEnded: {
                            previewRender.setScrubbing(false, cache: model.previewCache)
                        },
                        onSelectFilmstrip: {
                            filmstripSelected = true
                            model.selectOnlyZoom(nil)
                        }
                    )
                    ClickTrack(clicks: session.clicks, keystrokes: session.keystrokes, duration: duration, width: width, height: 16)
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(width: width, duration: duration))
                    ZoomTrack(
                        zooms: session.zooms,
                        duration: duration,
                        width: width,
                        height: 38,
                        selectedZoomID: $selectedZoomID,
                        selectedZoomIDs: $model.selectedZoomIDs,
                        selectZoom: { id, extending in
                            filmstripSelected = false
                            model.selectZoom(id, extending: extending)
                        },
                        onBegin: { model.beginUndoTransaction() },
                        onChange: { model.updateZoom($0) },
                        onEnd: { model.endUndoTransaction() }
                    )
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: playheadX(width: width, duration: duration))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: 152)
    }

    private func scrubGesture(width: Double, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                previewRender.setScrubbing(true, cache: model.previewCache)
                let t = min(max(0, value.location.x / width * duration), duration)
                playbackTime = t
                controller.pause()
                controller.seek(to: t, precise: false)
            }
            .onEnded { _ in
                previewRender.setScrubbing(false, cache: model.previewCache)
            }
    }

    private func playheadX(width: Double, duration: Double) -> Double {
        min(max(0, playbackTime / duration * width), width)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - Tracks

private struct PreviewCacheStrip: View {
    let cachedBuckets: Set<Int>
    let renderingBuckets: Set<Int>
    let bucketDuration: Double
    let duration: Double
    let width: Double
    let height: Double

    var body: some View {
        Canvas { context, _ in
            let totalBuckets = max(1, Int(ceil(duration / bucketDuration)))
            let bucketWidth = width / Double(totalBuckets)
            for bucket in cachedBuckets {
                let rect = CGRect(x: Double(bucket) * bucketWidth, y: 0, width: max(1.5, bucketWidth), height: height)
                context.fill(Path(rect), with: .color(.green.opacity(0.78)))
            }
            for bucket in renderingBuckets {
                let rect = CGRect(x: Double(bucket) * bucketWidth, y: 0, width: max(1.5, bucketWidth), height: height)
                context.fill(Path(rect), with: .color(.yellow.opacity(0.9)))
            }
        }
        .frame(width: width, height: height)
        .background(Color.secondary.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .help("Preview cache: green is cached, yellow is rendering")
    }
}

private struct FilmstripTimelineTrack: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession
    let duration: Double
    let width: Double
    let height: Double
    @Binding var filmstripSelected: Bool
    let onScrubBegan: () -> Void
    let scrubTo: (Double) -> Void
    let onScrubEnded: () -> Void
    let onSelectFilmstrip: () -> Void

    private static let coord = "FilmstripTimelineTrack"

    @State private var trimDrag: TrimDragState?
    @State private var slipAnchor: (trimStart: Double, trimEnd: Double)?

    private struct TrimDragState {
        var kind: Kind
        var anchorTrimStart: Double
        var anchorTrimEnd: Double
        var startX: CGFloat

        enum Kind { case leading, trailing }
    }

    var body: some View {
        let x0 = session.timelineContentStart / max(0.0001, duration) * width
        let x1 = session.timelineContentEnd / max(0.0001, duration) * width
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ThumbnailStrip(url: session.rawVideoURL, duration: duration, width: width, height: height)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(0.52))
                        .frame(width: max(0, x0))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color.black.opacity(0.52))
                        .frame(width: max(0, width - x1))
                }
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    WaveformFilmstripOverlay(url: session.rawVideoURL, duration: duration, width: width)
                        .frame(height: max(22, height * 0.36))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        filmstripSelected ? Color.white.opacity(0.32) : Color.white.opacity(0.14),
                        lineWidth: filmstripSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coord))
                    .onChanged { value in
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        if flags.contains(.option) {
                            if slipAnchor == nil {
                                guard let s = model.currentSession else { return }
                                slipAnchor = (s.timelineTrimStart, s.timelineTrimEnd)
                                model.beginUndoTransaction()
                            }
                            if let slipAnchor {
                                let slip = Double(value.translation.width) / max(1, width) * duration
                                model.updateTimelineTrims(
                                    trimStart: slipAnchor.trimStart + slip,
                                    trimEnd: slipAnchor.trimEnd - slip,
                                    recordUndo: false
                                )
                            }
                            return
                        }
                        onScrubBegan()
                        let t = min(max(0, value.location.x / max(1, width) * duration), duration)
                        scrubTo(t)
                    }
                    .onEnded { _ in
                        if slipAnchor != nil {
                            model.endUndoTransaction()
                            slipAnchor = nil
                        } else {
                            onScrubEnded()
                        }
                    }
            )
            .onTapGesture {
                onSelectFilmstrip()
            }

            TrimEdgeHandleView()
                .frame(width: 14, height: height)
                .offset(x: max(0, x0 - 7))
                .highPriorityGesture(trimHandleGesture(kind: .leading))
            TrimEdgeHandleView()
                .frame(width: 14, height: height)
                .offset(x: min(width - 14, x1 - 7))
                .highPriorityGesture(trimHandleGesture(kind: .trailing))
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: Self.coord)
        .help("Drag filmstrip to scrub. Drag trim handles to shorten. ⌥ drag inside the clip to slip the edit window.")
    }

    private func trimHandleGesture(kind: TrimDragState.Kind) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coord))
            .onChanged { value in
                if trimDrag == nil {
                    trimDrag = TrimDragState(
                        kind: kind,
                        anchorTrimStart: session.timelineTrimStart,
                        anchorTrimEnd: session.timelineTrimEnd,
                        startX: value.startLocation.x
                    )
                    model.beginUndoTransaction()
                }
                guard let drag = trimDrag else { return }
                let deltaT = Double(value.location.x - drag.startX) / max(1, width) * duration
                switch drag.kind {
                case .leading:
                    model.updateTimelineTrims(trimStart: drag.anchorTrimStart + deltaT, trimEnd: nil, recordUndo: false)
                case .trailing:
                    model.updateTimelineTrims(trimStart: nil, trimEnd: drag.anchorTrimEnd - deltaT, recordUndo: false)
                }
            }
            .onEnded { _ in
                trimDrag = nil
                model.endUndoTransaction()
            }
    }
}

private struct TrimEdgeHandleView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.22))
                .frame(width: 6, height: min(48, 42))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                .frame(width: 6, height: min(48, 42))
        }
        .contentShape(Rectangle())
    }
}

private struct WaveformFilmstripOverlay: View {
    let url: URL
    let duration: Double
    let width: CGFloat
    @State private var levels: [CGFloat] = []

    var body: some View {
        Group {
            if levels.isEmpty {
                Color.clear
            } else {
                Canvas { context, size in
                    let segments = max(Int(size.width), 120)
                    var path = Path()
                    for s in 0..<segments {
                        let t = Double(s) / Double(max(1, segments - 1))
                        let x = CGFloat(t) * size.width
                        let v = Self.interpolatedLevel(t, levels: levels)
                        let y = size.height * CGFloat(0.94 - 0.82 * v)
                        if s == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    let gradient = Gradient(colors: [
                        Color.white.opacity(0.82),
                        Color.white.opacity(0.45),
                        Color.white.opacity(0.1)
                    ])
                    context.stroke(
                        path,
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: size.width * 0.5, y: 0),
                            endPoint: CGPoint(x: size.width * 0.5, y: size.height)
                        ),
                        style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .task(id: "\(url.path)-\(Int(duration))-\(Int(width))") {
            let count = max(40, min(220, Int(width / 10)))
            let loaded = await WaveformBucketLoader.load(url: url, duration: duration, bucketCount: count)
            if !Task.isCancelled {
                levels = loaded
            }
        }
    }

    private static func interpolatedLevel(_ t: Double, levels: [CGFloat]) -> CGFloat {
        guard !levels.isEmpty else { return 0 }
        if levels.count == 1 { return min(1, max(0, levels[0])) }
        let x = t * Double(levels.count - 1)
        let xf = min(max(x, 0), Double(levels.count - 1))
        let i0 = Int(floor(xf))
        let i1 = min(levels.count - 1, i0 + 1)
        let frac = CGFloat(xf - Double(i0))
        let v0 = levels[i0]
        let v1 = levels[i1]
        let v = v0 + (v1 - v0) * frac
        return min(1, max(0, v))
    }
}

private enum WaveformBucketLoader {
    static func load(url: URL, duration: Double, bucketCount: Int) async -> [CGFloat] {
        guard duration > 0.04, bucketCount > 1 else { return [] }
        return await Task.detached(priority: .utility) { () async -> [CGFloat] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
            guard let reader = try? AVAssetReader(asset: asset) else { return [] }
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            var sums = [Double](repeating: 0, count: bucketCount)
            var counts = [Int](repeating: 0, count: bucketCount)

            var sampleIndex: Int64 = 0
            let formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
            let asbd = formatDescriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let channelCount = max(1, Int(asbd?.mChannelsPerFrame ?? 1))
            let sampleRate = max(8000, asbd?.mSampleRate ?? 48_000)

            while let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                let frameBytes = channelCount * MemoryLayout<Float>.size
                guard frameBytes > 0, length >= frameBytes else { continue }
                let frameCount = length / frameBytes
                var data = [UInt8](repeating: 0, count: length)
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
                guard status == kCMBlockBufferNoErr else { continue }
                data.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float.self)
                    for f in 0..<frameCount {
                        let t = Double(sampleIndex) / sampleRate
                        sampleIndex += 1
                        guard t >= 0, t <= duration + 0.01 else { continue }
                        let bucket = min(bucketCount - 1, max(0, Int(t / duration * Double(bucketCount))))
                        var peak: Float = 0
                        for ch in 0..<channelCount {
                            let idx = f * channelCount + ch
                            guard idx < floats.count else { continue }
                            let v = floats[idx]
                            peak = max(peak, abs(v))
                        }
                        sums[bucket] += Double(peak)
                        counts[bucket] += 1
                    }
                }
            }

            var out: [CGFloat] = []
            var maxVal: CGFloat = 0.0001
            for i in 0..<bucketCount {
                let avg = counts[i] > 0 ? sums[i] / Double(counts[i]) : 0
                let g = CGFloat(avg)
                out.append(g)
                maxVal = max(maxVal, g)
            }
            return out.map { min(1, $0 / maxVal) }
        }.value
    }
}

private struct ThumbnailStrip: View {
    let url: URL
    let duration: Double
    let width: Double
    let height: Double
    @State private var thumbnails: [CGImage] = []
    @State private var loadKey: String = ""

    static func imageAsync(generator: AVAssetImageGenerator, at time: CMTime) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle()
                    .fill(Color.black.opacity(0.6))
            } else {
                ForEach(0..<thumbnails.count, id: \.self) { idx in
                    Image(thumbnails[idx], scale: 1, label: Text(""))
                        .resizable()
                        .interpolation(.low)
                        .scaledToFill()
                        .frame(width: width / Double(thumbnails.count), height: height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(url.path)-\(Int(duration))-\(Int(width))") {
            await loadThumbnails()
        }
    }

    private func loadThumbnails() async {
        let key = "\(url.path)-\(Int(duration))-\(Int(width))"
        loadKey = key
        let count = max(8, min(40, Int(width / 90)))
        let times: [CMTime] = (0..<count).map { i in
            CMTime(seconds: duration * Double(i) / Double(max(1, count - 1)),
                   preferredTimescale: 600)
        }
        let images = await Task.detached(priority: .utility) { () -> [CGImage] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 120)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var out: [CGImage] = []
            for time in times {
                if let img = await Self.imageAsync(generator: generator, at: time) {
                    out.append(img)
                }
            }
            return out
        }.value
        if !Task.isCancelled, loadKey == key {
            thumbnails = images
        }
    }
}

private struct ClickTrack: View {
    let clicks: [MouseClickEvent]
    let keystrokes: [KeystrokeEvent]
    let duration: Double
    let width: Double
    let height: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
            ForEach(keystrokes) { k in
                Rectangle()
                    .fill(Color.green.opacity(0.45))
                    .frame(width: 1.5, height: height - 6)
                    .offset(x: k.time / max(0.0001, duration) * width)
            }
            ForEach(clicks) { c in
                Circle()
                    .fill(c.isRightClick ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: c.time / max(0.0001, duration) * width - 3.5,
                            y: height / 2 - 3.5)
            }
        }
        .frame(width: width, height: height)
    }
}

private struct ZoomTrack: View {
    let zooms: [ZoomKeyframe]
    let duration: Double
    let width: Double
    let height: Double
    @Binding var selectedZoomID: UUID?
    @Binding var selectedZoomIDs: Set<UUID>
    let selectZoom: (UUID, Bool) -> Void
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onEnd: () -> Void

    private static let coordinateName = "ZoomTrack.coordinateSpace"

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                )
            ForEach(zooms) { zoom in
                ZoomBlock(
                    zoom: zoom,
                    duration: duration,
                    totalWidth: width,
                    height: height,
                    selected: selectedZoomIDs.contains(zoom.id) || selectedZoomID == zoom.id,
                    coordinateSpaceName: Self.coordinateName,
                    select: { extending in selectZoom(zoom.id, extending) },
                    onBegin: onBegin,
                    onChange: onChange,
                    onEnd: onEnd
                )
            }
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: Self.coordinateName)
    }
}

private struct ZoomBlock: View {
    let zoom: ZoomKeyframe
    let duration: Double
    let totalWidth: Double
    let height: Double
    let selected: Bool
    let coordinateSpaceName: String
    let select: (Bool) -> Void
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onEnd: () -> Void
    @State private var dragKind: DragKind?
    @State private var origin: ZoomKeyframe?
    @State private var dragStartX: Double = 0
    @State private var draft: ZoomKeyframe?

    enum DragKind { case body, leftEdge, rightEdge, zoomInEnd, zoomOutStart }

    var body: some View {
        let x = zoom.start / max(0.0001, duration) * totalWidth
        let w = max(56, zoom.duration / max(0.0001, duration) * totalWidth)
        let blockHeight = height - 4
        let corner: CGFloat = 5
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(selected ? 0.42 : 0.24),
                            Color.accentColor.opacity(selected ? 0.12 : 0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(selected ? 0.95 : 0.4), lineWidth: selected ? 1.5 : 1)
                }

            Canvas { context, size in
                let steps = max(14, min(64, Int(w / 3)))
                var path = Path()
                for i in 0...steps {
                    let p = Double(i) / Double(steps)
                    let env = zoomEnvelope(progress: p, zoom: zoom)
                    let px = CGFloat(p) * size.width
                    let py = size.height * CGFloat(0.78 - 0.38 * env)
                    if i == 0 {
                        path.move(to: CGPoint(x: px, y: py))
                    } else {
                        path.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(selected ? 0.62 : 0.38)),
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
            }
            .allowsHitTesting(false)

            HStack {
                Spacer(minLength: 0)
                Text("\(zoom.scale, specifier: "%.1f")×")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .padding(5)
                    .opacity(w < 52 ? 0 : 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if selected {
                let timings = zoomAnimationTimings(for: zoom)
                let zoomInX = max(10, min(w - 10, timings.zoomIn / max(0.001, zoom.duration) * w))
                let zoomOutX = max(10, min(w - 10, (zoom.duration - timings.zoomOut) / max(0.001, zoom.duration) * w))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: max(2, zoomOutX - zoomInX), height: 2)
                    .offset(x: zoomInX, y: blockHeight - 6)
                    .allowsHitTesting(false)
                AnimationHandle()
                    .offset(x: zoomInX - 7, y: (blockHeight - 22) / 2)
                    .highPriorityGesture(dragGesture(kind: .zoomInEnd))
                    .help("Drag to set where zoom-in animation ends")
                AnimationHandle()
                    .offset(x: zoomOutX - 7, y: (blockHeight - 22) / 2)
                    .highPriorityGesture(dragGesture(kind: .zoomOutStart))
                    .help("Drag to set where zoom-out animation starts")
                HStack(spacing: 0) {
                    Handle()
                        .highPriorityGesture(dragGesture(kind: .leftEdge))
                    Spacer(minLength: 0)
                    Handle()
                        .highPriorityGesture(dragGesture(kind: .rightEdge))
                }
            }
        }
        .frame(width: w, height: blockHeight)
        .contentShape(Rectangle())
        .offset(x: x, y: 2)
        .onTapGesture { select(selectionExtendsFromCurrentEvent()) }
        .gesture(dragGesture(kind: .body))
    }

    /// Use the named coordinate space of the parent ZoomTrack so locations stay anchored
    /// to the (stationary) timeline while the dragged block itself moves. Otherwise,
    /// SwiftUI re-evaluates `value.translation.width` against the moved view each frame
    /// which causes visible twitching during edge resizes.
    private func dragGesture(kind explicitKind: DragKind? = nil) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                if dragKind == nil {
                    dragKind = explicitKind ?? .body
                    origin = zoom
                    dragStartX = Double(value.startLocation.x)
                    draft = zoom
                    select(selectionExtendsFromCurrentEvent())
                    onBegin()
                }
                guard let kind = dragKind, let origin else { return }
                let deltaX = Double(value.location.x) - dragStartX
                let dt = deltaX / max(1, totalWidth) * duration
                var updated = origin
                switch kind {
                case .body:
                    updated.start = max(0, min(duration - origin.duration, origin.start + dt))
                case .leftEdge:
                    let minDuration = minimumDuration(for: origin)
                    let newStart = max(0, min(origin.start + origin.duration - minDuration, origin.start + dt))
                    let newDuration = origin.duration - (newStart - origin.start)
                    updated.start = newStart
                    updated.duration = max(minDuration, newDuration)
                case .rightEdge:
                    let minDuration = minimumDuration(for: origin)
                    let newDuration = max(minDuration, origin.duration + dt)
                    updated.duration = min(duration - origin.start, newDuration)
                case .zoomInEnd:
                    updated.zoomInDuration = min(
                        max(0.08, origin.zoomInDuration + dt),
                        max(0.08, origin.duration - origin.zoomOutDuration)
                    )
                case .zoomOutStart:
                    let proposedStart = origin.duration - origin.zoomOutDuration + dt
                    let minStart = origin.zoomInDuration
                    let maxStart = origin.duration - 0.08
                    let clampedStart = min(max(minStart, proposedStart), maxStart)
                    updated.zoomOutDuration = origin.duration - clampedStart
                }
                draft = updated
                onChange(updated)
            }
            .onEnded { _ in
                if let draft { onChange(draft) }
                onEnd()
                dragKind = nil
                origin = nil
                draft = nil
            }
    }

    private func selectionExtendsFromCurrentEvent() -> Bool {
        guard let flags = NSApp.currentEvent?.modifierFlags else { return false }
        return flags.contains(.command) || flags.contains(.shift)
    }

    private func minimumDuration(for zoom: ZoomKeyframe) -> Double {
        max(0.5, zoom.zoomInDuration + zoom.zoomOutDuration)
    }

    private struct Handle: View {
        var body: some View {
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 22, height: 36)
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 4, height: 24)
            }
        }
    }

    private struct AnimationHandle: View {
        var body: some View {
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: 18, height: 28)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
            }
        }
    }
}

// MARK: - Inspector

private struct Inspector: View {
    @EnvironmentObject var model: AppViewModel
    @Binding var tab: EditorView.InspectorTab
    let session: RecordingSession
    let controller: PlaybackController?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(EditorView.InspectorTab.allCases, id: \.self) { tabValue in
                    Button {
                        tab = tabValue
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tabValue.icon)
                            Text(tabValue.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(tab == tabValue ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.thinMaterial)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .zooms:  ZoomInspector(session: session)
                    case .polish: PolishInspector(session: session)
                    case .cursor: CursorInspector(session: session)
                    case .export: ExportInspector(session: session)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.background)
    }
}

private struct ZoomInspector: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession

    var selected: ZoomKeyframe? {
        session.zooms.first { $0.id == model.selectedZoomID }
    }

    var selectedZooms: [ZoomKeyframe] {
        model.selectedZooms(in: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Zooms").font(.title3.weight(.semibold))
                Spacer()
                Text("\(session.zooms.count)").foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    model.addZoomAtPlayhead()
                } label: {
                    Label("Add at playhead", systemImage: "plus")
                }
                Button {
                    model.regenerateAutomaticZooms()
                } label: {
                    Label("Regenerate", systemImage: "sparkles")
                }
            }
            .controlSize(.small)

            if !selectedZooms.isEmpty {
                HStack {
                    Button {
                        model.duplicateSelectedZoom()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                }
                .controlSize(.small)
            }

            if session.zooms.isEmpty {
                ContentUnavailableView(
                    "No zooms yet",
                    systemImage: "plus.magnifyingglass",
                    description: Text("Press Z at any moment in the timeline to add a zoom, or use Regenerate.")
                )
            } else {
                Divider()
                if selectedZooms.count > 1 {
                    MultiZoomCard(
                        zooms: selectedZooms,
                        onBegin: { model.beginUndoTransaction() },
                        onChange: { apply in model.updateSelectedZooms(apply) },
                        onCommit: { apply in
                            model.updateSelectedZooms(apply)
                            model.endUndoTransaction()
                        }
                    )
                } else if let zoom = selected {
                    ZoomCard(
                        zoom: zoom,
                        width: Double(session.width),
                        height: Double(session.height),
                        selected: zoom.id == model.selectedZoomID,
                        onSelect: { model.selectOnlyZoom(zoom.id) },
                        onBegin: { model.beginUndoTransaction() },
                        onChange: { model.updateZoom($0) },
                        onCommit: {
                            model.updateZoom($0)
                            model.endUndoTransaction()
                        },
                        onCenterOnCursor: { model.centerSelectedZoomOnCursor() },
                        onDelete: { model.deleteZoom($0) }
                    )
                } else {
                    ContentUnavailableView(
                        "Select a zoom",
                        systemImage: "cursorarrow.click",
                        description: Text("Choose a zoom block in the timeline to edit its settings.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ZoomCard: View {
    let zoom: ZoomKeyframe
    let width: Double
    let height: Double
    let selected: Bool
    let onSelect: () -> Void
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onCommit: (ZoomKeyframe) -> Void
    let onCenterOnCursor: () -> Void
    let onDelete: (ZoomKeyframe) -> Void
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: selected ? "circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text("Zoom @ \(zoom.start, specifier: "%.2f")s").font(.headline)
                Spacer()
                Text(timecode(zoom.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    onDelete(zoom)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }

            SliderRow(label: "Scale",    value: zoom.scale, range: 1...3, suffix: "x") {
                var u = zoom; u.scale = $0; onChange(u)
            } onCommit: {
                var u = zoom; u.scale = $0; onCommit(u)
            } onBegin: { onBegin() }

            Toggle("Follow cursor", isOn: Binding(
                get: { zoom.followCursor },
                set: { value in
                    var u = zoom
                    u.followCursor = value
                    onBegin()
                    onCommit(u)
                }
            ))

            if !zoom.followCursor {
                ZoomCenterPicker(
                    zoom: zoom,
                    width: width,
                    height: height,
                    onBegin: onBegin,
                    onChange: onChange,
                    onCommit: onCommit,
                    onCenterOnCursor: onCenterOnCursor
                )
            }

            if zoom.followCursor {
                Picker("Follow style", selection: Binding(
                    get: { zoom.followCursorStyle },
                    set: { style in
                        var u = zoom
                        u.followCursorStyle = style
                        onBegin()
                        onCommit(u)
                    }
                )) {
                    ForEach(CursorFollowStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                SliderRow(label: "Smoothness", value: zoom.followCursorSmoothing, range: 0...2, suffix: "") {
                    var u = zoom
                    u.followCursorSmoothing = $0
                    onChange(u)
                } onCommit: {
                    var u = zoom
                    u.followCursorSmoothing = $0
                    onCommit(u)
                } onBegin: { onBegin() }
                SliderRow(label: "Cursor delay", value: zoom.followCursorDelay, range: 0...0.8, suffix: "s") {
                    var u = zoom
                    u.followCursorDelay = $0
                    onChange(u)
                } onCommit: {
                    var u = zoom
                    u.followCursorDelay = $0
                    onCommit(u)
                } onBegin: { onBegin() }

                switch zoom.followCursorStyle {
                case .cinematic:
                    DeadZoneEditor(
                        zoom: zoom,
                        width: width,
                        height: height,
                        onBegin: onBegin,
                        onChange: onChange,
                        onCommit: onCommit
                    )
                case .centered:
                    CursorAnchorSelector(
                        zoom: zoom,
                        width: width,
                        height: height,
                        onBegin: onBegin,
                        onChange: onChange,
                        onCommit: onCommit
                    )
                }
            }

            Divider()

            HStack {
                Text("Easing")
                    .frame(width: 78, alignment: .leading)
                Picker("", selection: Binding(get: { zoom.easing }, set: { newValue in
                    var u = zoom
                    u.easing = newValue
                    if newValue != .custom {
                        u.rampFraction = newValue.rampFraction
                        u.bezier = newValue.curve
                    }
                    onBegin()
                    u.zoomInDuration = max(0.08, u.duration * newValue.rampFraction)
                    u.zoomOutDuration = max(0.08, u.duration * newValue.rampFraction)
                    onCommit(u)
                })) {
                    ForEach(ZoomEasing.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            DisclosureGroup("Custom curve", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    SliderRow(label: "Ramp", value: zoom.rampFraction, range: 0.04...0.48, suffix: "") {
                        var u = zoom
                        u.easing = .custom
                        u.rampFraction = $0
                        u.zoomInDuration = max(0.08, u.duration * $0)
                        u.zoomOutDuration = max(0.08, u.duration * $0)
                        onChange(u)
                    } onCommit: {
                        var u = zoom
                        u.easing = .custom
                        u.rampFraction = $0
                        u.zoomInDuration = max(0.08, u.duration * $0)
                        u.zoomOutDuration = max(0.08, u.duration * $0)
                        onCommit(u)
                    } onBegin: { onBegin() }

                    BezierCurveEditor(
                        curve: zoom.bezier,
                        onBegin: onBegin,
                        onChange: { curve in
                            var u = zoom
                            u.easing = .custom
                            u.bezier = curve
                            onChange(u)
                        },
                        onEnd: { curve in
                            var u = zoom
                            u.easing = .custom
                            u.bezier = curve
                            onCommit(u)
                        }
                    )
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            CurveNumberField("X1", value: zoom.bezier.x1) { updateBezier(x1: $0) }
                            CurveNumberField("Y1", value: zoom.bezier.y1) { updateBezier(y1: $0) }
                        }
                        GridRow {
                            CurveNumberField("X2", value: zoom.bezier.x2) { updateBezier(x2: $0) }
                            CurveNumberField("Y2", value: zoom.bezier.y2) { updateBezier(y2: $0) }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    private func updateBezier(x1: Double? = nil, y1: Double? = nil, x2: Double? = nil, y2: Double? = nil) {
        var curve = zoom.bezier
        if let x1 { curve.x1 = x1 }
        if let y1 { curve.y1 = y1 }
        if let x2 { curve.x2 = x2 }
        if let y2 { curve.y2 = y2 }
        var u = zoom
        u.easing = .custom
        u.bezier = curve.clamped()
        onBegin()
        onCommit(u)
    }
}

private struct MultiZoomCard: View {
    let zooms: [ZoomKeyframe]
    let onBegin: () -> Void
    let onChange: ((inout ZoomKeyframe) -> Void) -> Void
    let onCommit: ((inout ZoomKeyframe) -> Void) -> Void

    private var averageScale: Double {
        zooms.reduce(0) { $0 + $1.scale } / Double(max(1, zooms.count))
    }

    private var allFollowCursor: Bool {
        zooms.allSatisfy(\.followCursor)
    }

    private var averageFollowSmoothing: Double {
        zooms.reduce(0) { $0 + $1.followCursorSmoothing } / Double(max(1, zooms.count))
    }

    private var averageFollowDelay: Double {
        zooms.reduce(0) { $0 + $1.followCursorDelay } / Double(max(1, zooms.count))
    }

    private var commonFollowStyle: CursorFollowStyle {
        let first = zooms.first?.followCursorStyle ?? .cinematic
        return zooms.allSatisfy { $0.followCursorStyle == first } ? first : .cinematic
    }

    private var commonEasing: ZoomEasing {
        let first = zooms.first?.easing ?? .smooth
        return zooms.allSatisfy { $0.easing == first } ? first : .smooth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("\(zooms.count) zooms selected")
                    .font(.headline)
                Spacer()
            }

            SliderRow(label: "Scale", value: averageScale, range: 1...3, suffix: "x") { value in
                onChange { $0.scale = value }
            } onCommit: { value in
                onCommit { $0.scale = value }
            } onBegin: { onBegin() }

            Toggle("Follow cursor during zoom", isOn: Binding(
                get: { allFollowCursor },
                set: { value in
                    onBegin()
                    onCommit { $0.followCursor = value }
                }
            ))

            if allFollowCursor {
                Picker("Follow style", selection: Binding(get: { commonFollowStyle }, set: { style in
                    onBegin()
                    onCommit { $0.followCursorStyle = style }
                })) {
                    ForEach(CursorFollowStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                SliderRow(label: "Smoothness", value: averageFollowSmoothing, range: 0...2, suffix: "") { value in
                    onChange { $0.followCursorSmoothing = value }
                } onCommit: { value in
                    onCommit { $0.followCursorSmoothing = value }
                } onBegin: { onBegin() }

                SliderRow(label: "Cursor delay", value: averageFollowDelay, range: 0...0.8, suffix: "s") { value in
                    onChange { $0.followCursorDelay = value }
                } onCommit: { value in
                    onCommit { $0.followCursorDelay = value }
                } onBegin: { onBegin() }
            }

            HStack {
                Text("Easing")
                    .frame(width: 78, alignment: .leading)
                Picker("", selection: Binding(get: { commonEasing }, set: { newValue in
                    onBegin()
                    onCommit {
                        $0.easing = newValue
                        if newValue != .custom {
                            $0.rampFraction = newValue.rampFraction
                            $0.zoomInDuration = max(0.08, $0.duration * newValue.rampFraction)
                            $0.zoomOutDuration = max(0.08, $0.duration * newValue.rampFraction)
                            $0.bezier = newValue.curve
                        }
                    }
                })) {
                    ForEach(ZoomEasing.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Text("Use command-click or shift-click in the timeline to add or remove zooms from the selection.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ZoomCenterPicker: View {
    let zoom: ZoomKeyframe
    let width: Double
    let height: Double
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onCommit: (ZoomKeyframe) -> Void
    let onCenterOnCursor: () -> Void
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Center")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCenterOnCursor()
                } label: {
                    Label("Center on Cursor", systemImage: "scope")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
            }
            GeometryReader { proxy in
                let size = proxy.size
                let x = CGFloat(zoom.centerX / max(1, width)) * size.width
                let y = CGFloat(zoom.centerY / max(1, height)) * size.height
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.42))
                    GridLines()
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .position(x: x, y: y)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !dragging {
                                dragging = true
                                onBegin()
                            }
                            onChange(updatedZoom(location: value.location, size: size))
                        }
                        .onEnded { value in
                            onCommit(updatedZoom(location: value.location, size: size))
                            dragging = false
                        }
                )
            }
            .aspectRatio(max(1, width) / max(1, height), contentMode: .fit)
            .frame(maxHeight: 120)
            Text("x \(Int(zoom.centerX.rounded())) / y \(Int(zoom.centerY.rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func updatedZoom(location: CGPoint, size: CGSize) -> ZoomKeyframe {
        var updated = zoom
        let clampedX = min(max(0, location.x), size.width)
        let clampedY = min(max(0, location.y), size.height)
        updated.centerX = Double(clampedX / max(1, size.width)) * width
        updated.centerY = Double(clampedY / max(1, size.height)) * height
        return updated
    }

    private struct GridLines: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                let x = rect.minX + rect.width * fraction
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * fraction
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            return path
        }
    }
}

private struct DeadZoneEditor: View {
    let zoom: ZoomKeyframe
    let width: Double
    let height: Double
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onCommit: (ZoomKeyframe) -> Void
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dead zone")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let size = proxy.size
                let zoneWidth = size.width * CGFloat(zoom.followCursorDeadZoneWidth)
                let zoneHeight = size.height * CGFloat(zoom.followCursorDeadZoneHeight)
                let zone = CGRect(
                    x: (size.width - zoneWidth) / 2,
                    y: (size.height - zoneHeight) / 2,
                    width: zoneWidth,
                    height: zoneHeight
                )
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.42))
                    SelectorGrid()
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                        )
                        .frame(width: zone.width, height: zone.height)
                        .position(x: zone.midX, y: zone.midY)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.5))
                        .position(x: zone.maxX, y: zone.maxY)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .onTapGesture(count: 2) {
                    var u = zoom
                    u.followCursorDeadZoneWidth = 0.35
                    u.followCursorDeadZoneHeight = 0.30
                    onBegin()
                    onCommit(u)
                }
            }
            .aspectRatio(max(1, width) / max(1, height), contentMode: .fit)
            .frame(maxHeight: 120)
            Text("Drag the handle to resize. Double-click to reset.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    onBegin()
                }
                onChange(updatedZoom(location: value.location, size: size))
            }
            .onEnded { value in
                onCommit(updatedZoom(location: value.location, size: size))
                dragging = false
            }
    }

    private func updatedZoom(location: CGPoint, size: CGSize) -> ZoomKeyframe {
        var updated = zoom
        let dx = abs(location.x - size.width / 2)
        let dy = abs(location.y - size.height / 2)
        updated.followCursorDeadZoneWidth = min(max(0.08, Double(dx * 2 / max(1, size.width))), 0.92)
        updated.followCursorDeadZoneHeight = min(max(0.08, Double(dy * 2 / max(1, size.height))), 0.92)
        return updated
    }
}

private struct CursorAnchorSelector: View {
    let zoom: ZoomKeyframe
    let width: Double
    let height: Double
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onCommit: (ZoomKeyframe) -> Void
    @State private var dragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cursor position in frame")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                let size = proxy.size
                let marker = CGPoint(
                    x: CGFloat(zoom.followCursorAnchorX) * size.width,
                    y: CGFloat(zoom.followCursorAnchorY) * size.height
                )
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.42))
                    SelectorGrid()
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                    Path { path in
                        path.move(to: CGPoint(x: marker.x, y: 0))
                        path.addLine(to: CGPoint(x: marker.x, y: size.height))
                        path.move(to: CGPoint(x: 0, y: marker.y))
                        path.addLine(to: CGPoint(x: size.width, y: marker.y))
                    }
                    .stroke(Color.accentColor.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .position(marker)
                    Circle()
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                        .position(marker)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
            }
            .aspectRatio(max(1, width) / max(1, height), contentMode: .fit)
            .frame(maxHeight: 120)
            HStack(spacing: 6) {
                anchorButton("Left", x: 0.32, y: 0.5)
                anchorButton("Center", x: 0.5, y: 0.5)
                anchorButton("Right", x: 0.68, y: 0.5)
            }
            .controlSize(.small)
        }
    }

    private func anchorButton(_ title: String, x: Double, y: Double) -> some View {
        Button(title) {
            var u = zoom
            u.followCursorAnchorX = x
            u.followCursorAnchorY = y
            onBegin()
            onCommit(u)
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    onBegin()
                }
                onChange(updatedZoom(location: value.location, size: size))
            }
            .onEnded { value in
                onCommit(updatedZoom(location: value.location, size: size))
                dragging = false
            }
    }

    private func updatedZoom(location: CGPoint, size: CGSize) -> ZoomKeyframe {
        var updated = zoom
        updated.followCursorAnchorX = min(max(0.12, Double(location.x / max(1, size.width))), 0.88)
        updated.followCursorAnchorY = min(max(0.12, Double(location.y / max(1, size.height))), 0.88)
        return updated
    }
}

private struct SelectorGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

private struct BezierCurveEditor: View {
    let curve: CubicBezier
    let onBegin: () -> Void
    let onChange: (CubicBezier) -> Void
    let onEnd: (CubicBezier) -> Void
    @State private var dragHandle: Handle?
    @State private var draft: CubicBezier?

    enum Handle { case first, second }

    private var activeCurve: CubicBezier { (draft ?? curve).clamped() }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let current = activeCurve
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                grid(size: size)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                controlLines(curve: current, size: size)
                    .stroke(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                curvePath(curve: current, size: size)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                handle(at: point(x: current.x1, y: current.y1, size: size), label: "1")
                handle(at: point(x: current.x2, y: current.y2, size: size), label: "2")
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
        }
        .frame(height: 150)
        .help("Drag a control point to shape the zoom ramp")
    }

    private func grid(size: CGSize) -> Path {
        Path { path in
            for idx in 1..<4 {
                let x = size.width * CGFloat(idx) / 4
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                let y = size.height * CGFloat(idx) / 4
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
    }

    private func curvePath(curve: CubicBezier, size: CGSize) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addCurve(
                to: CGPoint(x: size.width, y: 0),
                control1: point(x: curve.x1, y: curve.y1, size: size),
                control2: point(x: curve.x2, y: curve.y2, size: size)
            )
        }
    }

    private func controlLines(curve: CubicBezier, size: CGSize) -> Path {
        Path { path in
            let p1 = point(x: curve.x1, y: curve.y1, size: size)
            let p2 = point(x: curve.x2, y: curve.y2, size: size)
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: p1)
            path.move(to: CGPoint(x: size.width, y: 0))
            path.addLine(to: p2)
        }
    }

    private func handle(at point: CGPoint, label: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 18, height: 18)
        .position(point)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragHandle == nil {
                    dragHandle = nearestHandle(to: value.startLocation, curve: activeCurve, size: size)
                    draft = curve
                    onBegin()
                }
                guard let dragHandle else { return }
                var updated = activeCurve
                let normalized = normalizedPoint(value.location, size: size)
                switch dragHandle {
                case .first:
                    updated.x1 = normalized.x
                    updated.y1 = normalized.y
                case .second:
                    updated.x2 = normalized.x
                    updated.y2 = normalized.y
                }
                updated = updated.clamped()
                draft = updated
                onChange(updated)
            }
            .onEnded { _ in
                let final = activeCurve
                onEnd(final)
                dragHandle = nil
                draft = nil
            }
    }

    private func nearestHandle(to point: CGPoint, curve: CubicBezier, size: CGSize) -> Handle {
        let p1 = self.point(x: curve.x1, y: curve.y1, size: size)
        let p2 = self.point(x: curve.x2, y: curve.y2, size: size)
        let d1 = hypot(point.x - p1.x, point.y - p1.y)
        let d2 = hypot(point.x - p2.x, point.y - p2.y)
        return d1 <= d2 ? .first : .second
    }

    private func point(x: Double, y: Double, size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
    }

    private func normalizedPoint(_ point: CGPoint, size: CGSize) -> (x: Double, y: Double) {
        let x = min(max(point.x / max(1, size.width), 0), 1)
        let y = min(max(1 - point.y / max(1, size.height), 0), 1)
        return (Double(x), Double(y))
    }
}

private struct CurveNumberField: View {
    let title: String
    let value: Double
    let commit: (Double) -> Void

    init(_ title: String, value: Double, commit: @escaping (Double) -> Void) {
        self.title = title
        self.value = value
        self.commit = commit
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)
            TextField(title, value: Binding(
                get: { value },
                set: { commit(min(max($0, 0), 1)) }
            ), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
        }
    }
}

private struct PolishInspector: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession

    var edit: EditSettings { session.edit }

    private var currentMode: BackgroundMode {
        switch edit.background {
        case .none: return .none
        case .solid: return .solid
        case .gradient: return .gradient
        }
    }

    /// Presets that actually match the currently selected canvas mode. Hides irrelevant
    /// swatches (e.g. gradients while in Solid mode) so the picker stays consistent.
    private var visiblePresets: [(name: String, style: BackgroundStyle)] {
        let mode = currentMode
        return BackgroundStyle.presets.filter { _, style in
            switch (mode, style) {
            case (.none, .none): return true
            case (.solid, .solid): return true
            case (.gradient, .gradient): return true
            default: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Canvas").font(.headline)
            Picker("Canvas", selection: backgroundModeBinding) {
                ForEach(BackgroundMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch currentMode {
            case .none:
                Text("Renders the recording at its native size with no canvas, padding, corner radius, or shadow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .solid, .gradient:
                if !visiblePresets.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                        ForEach(visiblePresets.indices, id: \.self) { idx in
                            let preset = visiblePresets[idx]
                            BackgroundSwatch(name: preset.name, style: preset.style, selected: stylesEqual(edit.background, preset.style)) {
                                var e = edit
                                e.background = preset.style
                                model.updateEditSettings(e, recordUndo: true)
                            }
                        }
                    }
                }
                backgroundColorControls
            }

            if currentMode != .none {
                Divider()
                Text("Frame").font(.headline)
                SliderRow(label: "Padding", value: edit.padding, range: 0...0.18, suffix: "") {
                    var e = edit; e.padding = $0; model.updateEditSettings(e)
                } onCommit: {
                    var e = edit; e.padding = $0; model.updateEditSettings(e); model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() }
                SliderRow(label: "Corners", value: edit.cornerRadius, range: 0...0.08, suffix: "") {
                    var e = edit; e.cornerRadius = $0; model.updateEditSettings(e)
                } onCommit: {
                    var e = edit; e.cornerRadius = $0; model.updateEditSettings(e); model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() }
                SliderRow(label: "Shadow", value: edit.shadow, range: 0...1, suffix: "") {
                    var e = edit; e.shadow = $0; model.updateEditSettings(e)
                } onCommit: {
                    var e = edit; e.shadow = $0; model.updateEditSettings(e); model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() }
            }

            Divider()

            Text("Motion").font(.headline)
            SliderRow(label: "Blur", value: edit.motionBlur, range: 0...1, suffix: "") {
                var e = edit; e.motionBlur = $0; model.updateEditSettings(e)
            } onCommit: {
                var e = edit; e.motionBlur = $0; model.updateEditSettings(e); model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            Toggle("Preview motion blur", isOn: previewMotionBlurBinding)
                .help("Apply motion blur when the on-demand final preview frame is rendered.")
        }
    }

    private func stylesEqual(_ a: BackgroundStyle, _ b: BackgroundStyle) -> Bool { a == b }

    private var backgroundModeBinding: Binding<BackgroundMode> {
        Binding(
            get: {
                switch edit.background {
                case .none: return .none
                case .solid: return .solid
                case .gradient: return .gradient
                }
            },
            set: { mode in
                var e = edit
                switch mode {
                case .none:
                    e.background = .none
                case .solid:
                    if case .solid = e.background {} else {
                        e.background = .solid(red: 0.10, green: 0.10, blue: 0.12)
                    }
                case .gradient:
                    if case .gradient = e.background {} else {
                        e.background = .gradient(
                            top: BackgroundStyle.RGB(red: 0.18, green: 0.19, blue: 0.22),
                            bottom: BackgroundStyle.RGB(red: 0.08, green: 0.09, blue: 0.11)
                        )
                    }
                }
                model.updateEditSettings(e, recordUndo: true)
            }
        )
    }

    private var previewMotionBlurBinding: Binding<Bool> {
        Binding(
            get: { edit.previewMotionBlurEnabled },
            set: { enabled in
                var e = edit
                e.previewMotionBlurEnabled = enabled
                model.updateEditSettings(e, recordUndo: true)
            }
        )
    }

    @ViewBuilder
    private var backgroundColorControls: some View {
        switch edit.background {
        case .none:
            EmptyView()
        case .solid(let red, let green, let blue):
            ColorPicker("Solid color", selection: Binding(
                get: { Color(red: red, green: green, blue: blue) },
                set: { color in
                    let rgb = rgb(from: color)
                    var e = edit
                    e.background = .solid(red: rgb.red, green: rgb.green, blue: rgb.blue)
                    model.updateEditSettings(e, recordUndo: true)
                }
            ))
        case .gradient(let top, let bottom):
            VStack(alignment: .leading, spacing: 8) {
                ColorPicker("Gradient top", selection: Binding(
                    get: { top.color },
                    set: { color in
                        var e = edit
                        e.background = .gradient(top: rgb(from: color), bottom: bottom)
                        model.updateEditSettings(e, recordUndo: true)
                    }
                ))
                ColorPicker("Gradient bottom", selection: Binding(
                    get: { bottom.color },
                    set: { color in
                        var e = edit
                        e.background = .gradient(top: top, bottom: rgb(from: color))
                        model.updateEditSettings(e, recordUndo: true)
                    }
                ))
            }
        }
    }

    private func rgb(from color: Color) -> BackgroundStyle.RGB {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return BackgroundStyle.RGB(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent)
        )
    }

    private enum BackgroundMode: String, CaseIterable, Identifiable {
        case none, solid, gradient
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Video"
            case .solid: return "Solid"
            case .gradient: return "Gradient"
            }
        }
    }
}

private struct BackgroundSwatch: View {
    let name: String
    let style: BackgroundStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    switch style {
                    case .none:
                        Color.black
                        Image(systemName: "film")
                            .foregroundStyle(.white.opacity(0.8))
                    case .solid(let r, let g, let b):
                        Color(red: r, green: g, blue: b)
                    case .gradient(let top, let bot):
                        LinearGradient(colors: [top.color, bot.color], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.05), lineWidth: 2)
                )
                Text(name).font(.caption2)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CursorInspector: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cursor").font(.headline)
            Toggle("Show cursor", isOn: Binding(
                get: { session.edit.showCursor },
                set: { v in
                    var e = session.edit
                    e.showCursor = v
                    model.updateEditSettings(e, recordUndo: true)
                }))
            Toggle("Click ripples", isOn: Binding(
                get: { session.edit.showClickRipples },
                set: { v in
                    var e = session.edit
                    e.showClickRipples = v
                    model.updateEditSettings(e, recordUndo: true)
                }))

            Divider()

            Text("Style").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            Picker("Sprite", selection: Binding(
                get: { session.settings.cursorSprite },
                set: { value in
                    var settings = session.settings
                    settings.cursorSprite = value
                    model.updateSessionSettings(settings, recordUndo: true)
                }
            )) {
                ForEach(CursorSprite.allCases) { sprite in
                    Label(sprite.label, systemImage: sprite.symbolName).tag(sprite)
                }
            }

            if session.settings.cursorSprite == .custom {
                customCursorPicker
            }

            SliderRow(label: "Size", value: session.settings.cursorScale, range: 0.5...3.0, suffix: "x") {
                var settings = session.settings
                settings.cursorScale = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorScale = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            SliderRow(label: "Opacity", value: session.settings.cursorOpacity, range: 0.2...1.0, suffix: "") {
                var settings = session.settings
                settings.cursorOpacity = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorOpacity = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            Divider()

            Text("Motion").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            SliderRow(label: "Smoothing", value: session.settings.cursorSmoothing, range: 0...2.0, suffix: "") {
                var settings = session.settings
                settings.cursorSmoothing = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorSmoothing = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            SliderRow(label: "Window", value: session.settings.cursorSmoothingWindow, range: 0.05...0.9, suffix: "s") {
                var settings = session.settings
                settings.cursorSmoothingWindow = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorSmoothingWindow = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            SliderRow(label: "Spring", value: session.settings.cursorSpring, range: 0...1.0, suffix: "") {
                var settings = session.settings
                settings.cursorSpring = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorSpring = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            Divider()

            Text("Click feedback").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            Toggle("Pulse cursor on click", isOn: Binding(
                get: { session.settings.cursorClickPulse },
                set: { v in
                    var settings = session.settings
                    settings.cursorClickPulse = v
                    model.updateSessionSettings(settings, recordUndo: true)
                }
            ))

            if session.settings.cursorClickPulse {
                SliderRow(label: "Pulse", value: session.settings.cursorClickPulseStrength, range: 0...1.0, suffix: "") {
                    var settings = session.settings
                    settings.cursorClickPulseStrength = $0
                    model.updateSessionSettings(settings)
                } onCommit: {
                    var settings = session.settings
                    settings.cursorClickPulseStrength = $0
                    model.updateSessionSettings(settings)
                    model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() }
            }

            Divider()

            HStack(spacing: 16) {
                Stat(title: "Cursor samples", value: "\(session.cursorSamples.count)")
                Stat(title: "Clicks", value: "\(session.clicks.count)")
                Stat(title: "Keys", value: "\(session.keystrokes.count)")
            }
        }
    }

    @ViewBuilder
    private var customCursorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                customCursorThumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(customCursorTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let path = session.settings.customCursorPath {
                        Text(URL(fileURLWithPath: path).deletingLastPathComponent().path(percentEncoded: false))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Pick a transparent image (e.g. 64x64).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack {
                Button {
                    pickCustomCursor()
                } label: {
                    Label(session.settings.customCursorPath == nil ? "Choose Image…" : "Replace Image…",
                          systemImage: "photo.on.rectangle")
                }
                .controlSize(.small)
                if session.settings.customCursorPath != nil {
                    Button(role: .destructive) {
                        var settings = session.settings
                        settings.customCursorPath = nil
                        model.updateSessionSettings(settings, recordUndo: true)
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                Text("Hotspot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text("X")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { session.settings.customCursorHotspotX },
                        set: { v in
                            var s = session.settings
                            s.customCursorHotspotX = v
                            model.updateSessionSettings(s)
                        }
                    ),
                    in: 0...1
                )
                Text("Y")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { session.settings.customCursorHotspotY },
                        set: { v in
                            var s = session.settings
                            s.customCursorHotspotY = v
                            model.updateSessionSettings(s)
                        }
                    ),
                    in: 0...1
                )
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var customCursorTitle: String {
        if let path = session.settings.customCursorPath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "No custom cursor"
    }

    @ViewBuilder
    private var customCursorThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55))
            if let path = session.settings.customCursorPath,
               let img = CustomCursorImageCache.shared.image(for: path) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 42, height: 42)
    }

    private func pickCustomCursor() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Use as Cursor"
        panel.title = "Choose Cursor Image"
        if panel.runModal() == .OK, let url = panel.url {
            var settings = session.settings
            settings.customCursorPath = url.path
            settings.cursorSprite = .custom
            model.updateSessionSettings(settings, recordUndo: true)
        }
    }
}

private struct ExportInspector: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession

    private var renderer: ExportRenderer { model.renderer }
    private var outputDirectory: URL {
        session.exportDirectoryURL ?? session.rawVideoURL.deletingLastPathComponent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.headline)

            summaryCard

            Divider()

            Text("Encoding").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            Picker("Resolution", selection: resolutionBinding) {
                ForEach(ResolutionPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }

            SliderRow(label: "Bitrate", value: session.settings.bitrateMbps, range: 4...80, suffix: " Mbps") {
                var s = session.settings
                s.bitrateMbps = $0
                model.updateSessionSettings(s)
            } onCommit: {
                var s = session.settings
                s.bitrateMbps = $0
                model.updateSessionSettings(s)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() }

            HStack {
                Text("Frame rate").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text("\(session.settings.frameRate) fps")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Format").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text("MP4 (H.264 High)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Destination").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(outputDirectory.path(percentEncoded: false))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button {
                        chooseExportDestination()
                    } label: {
                        Label("Choose…", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.small)

                    Button {
                        NSWorkspace.shared.open(outputDirectory)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)

                    if session.exportDirectoryURL != nil {
                        Button {
                            model.setExportDirectory(nil)
                        } label: {
                            Label("Reset", systemImage: "arrow.uturn.backward")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            if renderer.isRendering {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: renderer.progress)
                    Text(renderer.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.exportRendered()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(renderer.isRendering)
            }

            Button {
                model.previewCache.renderAll(session: session, renderer: renderer)
            } label: {
                Label("Pre-render preview cache", systemImage: "film.stack")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .help("Pre-render frames so the editor's Final Preview plays back smoothly")

            if let rendered = session.renderedVideoURL {
                renderedFileCard(url: rendered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Stat(title: "Duration", value: timecode(session.approximateDuration))
                Stat(title: "Resolution", value: "\(session.width)×\(session.height)")
            }
            HStack(spacing: 14) {
                Stat(title: "Zooms", value: "\(session.zooms.count)")
                Stat(title: "Frame rate", value: "\(session.settings.frameRate) fps")
            }
        }
    }

    private var resolutionBinding: Binding<ResolutionPreset> {
        Binding(
            get: { session.settings.resolutionPreset },
            set: { value in
                var s = session.settings
                s.resolutionPreset = value
                model.updateSessionSettings(s, recordUndo: true)
            }
        )
    }

    private func chooseExportDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Destination"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.setExportDirectory(url)
        }
    }

    @ViewBuilder
    private func renderedFileCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last export").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = fileSize(at: url) {
                        Text(size)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    model.revealRenderedFile()
                } label: {
                    Label("Reveal", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open", systemImage: "play.rectangle")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func fileSize(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size.int64Value)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SliderRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let onChange: (Double) -> Void
    var onCommit: ((Double) -> Void)? = nil
    var onBegin: (() -> Void)? = nil
    @State private var draftValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text("\(draftValue ?? value, specifier: range.upperBound > 10 ? "%.0f" : "%.2f")\(suffix)")
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(
                value: Binding(
                    get: { draftValue ?? value },
                    set: { newValue in
                        draftValue = newValue
                        onChange(newValue)
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        draftValue = value
                        onBegin?()
                    } else {
                        let final = draftValue ?? value
                        onCommit?(final)
                        draftValue = nil
                    }
                }
            )
        }
    }
}

// MARK: - Helpers

private func activeRipples(at time: Double, clicks: [MouseClickEvent]) -> [RippleEvent] {
    let window = ExportRippleParams.window
    return clicks.compactMap { click in
        let elapsed = time - click.time
        guard elapsed >= 0, elapsed <= window else { return nil }
        return RippleEvent(id: click.id, x: click.x, y: click.y, elapsed: elapsed)
    }
}

private func timecode(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let m = Int(total) / 60
    let s = Int(total) % 60
    let ms = Int((total - floor(total)) * 100)
    return String(format: "%02d:%02d.%02d", m, s, ms)
}

// MARK: - Key event catcher

struct KeyEventCatcher: NSViewRepresentable {
    enum Key {
        case space, leftArrow, rightArrow, shiftLeft, shiftRight, home, end, z, s, c, duplicateZoom, delete, undo, redo
    }

    let action: (Key) -> Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.handler = action
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.handler = action
    }
}

final class KeyCatcherView: NSView {
    var handler: ((KeyEventCatcher.Key) -> Bool)?
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installMonitor()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let handler = self.handler else { return event }
            // Only handle events delivered to our window (not the recorder window or any other).
            guard let window = self.window, event.window === window, window.isKeyWindow else {
                return event
            }
            // Don't intercept keys when a text field has focus.
            if let firstResponder = window.firstResponder,
               firstResponder.isKind(of: NSTextView.self) || firstResponder.isKind(of: NSText.self) {
                return event
            }
            let chars = event.charactersIgnoringModifiers ?? ""
            let cmd = event.modifierFlags.contains(.command)
            let control = event.modifierFlags.contains(.control)
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 49: if handler(.space) { return nil }
            case 123: if handler(shift ? .shiftLeft : .leftArrow) { return nil }
            case 124: if handler(shift ? .shiftRight : .rightArrow) { return nil }
            case 115: if handler(.home) { return nil }
            case 119: if handler(.end) { return nil }
            case 51, 117: if handler(.delete) { return nil }
            default:
                let dup = PreferencesStore.shared.preferences.duplicateZoomEditorHotkey
                if dup.matchesKeyDown(event), handler(.duplicateZoom) { return nil }
                if (cmd || control), chars.lowercased() == "z" {
                    if handler(shift ? .redo : .undo) { return nil }
                }
                if cmd { break }
                if chars.lowercased() == "z" { if handler(.z) { return nil } }
                if chars.lowercased() == "s" { if handler(.s) { return nil } }
                if chars.lowercased() == "c" { if handler(.c) { return nil } }
            }
            return event
        }
    }
}
