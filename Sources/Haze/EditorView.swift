import AVFoundation
import AppKit
import AudioToolbox
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor entry

struct EditorView: View {
    @EnvironmentObject private var model: AppViewModel
    @StateObject private var playback = EditorPlaybackHolder()
    @State private var inspectorTab: InspectorTab = .zooms
    @State private var isPreviewFullscreen: Bool = false
    @State private var fullscreenControlsVisible: Bool = true
    @State private var fullscreenHideTask: Task<Void, Never>?

    enum InspectorTab: Hashable, CaseIterable {
        case zooms, polish, cursor, export

        var title: String {
            switch self {
            case .zooms:  return "Zoom"
            case .polish: return "Background"
            case .cursor: return "Cursor"
            case .export: return "Export"
            }
        }

        var icon: String {
            switch self {
            case .zooms:  return "plus.magnifyingglass"
            case .polish: return "photo"
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
                    }
                    .onChange(of: session.rawVideoURL) { _, newURL in
                        playback.ensure(url: newURL)
                    }
            } else {
                ContentUnavailableView(
                    "No recording loaded",
                    systemImage: "film",
                    description: Text("Record something in the recorder window first.")
                )
            }
        }
        .background(Color.frBackground)
        .alert("Haze", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func content(session: RecordingSession) -> some View {
        let timelineIndex = RenderTimelineIndex(session: session)
        VStack(spacing: 0) {
            if !isPreviewFullscreen {
                EditorTopBar(session: session)
                    .environmentObject(model)
            }
            if isPreviewFullscreen {
                if let controller = playback.controller {
                    fullscreenContent(session: session, controller: controller)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HSplitView {
                    VStack(spacing: 8) {
                        if let controller = playback.controller {
                            VStack(spacing: 0) {
                                EditorPreview(
                                    session: session,
                                    timelineIndex: timelineIndex,
                                    controller: controller,
                                    playbackTime: $model.playbackTime,
                                    selectedZoomID: $model.selectedZoomID
                                )
                                .environmentObject(model)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                Rectangle()
                                    .fill(Color.frBorder.opacity(0.4))
                                    .frame(height: 1)

                                VideoControlBar(
                                    session: session,
                                    controller: controller,
                                    playbackTime: $model.playbackTime,
                                    isPreviewFullscreen: $isPreviewFullscreen,
                                    onToggleFullscreen: { togglePreviewFullscreen() }
                                )
                            }
                            .background(Color.frPanel)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.frBorder.opacity(0.5), lineWidth: 1)
                            )

                            TimelinePanel(
                                session: session,
                                controller: controller,
                                playbackTime: $model.playbackTime,
                                selectedZoomID: $model.selectedZoomID
                            )
                            .environmentObject(model)
                            .frame(height: 200)
                            .background(Color.frPanel)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.frBorder.opacity(0.5), lineWidth: 1)
                            )
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
                    .padding(.leading, 8)
                    .padding(.vertical, 8)
                    .padding(.trailing, 4)
                    .frame(minWidth: 720)

                    Inspector(tab: $inspectorTab, session: session, controller: playback.controller)
                        .environmentObject(model)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.frBorder.opacity(0.5), lineWidth: 1)
                        )
                        .padding(.leading, 4)
                        .padding(.trailing, 8)
                        .padding(.vertical, 8)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
                }
            }
        }
        .focusedSceneValue(\.editorActive, true)
        .background(KeyEventCatcher(action: handleKey(_:)))
    }

    @ViewBuilder
    private func fullscreenContent(session: RecordingSession, controller: PlaybackController) -> some View {
        let timelineIndex = RenderTimelineIndex(session: session)
        ZStack {
            Color.black.ignoresSafeArea()
            EditorPreview(
                session: session,
                timelineIndex: timelineIndex,
                controller: controller,
                playbackTime: $model.playbackTime,
                selectedZoomID: $model.selectedZoomID
            )
            .environmentObject(model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if fullscreenControlsVisible {
                VStack {
                    Spacer()
                    FullscreenControlBar(
                        session: session,
                        controller: controller,
                        playbackTime: $model.playbackTime,
                        onExit: { togglePreviewFullscreen() }
                    )
                    .padding(.bottom, 32)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showFullscreenControls()
            case .ended:
                break
            }
        }
        .onAppear { showFullscreenControls() }
    }

    private func showFullscreenControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            fullscreenControlsVisible = true
        }
        fullscreenHideTask?.cancel()
        fullscreenHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled, isPreviewFullscreen {
                withAnimation(.easeInOut(duration: 0.25)) {
                    fullscreenControlsVisible = false
                }
            }
        }
    }

    private func togglePreviewFullscreen() {
        let entering = !isPreviewFullscreen
        withAnimation(.easeInOut(duration: 0.2)) {
            isPreviewFullscreen = entering
        }
        if entering {
            showFullscreenControls()
        } else {
            fullscreenHideTask?.cancel()
            fullscreenControlsVisible = true
        }
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
        case .f:
            togglePreviewFullscreen()
            return true
        case .escape:
            if isPreviewFullscreen {
                togglePreviewFullscreen()
                return true
            }
            return false
        case .z:
            model.addZoomAtPlayhead()
            return true
        case .duplicateZoom:
            model.duplicateSelectedZoom()
            return true
        case .selectAllZooms:
            model.selectAllZooms()
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

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.rawVideoURL.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.frPrimaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.rawVideoURL.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.frSecondaryText)
                        .lineLimit(1)
                    Text("•")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.frBorder)
                    Text("Saved")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.frSecondaryText)
                }
            }
            Spacer()

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(model.canUndo ? Color.frSecondaryText : Color.frBorder)
            }
            .help("Undo (⌘Z)")
            .disabled(!model.canUndo)
            .buttonStyle(.plain)

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .foregroundStyle(model.canRedo ? Color.frSecondaryText : Color.frBorder)
            }
            .help("Redo (⌘⇧Z)")
            .disabled(!model.canRedo)
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.frBorder)
                .frame(width: 1, height: 22)

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
                    Label("Reveal in Finder", systemImage: "doc.on.doc")
                }
                .help(rendered.lastPathComponent)
                .buttonStyle(.bordered)
                .tint(Color.frSecondaryText)
            }

            Button {
                model.exportRendered()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.renderer.isRendering)
            .buttonStyle(.borderedProminent)
            .tint(Color.frAccent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 0)
    }
}

// MARK: - Preview area

private struct EditorPreview: View {
    let session: RecordingSession
    let timelineIndex: RenderTimelineIndex
    @ObservedObject var controller: PlaybackController
    @Binding var playbackTime: Double
    @Binding var selectedZoomID: UUID?

    var body: some View {
        ZStack {
            background
            GeometryReader { proxy in
                framedVideo(in: proxy.size)
            }
        }
        .clipped()
        .onChange(of: controller.currentTime) { _, newTime in
            if abs(newTime - playbackTime) > 0.005 {
                playbackTime = newTime
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
        case .image(let path):
            if let image = EditorBackgroundImageCache.shared.image(for: path) {
                BackgroundImageView(
                    image: image,
                    fit: session.edit.imageFit,
                    focusX: session.edit.imageFocusX,
                    focusY: session.edit.imageFocusY,
                    fallbackColor: .black
                )
            } else {
                Color.black
            }
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
        let radius = videoOnly ? 0 : max(0, CGFloat(session.edit.cornerRadius)) * min(frameW, frameH) * 1.4
        let renderState = RenderFrameStateBuilder.make(
            timelineIndex: timelineIndex,
            outputTime: max(0, playbackTime - session.timelineContentStart),
            sourceTime: playbackTime,
            canvasSize: size
        )
        let live = CGFloat(renderState.zoom)
        let center = renderState.cameraCenter
        let panAmount = renderState.panAmount
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
        let cursorState = renderState.cursor
        // Drop the heavy SwiftUI shadow during playback. The static shadow is recomputed every
        // frame because of scaleEffect, which tanks FPS - especially at high resolutions.
        let isPlaying = controller.isPlaying
        let shadowRadius = videoOnly || isPlaying ? 0 : max(2, CGFloat(session.edit.shadow) * 30)
        let shadowOpacity = videoOnly || isPlaying ? 0 : session.edit.shadow * 0.6
        let shadowOffsetY = videoOnly || isPlaying ? 0 : max(0, CGFloat(session.edit.shadow) * 16)
        let motionBlurRadius = approximateMotionBlurRadius(
            state: renderState,
            frameSize: CGSize(width: frameW, height: frameH)
        )
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
                    let ratio = frameW / max(1, CGFloat(session.width))
                    ForEach(activeRipples(at: playbackTime, clicks: session.clicks)) { ripple in
                        RippleMarker(elapsed: ripple.elapsed, frameToSessionRatio: ratio)
                            .position(
                                x: ripple.x / Double(session.width) * frameW,
                                y: ripple.y / Double(session.height) * frameH
                            )
                            .allowsHitTesting(false)
                    }
                }
                if let cursorState {
                    CursorMarker(
                        sprite: session.settings.cursorSprite,
                        scale: cursorState.scale,
                        settings: session.settings,
                        systemShape: cursorState.shape,
                        springRotation: cursorState.rotation,
                        frameToSessionRatio: frameW / max(1, CGFloat(session.width))
                    )
                        .opacity(cursorState.opacity)
                        .position(
                            x: cursorState.position.x / Double(session.width) * frameW,
                            y: max(0, cursorState.position.y - CursorOverlay.renderVerticalLift) / Double(session.height) * frameH
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(width: frameW, height: frameH)
            .blur(radius: motionBlurRadius)
            .scaleEffect(live, anchor: .center)
            .offset(layerOffset)
        }
        .frame(width: size.width, height: size.height)
    }

    private func approximateMotionBlurRadius(state: RenderFrameState, frameSize: CGSize) -> CGFloat {
        let strength = state.motionBlurAmount
        guard strength > 0.001 else { return 0 }

        let frameDuration = 1.0 / Double(max(1, session.settings.frameRate))
        let before = RenderFrameStateBuilder.make(
            timelineIndex: timelineIndex,
            outputTime: max(0, state.outputTime - frameDuration * 0.5),
            sourceTime: max(0, state.sourceTime - frameDuration * 0.5),
            canvasSize: state.canvasSize
        )
        let after = RenderFrameStateBuilder.make(
            timelineIndex: timelineIndex,
            outputTime: state.outputTime + frameDuration * 0.5,
            sourceTime: min(session.approximateDuration, state.sourceTime + frameDuration * 0.5),
            canvasSize: state.canvasSize
        )
        let scale = min(
            frameSize.width / max(1, CGFloat(session.width)),
            frameSize.height / max(1, CGFloat(session.height))
        )
        let cameraDelta = hypot(after.cameraCenter.x - before.cameraCenter.x, after.cameraCenter.y - before.cameraCenter.y) * scale
        let cursorDelta: CGFloat
        if let a = before.cursor?.position, let b = after.cursor?.position {
            cursorDelta = hypot(b.x - a.x, b.y - a.y) * scale
        } else {
            cursorDelta = 0
        }
        let zoomDelta = CGFloat(abs(after.zoom - before.zoom)) * min(frameSize.width, frameSize.height) * 0.45
        let radius = (cameraDelta * 0.06 + cursorDelta * 0.035 + zoomDelta) * CGFloat(strength)
        return radius > 0.18 ? min(9, radius) : 0
    }
}

/// Renders a cached editor background image constrained to the offered size with explicit fit + focal-point control.
/// Wraps the image in its own clipped GeometryReader so the image can never push its parent
/// container's frame larger than what was offered (which previously caused the background image
/// to overflow into the timeline / inspector).
private struct EditorBackgroundImage {
    let cgImage: CGImage

    var size: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }
}

private final class EditorBackgroundImageCache {
    static let shared = EditorBackgroundImageCache()

    private struct Entry {
        let image: EditorBackgroundImage
        let modificationDate: Date?
    }

    private let maxPixelSize = 2560
    private var entries: [String: Entry] = [:]

    func image(for path: String) -> EditorBackgroundImage? {
        guard !path.isEmpty else { return nil }
        let modificationDate = Self.modificationDate(for: path)
        if let cached = entries[path], cached.modificationDate == modificationDate {
            return cached.image
        }

        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            entries.removeValue(forKey: path)
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            entries.removeValue(forKey: path)
            return nil
        }

        if entries.count > 8 {
            entries.removeAll(keepingCapacity: true)
        }

        let image = EditorBackgroundImage(cgImage: cgImage)
        entries[path] = Entry(image: image, modificationDate: modificationDate)
        return image
    }

    private static func modificationDate(for path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}

private struct BackgroundImageView: View {
    let image: EditorBackgroundImage
    let fit: BackgroundImageFit
    let focusX: Double
    let focusY: Double
    var fallbackColor: Color = .black

    var body: some View {
        GeometryReader { proxy in
            let containerW = proxy.size.width
            let containerH = proxy.size.height
            let imgSize = image.size
            let imgAspect = imgSize.width / max(0.0001, imgSize.height)
            let containerAspect = containerW / max(0.0001, containerH)

            ZStack {
                fallbackColor

                let (scaledW, scaledH): (CGFloat, CGFloat) = {
                    switch fit {
                    case .fill:
                        if imgAspect > containerAspect {
                            // Image wider than container — fit to height, crop sides.
                            return (containerH * imgAspect, containerH)
                        } else {
                            return (containerW, containerW / imgAspect)
                        }
                    case .fit:
                        if imgAspect > containerAspect {
                            return (containerW, containerW / imgAspect)
                        } else {
                            return (containerH * imgAspect, containerH)
                        }
                    }
                }()

                let overflowX = scaledW - containerW
                let overflowY = scaledH - containerH
                let fx = CGFloat(min(max(focusX, 0), 1))
                let fy = CGFloat(min(max(focusY, 0), 1))
                let centerX = overflowX > 0
                    ? containerW / 2 + overflowX * (0.5 - fx)
                    : containerW / 2
                let centerY = overflowY > 0
                    ? containerH / 2 + overflowY * (0.5 - fy)
                    : containerH / 2

                Image(image.cgImage, scale: 1, label: Text(""))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: scaledW, height: scaledH)
                    .position(x: centerX, y: centerY)
            }
            .frame(width: containerW, height: containerH)
            .clipped()
        }
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

// MARK: - Fullscreen control bar

private struct FullscreenControlBar: View {
    let session: RecordingSession
    @ObservedObject var controller: PlaybackController
    @Binding var playbackTime: Double
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(timecode(max(0, playbackTime - session.timelineContentStart)))
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize()

            scrubSlider

            Text(timecode(session.timelineVisibleDuration))
                .font(.system(size: 13, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .fixedSize()

            iconButton(systemImage: "backward.frame.fill", help: "Frame back (←)") {
                controller.pause()
                controller.step(by: -1)
                playbackTime = controller.currentTime
            }

            Button {
                controller.togglePlay()
            } label: {
                ZStack {
                    Circle().fill(Color.white)
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: controller.isPlaying ? 0 : 1)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .help("Play/Pause (Space)")

            iconButton(systemImage: "forward.frame.fill", help: "Frame forward (→)") {
                controller.pause()
                controller.step(by: 1)
                playbackTime = controller.currentTime
            }

            iconButton(systemImage: "arrow.down.right.and.arrow.up.left", help: "Exit fullscreen (F / Esc)", action: onExit)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
        .frame(maxWidth: 1100)
        .padding(.horizontal, 32)
    }

    private var scrubSlider: some View {
        let start = session.timelineContentStart
        let end = max(start + 0.001, session.timelineContentEnd)
        let binding = Binding<Double>(
            get: { min(max(playbackTime, start), end) },
            set: { newValue in
                let clamped = min(max(newValue, start), end)
                playbackTime = clamped
                controller.pause()
                controller.seek(to: clamped, precise: false)
            }
        )
        return Slider(value: binding, in: start...end)
            .controlSize(.small)
            .tint(.white)
            .frame(minWidth: 320)
    }

    private func iconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Video control bar

private struct VideoControlBar: View {
    let session: RecordingSession
    @ObservedObject var controller: PlaybackController
    @Binding var playbackTime: Double
    @Binding var isPreviewFullscreen: Bool
    let onToggleFullscreen: () -> Void
    @State private var audioVolume: Double = 1.0

    var body: some View {
        HStack(spacing: 16) {
            timeReadout
            Spacer(minLength: 8)
            transportCluster
            Spacer(minLength: 8)
            rightControls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onChange(of: controller.currentTime) { _, newTime in
            if abs(newTime - playbackTime) > 0.005 { playbackTime = newTime }
        }
        .onChange(of: playbackTime) { _, newValue in
            if !controller.isPlaying, abs(newValue - controller.currentTime) > 0.05 {
                controller.seek(to: newValue)
            }
        }
    }

    private var timeReadout: some View {
        HStack(spacing: 6) {
            Text(timecode(max(0, playbackTime - session.timelineContentStart)))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.frPrimaryText)
            Text("/")
                .font(.system(size: 13))
                .foregroundStyle(Color.frBorder)
            Text(timecode(session.timelineVisibleDuration))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Color.frSecondaryText)
        }
        .fixedSize()
    }

    private var transportCluster: some View {
        HStack(spacing: 6) {
            transportBtn("backward.end.fill", help: "Jump to start") {
                controller.seek(to: session.timelineContentStart)
                playbackTime = controller.currentTime
            }
            transportBtn("backward.frame.fill", help: "Frame back (←)") {
                controller.pause(); controller.step(by: -1)
                playbackTime = controller.currentTime
            }
            Button { controller.togglePlay() } label: {
                ZStack {
                    Circle().fill(Color.white)
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: controller.isPlaying ? 0 : 1)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Play/Pause (Space)")
            .padding(.horizontal, 6)
            transportBtn("forward.frame.fill", help: "Frame forward (→)") {
                controller.pause(); controller.step(by: 1)
                playbackTime = controller.currentTime
            }
            transportBtn("forward.end.fill", help: "Jump to end") {
                controller.seek(to: max(session.timelineContentStart, session.timelineContentEnd - 0.02))
                playbackTime = controller.currentTime
            }
        }
        .fixedSize()
    }

    private var rightControls: some View {
        HStack(spacing: 10) {
            Image(systemName: audioVolume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.frSecondaryText)

            Slider(value: $audioVolume, in: 0...1)
                .controlSize(.small)
                .tint(Color.frAccent)
                .frame(width: 80)
                .onChange(of: audioVolume) { _, v in
                    controller.player.volume = Float(v)
                }

            Button(action: onToggleFullscreen) {
                Image(systemName: isPreviewFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.frSecondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPreviewFullscreen ? "Exit fullscreen (F / Esc)" : "Fullscreen (F)")
        }
    }

    private func transportBtn(_ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.frSecondaryText)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Timeline

private struct TimelinePanel: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession
    @ObservedObject var controller: PlaybackController
    @Binding var playbackTime: Double
    @Binding var selectedZoomID: UUID?
    @State private var filmstripSelected = false
    @State private var timelineZoomScale: Double = 1.0
    @State private var timelineViewportWidth: Double = 800
    @State private var snapToPlayhead = true

    var body: some View {
        VStack(spacing: 10) {
            timelineActionBar
            GeometryReader { proxy in
                let viewportWidth = max(1, proxy.size.width)
                let timelineWidth = baseTimelineWidth(for: viewportWidth) * timelineZoomScale
                ScrollViewReader { _ in
                    ScrollView(.horizontal, showsIndicators: true) {
                        timelineTracks(width: timelineWidth)
                            .frame(width: timelineWidth)
                    }
                }
                .onAppear {
                    timelineViewportWidth = viewportWidth
                }
                .onChange(of: viewportWidth) { _, newValue in
                    timelineViewportWidth = newValue
                }
            }
            .frame(height: 112)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var timelineActionBar: some View {
        HStack(spacing: 2) {
            let canRegenerate = model.canRegenerateAutomaticZooms(in: session)
            timelineLabelButton(systemImage: "plus", title: "Add Zoom", help: "Add zoom at playhead (Z)", disabled: false) {
                model.addZoomAtPlayhead()
            }
            timelineLabelButton(
                systemImage: "sparkles",
                title: "Auto",
                help: canRegenerate ? "Regenerate automatic zooms" : "No click or cursor-dwell signals in the visible timeline",
                disabled: !canRegenerate
            ) {
                model.regenerateAutomaticZooms()
            }
            timelineLabelButton(systemImage: "plus.square.on.square", title: "Duplicate", help: "Duplicate selected zoom", disabled: !model.hasSelectedZooms) {
                model.duplicateSelectedZoom()
            }
            timelineLabelButton(systemImage: "scissors", title: "Cut", help: "Cut selected zooms", disabled: !model.hasSelectedZooms) {
                model.cutSelectedZooms()
            }
            timelineLabelButton(systemImage: "trash", title: "Delete", help: "Delete selected zooms", disabled: !model.hasSelectedZooms, role: .destructive) {
                model.deleteSelectedZooms()
            }

            Rectangle()
                .fill(Color.frBorder)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 6)

            timelineLabelButton(
                systemImage: "square.split.2x1",
                title: "Split",
                help: filmstripSelected ? "Split selected clip at playhead" : "Split zoom at playhead (S)",
                disabled: false
            ) {
                splitTimelineSelection()
            }
            timelineLabelButton(
                systemImage: "arrow.left.and.right",
                title: "Snap",
                help: snapToPlayhead ? "Disable snapping to playhead" : "Enable snapping to playhead",
                disabled: false,
                active: snapToPlayhead
            ) {
                snapToPlayhead.toggle()
            }

            Spacer()

            timelineZoomControls
        }
    }

    private func timelineLabelButton(
        systemImage: String,
        title: String,
        help: String,
        disabled: Bool,
        active: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    disabled ? AnyShapeStyle(Color.frBorder) :
                    role == .destructive ? AnyShapeStyle(Color.red.opacity(0.8)) :
                    active ? AnyShapeStyle(Color.frAccent) :
                    AnyShapeStyle(Color.frSecondaryText)
                )
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.frAccent.opacity(0.14) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(title)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }

    private var timelineZoomControls: some View {
        HStack(spacing: 4) {
            Button {
                timelineZoomScale = max(0.5, (timelineZoomScale - 0.25).rounded(toPlaces: 2))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom timeline out")

            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)

            Slider(value: $timelineZoomScale, in: 0.5...4)
                .controlSize(.mini)
                .frame(width: 110)
                .help("Timeline horizontal zoom")

            Button {
                fitTimelineToViewport()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(timelineIsFitToViewport ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(timelineIsFitToViewport)
            .help("Fit timeline to visible area")

            Button {
                timelineZoomScale = 1
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(abs(timelineZoomScale - 1) < 0.001 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(abs(timelineZoomScale - 1) < 0.001)
            .help("Reset timeline zoom")

            Button {
                timelineZoomScale = min(4, (timelineZoomScale + 0.25).rounded(toPlaces: 2))
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom timeline in")

            Text("\(timelineZoomScale, specifier: "%.1f")×")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .padding(.leading, 2)
        }
    }

    private func baseTimelineWidth(for viewportWidth: Double) -> Double {
        max(800, viewportWidth)
    }

    private var timelineFitScale: Double {
        let viewportWidth = max(1, timelineViewportWidth)
        let scale = viewportWidth / baseTimelineWidth(for: viewportWidth)
        return min(4, max(0.5, scale)).rounded(toPlaces: 2)
    }

    private var timelineIsFitToViewport: Bool {
        abs(timelineZoomScale - timelineFitScale) < 0.001
    }

    private func fitTimelineToViewport() {
        timelineZoomScale = timelineFitScale
    }

    private func splitTimelineSelection() {
        if filmstripSelected {
            model.splitClipAtPlayhead()
        } else {
            model.splitZoomAtPlayhead()
        }
    }

    private func timelineTracks(width: Double) -> some View {
        VStack(spacing: 6) {
            let timeline = TimelineCoordinateMap(
                sourceStart: session.timelineContentStart,
                sourceEnd: session.timelineContentEnd,
                width: width
            )
            ZStack(alignment: .topLeading) {
                VStack(spacing: 5) {
                    ClickTrack(
                        clicks: session.clicks,
                        keystrokes: session.keystrokes,
                        timeline: timeline,
                        height: 14
                    )
                        .contentShape(Rectangle())
                        .gesture(scrubGesture(timeline: timeline))
                    FilmstripTimelineTrack(
                        session: session,
                        timeline: timeline,
                        height: 38,
                        filmstripSelected: $filmstripSelected,
                        onScrubBegan: {},
                        scrubTo: { t in
                            playbackTime = t
                            controller.pause()
                            controller.seek(to: t, precise: false)
                        },
                        onScrubEnded: {},
                        onSelectFilmstrip: {
                            filmstripSelected = true
                            model.selectOnlyZoom(nil)
                        }
                    )
                    ZoomTrack(
                        zooms: session.zooms,
                        timeline: timeline,
                        playheadTime: playbackTime,
                        snapToPlayhead: snapToPlayhead,
                        height: 38,
                        selectedZoomID: $selectedZoomID,
                        selectedZoomIDs: $model.selectedZoomIDs,
                        selectZoom: { id, extending in
                            filmstripSelected = false
                            model.selectZoom(id, extending: extending)
                        },
                        deselectZooms: {
                            filmstripSelected = false
                            model.selectOnlyZoom(nil)
                        },
                        onBegin: { model.beginUndoTransaction() },
                        onChange: { model.updateZoom($0) },
                        onChangeMany: { model.updateZooms($0) },
                        onEnd: { model.endUndoTransaction() }
                    )
                }
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: timeline.timeToX(playbackTime))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: 112)
    }

    private func scrubGesture(timeline: TimelineCoordinateMap) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = timeline.xToTime(Double(value.location.x))
                playbackTime = t
                controller.pause()
                controller.seek(to: t, precise: false)
            }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - Tracks

/// Maps between absolute source-video time and the trimmed timeline's visible x-axis.
///
/// RecordingSession zoom/cursor/click times are stored in absolute source time. UI labels can
/// display output-relative time by subtracting `sourceStart`, but drawing and dragging stay in
/// source time so preview/export continue to read the same model data.
private struct TimelineCoordinateMap {
    let sourceStart: Double
    let sourceEnd: Double
    let width: Double

    var visibleDuration: Double {
        max(0.001, sourceEnd - sourceStart)
    }

    func timeToX(_ sourceTime: Double) -> Double {
        let fraction = (sourceTime - sourceStart) / visibleDuration
        return min(max(0, fraction * width), width)
    }

    func xToTime(_ x: Double) -> Double {
        let fraction = min(max(0, x / max(1, width)), 1)
        return sourceStart + fraction * visibleDuration
    }

    func deltaXToTime(_ deltaX: Double) -> Double {
        deltaX / max(1, width) * visibleDuration
    }

    func outputTime(forSourceTime sourceTime: Double) -> Double {
        max(0, sourceTime - sourceStart)
    }

    func intersects(sourceStart start: Double, sourceEnd end: Double) -> Bool {
        start < sourceEnd && end > sourceStart
    }

    func xRange(sourceStart start: Double, sourceEnd end: Double, minimumWidth: Double = 0) -> (x: Double, width: Double) {
        let clampedStart = min(max(start, sourceStart), sourceEnd)
        let clampedEnd = min(max(end, sourceStart), sourceEnd)
        let rawX = timeToX(clampedStart)
        let rawWidth = max(0, timeToX(clampedEnd) - rawX)
        let displayWidth = min(width, max(minimumWidth, rawWidth))
        let displayX = min(max(0, rawX), max(0, width - displayWidth))
        return (displayX, displayWidth)
    }
}

private struct FilmstripTimelineTrack: View {
    @EnvironmentObject var model: AppViewModel
    let session: RecordingSession
    let timeline: TimelineCoordinateMap
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
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ThumbnailStrip(
                    url: session.rawVideoURL,
                    startTime: timeline.sourceStart,
                    endTime: timeline.sourceEnd,
                    width: timeline.width,
                    height: height
                )
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    WaveformFilmstripOverlay(
                        url: session.rawVideoURL,
                        startTime: timeline.sourceStart,
                        endTime: timeline.sourceEnd,
                        width: timeline.width
                    )
                        .frame(height: max(12, height * 0.34))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        filmstripSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.14),
                        lineWidth: filmstripSelected ? 1.5 : 1
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(filmstripSelected ? 0.12 : 0))
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coord))
                    .onChanged { value in
                        if !filmstripSelected {
                            onSelectFilmstrip()
                        }
                        let flags = NSApp.currentEvent?.modifierFlags ?? []
                        if flags.contains(.option) {
                            if slipAnchor == nil {
                                guard let s = model.currentSession else { return }
                                slipAnchor = (s.timelineTrimStart, s.timelineTrimEnd)
                                model.beginUndoTransaction()
                            }
                            if let slipAnchor {
                                let slip = timeline.deltaXToTime(Double(value.translation.width))
                                model.updateTimelineTrims(
                                    trimStart: slipAnchor.trimStart + slip,
                                    trimEnd: slipAnchor.trimEnd - slip,
                                    recordUndo: false
                                )
                            }
                            return
                        }
                        onScrubBegan()
                        let t = timeline.xToTime(Double(value.location.x))
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

            TrimEdgeHandleView(alignment: .leading)
                .frame(width: 32, height: height)
                .offset(x: 0)
                .highPriorityGesture(trimHandleGesture(kind: .leading))
            TrimEdgeHandleView(alignment: .trailing)
                .frame(width: 32, height: height)
                .offset(x: max(0, timeline.width - 32))
                .highPriorityGesture(trimHandleGesture(kind: .trailing))
        }
        .frame(width: timeline.width, height: height)
        .coordinateSpace(name: Self.coord)
        .help("Click to select. Drag trim handles to change clip length. Drag inside to scrub. ⌥ drag inside the clip to slip the edit window.")
    }

    private func trimHandleGesture(kind: TrimDragState.Kind) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coord))
            .onChanged { value in
                if trimDrag == nil {
                    if !filmstripSelected {
                        onSelectFilmstrip()
                    }
                    trimDrag = TrimDragState(
                        kind: kind,
                        anchorTrimStart: session.timelineTrimStart,
                        anchorTrimEnd: session.timelineTrimEnd,
                        startX: value.startLocation.x
                    )
                    model.beginUndoTransaction()
                }
                guard let drag = trimDrag else { return }
                let deltaT = timeline.deltaXToTime(Double(value.location.x - drag.startX))
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
    let alignment: Alignment

    var body: some View {
        ZStack(alignment: alignment) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
                .frame(width: 6, height: 24)
                .padding(.horizontal, 5)
        }
        .contentShape(Rectangle())
    }
}

private struct WaveformFilmstripOverlay: View {
    let url: URL
    let startTime: Double
    let endTime: Double
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
        .task(id: "\(url.path)-\(Int(startTime * 1000))-\(Int(endTime * 1000))-\(Int(width))") {
            let count = max(40, min(220, Int(width / 10)))
            let loaded = await WaveformBucketLoader.load(url: url, startTime: startTime, endTime: endTime, bucketCount: count)
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
    static func load(url: URL, startTime: Double, endTime: Double, bucketCount: Int) async -> [CGFloat] {
        let duration = max(0, endTime - startTime)
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
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: max(0, startTime), preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
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
    let startTime: Double
    let endTime: Double
    let width: Double
    let height: Double
    @State private var thumbnails: [CGImage] = []
    @State private var loadKey: String = ""

    private static let targetMaximumSize = CGSize(width: 200, height: 120)

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
        .task(id: "\(url.path)-\(Int(startTime * 1000))-\(Int(endTime * 1000))-\(Int(width))") {
            await loadThumbnails()
        }
    }

    private func loadThumbnails() async {
        let duration = max(0.001, endTime - startTime)
        let count = max(8, min(40, Int(width / 90)))
        let cacheKey = ThumbnailImageCache.Key(
            url: url,
            startTime: startTime,
            endTime: endTime,
            thumbnailCount: count,
            targetMaximumSize: Self.targetMaximumSize
        )
        let key = cacheKey.loadIdentifier(width: width)
        loadKey = key
        if let cached = await ThumbnailImageCache.shared.images(for: cacheKey) {
            if !Task.isCancelled, loadKey == key {
                thumbnails = cached
            }
            return
        }
        let times: [CMTime] = (0..<count).map { i in
            CMTime(seconds: startTime + duration * Double(i) / Double(max(1, count - 1)),
                   preferredTimescale: 600)
        }
        let maximumSize = Self.targetMaximumSize
        let images = await Task.detached(priority: .utility) { () -> [CGImage] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maximumSize
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
        await ThumbnailImageCache.shared.store(images, for: cacheKey)
        if !Task.isCancelled, loadKey == key {
            thumbnails = images
        }
    }
}

private actor ThumbnailImageCache {
    static let shared = ThumbnailImageCache()

    struct Key: Hashable {
        let path: String
        let modificationDate: TimeInterval
        let fileSize: UInt64
        let startBucket: Int
        let endBucket: Int
        let thumbnailCount: Int
        let maxWidth: Int
        let maxHeight: Int

        init(
            url: URL,
            startTime: Double,
            endTime: Double,
            thumbnailCount: Int,
            targetMaximumSize: CGSize
        ) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modificationDate = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

            self.path = url.path
            self.modificationDate = modificationDate
            self.fileSize = fileSize
            self.startBucket = Int((startTime * 1000).rounded())
            self.endBucket = Int((endTime * 1000).rounded())
            self.thumbnailCount = thumbnailCount
            self.maxWidth = Int(targetMaximumSize.width.rounded())
            self.maxHeight = Int(targetMaximumSize.height.rounded())
        }

        func loadIdentifier(width: Double) -> String {
            "\(path)-\(modificationDate)-\(fileSize)-\(startBucket)-\(endBucket)-\(thumbnailCount)-\(maxWidth)x\(maxHeight)-\(Int(width))"
        }
    }

    private let entryLimit = 24
    private var entries: [Key: [CGImage]] = [:]
    private var accessOrder: [Key] = []

    func images(for key: Key) -> [CGImage]? {
        guard let images = entries[key] else { return nil }
        markUsed(key)
        return images
    }

    func store(_ images: [CGImage], for key: Key) {
        guard !images.isEmpty else { return }
        entries[key] = images
        markUsed(key)
        while accessOrder.count > entryLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    private func markUsed(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

private struct ClickTrack: View {
    let clicks: [MouseClickEvent]
    let keystrokes: [KeystrokeEvent]
    let timeline: TimelineCoordinateMap
    let height: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.frPanel)
            ForEach(keystrokes.filter { $0.time >= timeline.sourceStart && $0.time <= timeline.sourceEnd }) { k in
                Rectangle()
                    .fill(Color.green.opacity(0.45))
                    .frame(width: 1.5, height: height - 6)
                    .offset(x: timeline.timeToX(k.time))
            }
            ForEach(clicks.filter { $0.time >= timeline.sourceStart && $0.time <= timeline.sourceEnd }) { c in
                Circle()
                    .fill(c.isRightClick ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: timeline.timeToX(c.time) - 3.5,
                            y: height / 2 - 3.5)
            }
        }
        .frame(width: timeline.width, height: height)
    }
}

private struct ZoomTrack: View {
    let zooms: [ZoomKeyframe]
    let timeline: TimelineCoordinateMap
    let playheadTime: Double
    let snapToPlayhead: Bool
    let height: Double
    @Binding var selectedZoomID: UUID?
    @Binding var selectedZoomIDs: Set<UUID>
    let selectZoom: (UUID, Bool) -> Void
    let deselectZooms: () -> Void
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onChangeMany: ([ZoomKeyframe]) -> Void
    let onEnd: () -> Void

    private static let coordinateName = "ZoomTrack.coordinateSpace"

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(zooms.filter { timeline.intersects(sourceStart: $0.start, sourceEnd: $0.start + $0.duration) }) { zoom in
                ZoomBlock(
                    zoom: zoom,
                    selectedZooms: selectedZoomsForDrag(anchor: zoom),
                    timeline: timeline,
                    playheadTime: playheadTime,
                    snapToPlayhead: snapToPlayhead,
                    height: height,
                    selected: selectedZoomIDs.contains(zoom.id) || selectedZoomID == zoom.id,
                    coordinateSpaceName: Self.coordinateName,
                    select: { extending in selectZoom(zoom.id, extending) },
                    onBegin: onBegin,
                    onChange: onChange,
                    onChangeMany: onChangeMany,
                    onEnd: onEnd
                )
            }
        }
        .frame(width: timeline.width, height: height, alignment: .topLeading)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { deselectZooms() }
        )
        .clipped()
        .coordinateSpace(name: Self.coordinateName)
    }

    private func selectedZoomsForDrag(anchor: ZoomKeyframe) -> [ZoomKeyframe] {
        guard selectedZoomIDs.contains(anchor.id), selectedZoomIDs.count > 1 else { return [] }
        return zooms.filter { selectedZoomIDs.contains($0.id) }
    }
}

private struct ZoomBlock: View {
    let zoom: ZoomKeyframe
    let selectedZooms: [ZoomKeyframe]
    let timeline: TimelineCoordinateMap
    let playheadTime: Double
    let snapToPlayhead: Bool
    let height: Double
    let selected: Bool
    let coordinateSpaceName: String
    let select: (Bool) -> Void
    let onBegin: () -> Void
    let onChange: (ZoomKeyframe) -> Void
    let onChangeMany: ([ZoomKeyframe]) -> Void
    let onEnd: () -> Void
    @State private var dragKind: DragKind?
    @State private var origin: ZoomKeyframe?
    @State private var groupOrigins: [ZoomKeyframe] = []
    @State private var dragStartX: Double = 0
    @State private var draft: ZoomKeyframe?

    enum DragKind { case body, leftEdge, rightEdge, zoomInEnd, zoomOutStart }

    var body: some View {
        let visibleStart = max(timeline.sourceStart, zoom.start)
        let visibleEnd = min(timeline.sourceEnd, zoom.start + zoom.duration)
        let visibleSpan = max(0.001, visibleEnd - visibleStart)
        let range = timeline.xRange(sourceStart: zoom.start, sourceEnd: zoom.start + zoom.duration, minimumWidth: 56)
        let x = range.x
        let w = range.width
        let blockHeight = height - 4
        let corner: CGFloat = 5
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(selected ? 0.42 : 0.24),
                            Color.accentColor.opacity(selected ? 0.24 : 0.1)
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
                    let sourceTime = visibleStart + visibleSpan * p
                    let zoomProgress = (sourceTime - zoom.start) / max(0.001, zoom.duration)
                    let env = zoomEnvelope(progress: zoomProgress, zoom: zoom)
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

            Text("\(zoom.scale, specifier: "%.1f")×")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                .opacity(w < 52 ? 0 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if selected {
                let timings = zoomAnimationTimings(for: zoom)
                let zoomInEndTime = zoom.start + timings.zoomIn
                let zoomOutStartTime = zoom.start + zoom.duration - timings.zoomOut
                let zoomInVisible = zoomInEndTime >= visibleStart && zoomInEndTime <= visibleEnd
                let zoomOutVisible = zoomOutStartTime >= visibleStart && zoomOutStartTime <= visibleEnd
                let zoomInX = localX(for: zoomInEndTime, visibleStart: visibleStart, visibleSpan: visibleSpan, width: w)
                let zoomOutX = localX(for: zoomOutStartTime, visibleStart: visibleStart, visibleSpan: visibleSpan, width: w)
                let plateauStart = localX(for: max(visibleStart, zoomInEndTime), visibleStart: visibleStart, visibleSpan: visibleSpan, width: w)
                let plateauEnd = localX(for: min(visibleEnd, zoomOutStartTime), visibleStart: visibleStart, visibleSpan: visibleSpan, width: w)
                if plateauEnd > plateauStart {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(2, plateauEnd - plateauStart), height: 2)
                        .offset(x: plateauStart, y: (blockHeight - 2) / 2)
                        .allowsHitTesting(false)
                }
                if zoomInVisible {
                    AnimationHandle()
                        .offset(x: zoomInX - 7, y: (blockHeight - 28) / 2)
                        .highPriorityGesture(dragGesture(kind: .zoomInEnd))
                        .help("Drag to set where zoom-in animation ends")
                }
                if zoomOutVisible {
                    AnimationHandle()
                        .offset(x: zoomOutX - 7, y: (blockHeight - 28) / 2)
                        .highPriorityGesture(dragGesture(kind: .zoomOutStart))
                        .help("Drag to set where zoom-out animation starts")
                }
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
                    let kind = explicitKind ?? .body
                    dragKind = kind
                    origin = timelineEditableZoom(for: zoom, kind: kind)
                    groupOrigins = kind == .body ? selectedZooms : []
                    dragStartX = Double(value.startLocation.x)
                    draft = origin
                    if groupOrigins.isEmpty {
                        select(selectionExtendsFromCurrentEvent())
                    }
                    onBegin()
                }
                guard let kind = dragKind, let origin else { return }
                let deltaX: Double
                if kind == .body {
                    // Body drag: the block moves 1:1 with the cursor, so use the gesture's
                    // own translation. `value.location.x` in the named coord space can get
                    // clipped at the timeline edges, preventing it from reaching the visible start.
                    deltaX = Double(value.translation.width)
                } else {
                    deltaX = Double(value.location.x) - dragStartX
                }
                let dt = timeline.deltaXToTime(deltaX)
                var updated = origin
                switch kind {
                case .body:
                    if groupOrigins.count > 1 {
                        let moved = movedGroupZooms(deltaTime: dt)
                        draft = moved.first(where: { $0.id == zoom.id }) ?? origin
                        onChangeMany(moved)
                        return
                    }
                    let maxStart = max(timeline.sourceStart, timeline.sourceEnd - origin.duration)
                    updated.start = min(max(timeline.sourceStart, origin.start + dt), maxStart)
                    updated = snappedBodyZoom(updated)
                case .leftEdge:
                    let minDuration = minimumDuration(for: origin)
                    let newStart = max(timeline.sourceStart, min(origin.start + origin.duration - minDuration, origin.start + dt))
                    let newDuration = origin.duration - (newStart - origin.start)
                    updated.start = newStart
                    updated.duration = max(minDuration, newDuration)
                    updated = snappedLeftEdgeZoom(updated, origin: origin)
                case .rightEdge:
                    let minDuration = minimumDuration(for: origin)
                    let newDuration = max(minDuration, origin.duration + dt)
                    updated.duration = min(max(minDuration, timeline.sourceEnd - origin.start), newDuration)
                    updated = snappedRightEdgeZoom(updated)
                case .zoomInEnd:
                    updated.zoomInDuration = min(
                        max(0.08, origin.zoomInDuration + dt),
                        max(0.08, origin.duration - origin.zoomOutDuration)
                    )
                    updated = snappedZoomInHandle(updated)
                case .zoomOutStart:
                    let proposedStart = origin.duration - origin.zoomOutDuration + dt
                    let minStart = origin.zoomInDuration
                    let maxStart = origin.duration - 0.08
                    let clampedStart = min(max(minStart, proposedStart), maxStart)
                    updated.zoomOutDuration = origin.duration - clampedStart
                    updated = snappedZoomOutHandle(updated)
                }
                draft = updated
                onChange(updated)
            }
            .onEnded { _ in
                if groupOrigins.count <= 1, let draft { onChange(draft) }
                onEnd()
                dragKind = nil
                origin = nil
                groupOrigins = []
                draft = nil
            }
    }

    private func movedGroupZooms(deltaTime: Double) -> [ZoomKeyframe] {
        guard !groupOrigins.isEmpty else { return [] }
        let minStart = groupOrigins.map(\.start).min() ?? timeline.sourceStart
        let maxEnd = groupOrigins.map { $0.start + $0.duration }.max() ?? timeline.sourceEnd
        var delta = min(max(deltaTime, timeline.sourceStart - minStart), timeline.sourceEnd - maxEnd)

        let anchor = groupOrigins.first { $0.id == zoom.id } ?? zoom
        let anchorStart = anchor.start + delta
        let anchorEnd = anchor.start + anchor.duration + delta
        if shouldSnap(anchorStart) {
            delta += snapTime - anchorStart
        } else if shouldSnap(anchorEnd) {
            delta += snapTime - anchorEnd
        }
        delta = min(max(delta, timeline.sourceStart - minStart), timeline.sourceEnd - maxEnd)

        return groupOrigins.map { original in
            var moved = original
            moved.start = original.start + delta
            return moved
        }
    }

    private func selectionExtendsFromCurrentEvent() -> Bool {
        guard let flags = NSApp.currentEvent?.modifierFlags else { return false }
        return flags.contains(.command) || flags.contains(.shift)
    }

    private func localX(for sourceTime: Double, visibleStart: Double, visibleSpan: Double, width: Double) -> Double {
        let fraction = (sourceTime - visibleStart) / max(0.001, visibleSpan)
        return min(max(0, fraction * width), width)
    }

    private var snapTime: Double {
        min(max(timeline.sourceStart, playheadTime), timeline.sourceEnd)
    }

    private var snapTolerance: Double {
        timeline.deltaXToTime(10)
    }

    private func shouldSnap(_ sourceTime: Double) -> Bool {
        snapToPlayhead && abs(sourceTime - snapTime) <= snapTolerance
    }

    private func snappedBodyZoom(_ zoom: ZoomKeyframe) -> ZoomKeyframe {
        var updated = zoom
        let maxStart = max(timeline.sourceStart, timeline.sourceEnd - updated.duration)
        if shouldSnap(updated.start) {
            updated.start = snapTime
        } else if shouldSnap(updated.start + updated.duration) {
            updated.start = snapTime - updated.duration
        }
        updated.start = min(max(timeline.sourceStart, updated.start), maxStart)
        return updated
    }

    private func snappedLeftEdgeZoom(_ zoom: ZoomKeyframe, origin: ZoomKeyframe) -> ZoomKeyframe {
        guard shouldSnap(zoom.start) else { return zoom }
        var updated = zoom
        let minDuration = minimumDuration(for: origin)
        let newStart = min(max(timeline.sourceStart, snapTime), origin.start + origin.duration - minDuration)
        updated.start = newStart
        updated.duration = max(minDuration, origin.start + origin.duration - newStart)
        return updated
    }

    private func snappedRightEdgeZoom(_ zoom: ZoomKeyframe) -> ZoomKeyframe {
        guard shouldSnap(zoom.start + zoom.duration) else { return zoom }
        var updated = zoom
        let minDuration = minimumDuration(for: zoom)
        updated.duration = min(max(minDuration, snapTime - zoom.start), max(minDuration, timeline.sourceEnd - zoom.start))
        return updated
    }

    private func snappedZoomInHandle(_ zoom: ZoomKeyframe) -> ZoomKeyframe {
        let handleTime = zoom.start + zoom.zoomInDuration
        guard shouldSnap(handleTime) else { return zoom }
        var updated = zoom
        updated.zoomInDuration = min(
            max(0.08, snapTime - zoom.start),
            max(0.08, zoom.duration - zoom.zoomOutDuration)
        )
        return updated
    }

    private func snappedZoomOutHandle(_ zoom: ZoomKeyframe) -> ZoomKeyframe {
        let handleTime = zoom.start + zoom.duration - zoom.zoomOutDuration
        guard shouldSnap(handleTime) else { return zoom }
        var updated = zoom
        let handleOffset = min(max(zoom.zoomInDuration, snapTime - zoom.start), zoom.duration - 0.08)
        updated.zoomOutDuration = zoom.duration - handleOffset
        return updated
    }

    private func minimumDuration(for zoom: ZoomKeyframe) -> Double {
        max(0.5, zoom.zoomInDuration + zoom.zoomOutDuration)
    }

    private func timelineEditableZoom(for zoom: ZoomKeyframe, kind: DragKind) -> ZoomKeyframe {
        switch kind {
        case .body, .leftEdge, .rightEdge:
            let visibleStart = max(timeline.sourceStart, zoom.start)
            let visibleEnd = min(timeline.sourceEnd, zoom.start + zoom.duration)
            guard visibleEnd > visibleStart else { return zoom }
            var editable = zoom
            editable.start = visibleStart
            editable.duration = visibleEnd - visibleStart
            editable.zoomInDuration = min(editable.zoomInDuration, editable.duration)
            editable.zoomOutDuration = min(editable.zoomOutDuration, editable.duration)
            if editable.zoomInDuration + editable.zoomOutDuration > editable.duration {
                let factor = editable.duration / max(0.001, editable.zoomInDuration + editable.zoomOutDuration)
                editable.zoomInDuration *= factor
                editable.zoomOutDuration *= factor
            }
            return editable
        case .zoomInEnd, .zoomOutStart:
            return zoom
        }
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
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 18)
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
                        VStack(spacing: 0) {
                            HStack(spacing: 5) {
                                Image(systemName: tabValue.icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(tab == tabValue ? Color.frAccent : Color.frSecondaryText)
                                Text(tabValue.title)
                                    .font(.system(size: 12, weight: tab == tabValue ? .semibold : .regular))
                                    .foregroundStyle(tab == tabValue ? Color.frAccent : Color.frSecondaryText)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                            Rectangle()
                                .fill(tab == tabValue ? Color.frAccent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.frPanel)
            Rectangle()
                .fill(Color.frBorder)
                .frame(height: 1)
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
        .background(Color.frPanel)
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
                Text("Zooms")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.frPrimaryText)
                Spacer()
                Button {
                    model.addZoomAtPlayhead()
                } label: {
                    Label("Add Zoom", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.frAccent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.frAccent.opacity(0.75), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if session.zooms.isEmpty {
                ContentUnavailableView(
                    "No zooms yet",
                    systemImage: "plus.magnifyingglass",
                    description: Text("Press Z or use the timeline action row to add a zoom.")
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
                        timelineStart: session.timelineContentStart,
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
    let timelineStart: Double
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
            HStack(spacing: 8) {
                Circle()
                    .fill(selected ? Color.frAccent : Color.frBorder)
                    .frame(width: 10, height: 10)
                Text("Zoom @ \(max(0, zoom.start - timelineStart), specifier: "%.2f")s")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.frPrimaryText)
                Spacer()
                Text(timecode(max(0, zoom.start - timelineStart)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.frSecondaryText)
                Button(role: .destructive) {
                    onDelete(zoom)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.frSecondaryText)
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }

            SliderRow(label: "Scale", value: zoom.scale, range: 1...3, suffix: "x", defaultValue: RecordingSettings().automaticZoomScale) {
                var u = zoom; u.scale = $0; onChange(u)
            } onCommit: {
                var u = zoom; u.scale = $0; onCommit(u)
            } onBegin: { onBegin() } onReset: {
                var u = zoom; u.scale = $0; onCommit(u)
            }

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

                SliderRow(label: "Smoothness", value: zoom.followCursorSmoothing, range: 0...2, suffix: "", defaultValue: ZoomKeyframe.defaultFollowCursorSmoothing) {
                    var u = zoom
                    u.followCursorSmoothing = $0
                    onChange(u)
                } onCommit: {
                    var u = zoom
                    u.followCursorSmoothing = $0
                    onCommit(u)
                } onBegin: { onBegin() } onReset: {
                    var u = zoom
                    u.followCursorSmoothing = $0
                    onCommit(u)
                }
                SliderRow(label: "Cursor delay", value: zoom.followCursorDelay, range: 0...0.8, suffix: "s", defaultValue: ZoomKeyframe.defaultFollowCursorDelay) {
                    var u = zoom
                    u.followCursorDelay = $0
                    onChange(u)
                } onCommit: {
                    var u = zoom
                    u.followCursorDelay = $0
                    onCommit(u)
                } onBegin: { onBegin() } onReset: {
                    var u = zoom
                    u.followCursorDelay = $0
                    onCommit(u)
                }

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
                    .font(.system(size: 12))
                    .foregroundStyle(Color.frSecondaryText)
                    .frame(width: 56, alignment: .leading)
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
                    SliderRow(label: "Ramp", value: zoom.rampFraction, range: 0.04...0.48, suffix: "", defaultValue: ZoomEasing.smooth.rampFraction) {
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
                    } onBegin: { onBegin() } onReset: {
                        var u = zoom
                        u.easing = .smooth
                        u.rampFraction = $0
                        u.zoomInDuration = max(0.08, u.duration * $0)
                        u.zoomOutDuration = max(0.08, u.duration * $0)
                        u.bezier = ZoomEasing.smooth.curve
                        onCommit(u)
                    }

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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.frAccent.opacity(0.08) : Color.frBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.frAccent : Color.frBorder, lineWidth: selected ? 1.5 : 1)
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

            SliderRow(label: "Scale", value: averageScale, range: 1...3, suffix: "x", defaultValue: RecordingSettings().automaticZoomScale) { value in
                onChange { $0.scale = value }
            } onCommit: { value in
                onCommit { $0.scale = value }
            } onBegin: { onBegin() } onReset: { value in
                onCommit { $0.scale = value }
            }

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

                SliderRow(label: "Smoothness", value: averageFollowSmoothing, range: 0...2, suffix: "", defaultValue: ZoomKeyframe.defaultFollowCursorSmoothing) { value in
                    onChange { $0.followCursorSmoothing = value }
                } onCommit: { value in
                    onCommit { $0.followCursorSmoothing = value }
                } onBegin: { onBegin() } onReset: { value in
                    onCommit { $0.followCursorSmoothing = value }
                }

                SliderRow(label: "Cursor delay", value: averageFollowDelay, range: 0...0.8, suffix: "s", defaultValue: ZoomKeyframe.defaultFollowCursorDelay) { value in
                    onChange { $0.followCursorDelay = value }
                } onCommit: { value in
                    onCommit { $0.followCursorDelay = value }
                } onBegin: { onBegin() } onReset: { value in
                    onCommit { $0.followCursorDelay = value }
                }
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.frBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.frBorder, lineWidth: 1)
        )
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
                    .font(.system(size: 12))
                    .foregroundStyle(Color.frSecondaryText)
                Spacer()
                Button {
                    onCenterOnCursor()
                } label: {
                    Label("Center on Cursor", systemImage: "scope")
                        .font(.system(size: 11, weight: .medium))
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .tint(Color.frSecondaryText)
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
                    resetDeadZone()
                }
            }
            .aspectRatio(max(1, width) / max(1, height), contentMode: .fit)
            .frame(maxHeight: 120)
            HStack {
                Text("Drag the handle to resize.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    resetDeadZone()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
            }
        }
    }

    private func resetDeadZone() {
        var updated = zoom
        updated.followCursorDeadZoneWidth = 0.35
        updated.followCursorDeadZoneHeight = 0.30
        onBegin()
        onCommit(updated)
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
                    .fill(Color.frBackground)
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
        case .image: return .image
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
            case (.image, .image): return true
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
            case .solid, .gradient, .image:
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
                SliderRow(label: "Padding", value: edit.padding, range: 0...0.18, suffix: "", defaultValue: EditSettings().padding) {
                    var e = edit; e.padding = $0; model.updateEditSettings(e)
                } onCommit: {
                    var e = edit; e.padding = $0; model.updateEditSettings(e); model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() } onReset: {
                    var e = edit; e.padding = $0; model.updateEditSettings(e); model.endUndoTransaction()
                }
                SliderRow(label: "Corners", value: edit.cornerRadius, range: 0...0.08, suffix: "", defaultValue: EditSettings().cornerRadius) {
                    var e = edit; e.cornerRadius = $0; model.updateEditSettings(e)
                } onCommit: {
                    var e = edit; e.cornerRadius = $0; model.updateEditSettings(e); model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() } onReset: {
                    var e = edit; e.cornerRadius = $0; model.updateEditSettings(e); model.endUndoTransaction()
                }
                SliderRow(label: "Shadow", value: edit.shadow, range: 0...1, suffix: "", defaultValue: EditSettings().shadow) {
                    var e = edit; e.shadow = $0; model.updateEditSettings(e)
                } onCommit: {
                    var e = edit; e.shadow = $0; model.updateEditSettings(e); model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() } onReset: {
                    var e = edit; e.shadow = $0; model.updateEditSettings(e); model.endUndoTransaction()
                }
            }

            Divider()

            Text("Motion").font(.headline)
            SliderRow(label: "Blur", value: edit.motionBlur, range: 0...2, suffix: "", defaultValue: EditSettings().motionBlur) {
                var e = edit; e.motionBlur = $0; model.updateEditSettings(e)
            } onCommit: {
                var e = edit; e.motionBlur = $0; model.updateEditSettings(e); model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var e = edit; e.motionBlur = $0; model.updateEditSettings(e); model.endUndoTransaction()
            }
            Text("The editor uses a lightweight approximation; final export renders smoother, higher-quality motion blur.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                case .image: return .image
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
                case .image:
                    if case .image = e.background {} else {
                        e.background = .image(path: "")
                    }
                }
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
        case .image(let path):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        chooseBackgroundImage()
                    } label: {
                        Label(path.isEmpty ? "Choose Image" : "Change Image", systemImage: "photo")
                    }
                    .controlSize(.small)

                    if !path.isEmpty {
                        Button {
                            var e = edit
                            e.background = .image(path: "")
                            model.updateEditSettings(e, recordUndo: true)
                        } label: {
                            Label("Remove", systemImage: "xmark")
                        }
                        .controlSize(.small)
                    }
                }
                if path.isEmpty {
                    Text("Choose a local image to use as an aspect-filled canvas background.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    imagePositioningControls(path: path)
                }
            }
        }
    }

    @ViewBuilder
    private func imagePositioningControls(path: String) -> some View {
        let image = EditorBackgroundImageCache.shared.image(for: path)
        let valid = image != nil

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fit").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { edit.imageFit },
                    set: { newValue in
                        var e = edit
                        e.imageFit = newValue
                        model.updateEditSettings(e, recordUndo: true)
                    }
                )) {
                    ForEach(BackgroundImageFit.allCases) { fit in
                        Text(fit.title).tag(fit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }

            if edit.imageFit == .fill, valid, let img = image {
                HStack(alignment: .top, spacing: 12) {
                    ImageFocusPicker(
                        image: img,
                        focusX: edit.imageFocusX,
                        focusY: edit.imageFocusY,
                        onChange: { fx, fy in
                            var e = edit
                            e.imageFocusX = fx
                            e.imageFocusY = fy
                            model.updateEditSettings(e)
                        },
                        onCommit: {
                            model.endUndoTransaction()
                        },
                        onBegin: {
                            model.beginUndoTransaction()
                        }
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Position").font(.subheadline).foregroundStyle(.secondary)
                        FocusPresetGrid(
                            focusX: edit.imageFocusX,
                            focusY: edit.imageFocusY,
                            onPick: { fx, fy in
                                var e = edit
                                e.imageFocusX = fx
                                e.imageFocusY = fy
                                model.updateEditSettings(e, recordUndo: true)
                            }
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Background Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var e = edit
        e.background = .image(path: url.path)
        model.updateEditSettings(e, recordUndo: true)
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
        case none, solid, gradient, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Original"
            case .solid: return "Solid"
            case .gradient: return "Gradient"
            case .image: return "Image"
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
                    case .image(let path):
                        if let image = EditorBackgroundImageCache.shared.image(for: path) {
                            BackgroundImageView(
                                image: image,
                                fit: .fill,
                                focusX: 0.5,
                                focusY: 0.5,
                                fallbackColor: .black
                            )
                        } else {
                            Color.black
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.8))
                        }
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

/// Visual draggable focal-point picker over a thumbnail of the chosen background image.
private struct ImageFocusPicker: View {
    let image: EditorBackgroundImage
    let focusX: Double
    let focusY: Double
    let onChange: (Double, Double) -> Void
    let onCommit: () -> Void
    let onBegin: () -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                BackgroundImageView(
                    image: image,
                    fit: .fill,
                    focusX: 0.5,
                    focusY: 0.5,
                    fallbackColor: .black
                )
                .overlay(Color.black.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Crosshair guides
                Path { p in
                    let cx = focusX * size.width
                    let cy = focusY * size.height
                    p.move(to: CGPoint(x: cx, y: 0))
                    p.addLine(to: CGPoint(x: cx, y: size.height))
                    p.move(to: CGPoint(x: 0, y: cy))
                    p.addLine(to: CGPoint(x: size.width, y: cy))
                }
                .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false)

                // The handle
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().fill(Color.accentColor).padding(3))
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .position(
                        x: focusX * size.width,
                        y: focusY * size.height
                    )
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onBegin()
                        }
                        let fx = min(max(value.location.x / size.width, 0), 1)
                        let fy = min(max(value.location.y / size.height, 0), 1)
                        onChange(fx, fy)
                    }
                    .onEnded { _ in
                        dragging = false
                        onCommit()
                    }
            )
        }
        .frame(width: 130, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

/// 3×3 grid of preset focal-point positions (top-left, top-center, … bottom-right).
private struct FocusPresetGrid: View {
    let focusX: Double
    let focusY: Double
    let onPick: (Double, Double) -> Void

    private let positions: [(Double, Double)] = [
        (0.0, 0.0), (0.5, 0.0), (1.0, 0.0),
        (0.0, 0.5), (0.5, 0.5), (1.0, 0.5),
        (0.0, 1.0), (0.5, 1.0), (1.0, 1.0)
    ]

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(0..<3) { col in
                        let idx = row * 3 + col
                        let (fx, fy) = positions[idx]
                        let isSelected =
                            abs(focusX - fx) < 0.05 && abs(focusY - fy) < 0.05
                        Button {
                            onPick(fx, fy)
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.12))
                                .frame(width: 18, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.white.opacity(isSelected ? 0.0 : 0.05), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Anchor to \(positionName(fx, fy))")
                    }
                }
            }
        }
    }

    private func positionName(_ fx: Double, _ fy: Double) -> String {
        let v = fy < 0.34 ? "top" : (fy > 0.66 ? "bottom" : "middle")
        let h = fx < 0.34 ? "left" : (fx > 0.66 ? "right" : "center")
        return "\(v) \(h)"
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

            SliderRow(label: "Size", value: session.settings.cursorScale, range: 0.5...5.0, suffix: "x", defaultValue: RecordingSettings().cursorScale) {
                var settings = session.settings
                settings.cursorScale = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorScale = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var settings = session.settings
                settings.cursorScale = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            }

            SliderRow(label: "Opacity", value: session.settings.cursorOpacity, range: 0.2...1.0, suffix: "", defaultValue: RecordingSettings().cursorOpacity) {
                var settings = session.settings
                settings.cursorOpacity = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorOpacity = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var settings = session.settings
                settings.cursorOpacity = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            }

            Divider()

            Text("Motion").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            SliderRow(label: "Smoothing", value: session.settings.cursorSmoothing, range: 0...2.0, suffix: "", defaultValue: RecordingSettings().cursorSmoothing) {
                var settings = session.settings
                settings.cursorSmoothing = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorSmoothing = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var settings = session.settings
                settings.cursorSmoothing = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            }

            SliderRow(label: "Window", value: session.settings.cursorSmoothingWindow, range: 0.05...0.9, suffix: "s", defaultValue: RecordingSettings().cursorSmoothingWindow) {
                var settings = session.settings
                settings.cursorSmoothingWindow = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorSmoothingWindow = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var settings = session.settings
                settings.cursorSmoothingWindow = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            }

            SliderRow(label: "Spring", value: session.settings.cursorSpring, range: 0...2.0, suffix: "", defaultValue: RecordingSettings().cursorSpring) {
                var settings = session.settings
                settings.cursorSpring = $0
                model.updateSessionSettings(settings)
            } onCommit: {
                var settings = session.settings
                settings.cursorSpring = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var settings = session.settings
                settings.cursorSpring = $0
                model.updateSessionSettings(settings)
                model.endUndoTransaction()
            }

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
                SliderRow(label: "Pulse", value: session.settings.cursorClickPulseStrength, range: 0...1.0, suffix: "", defaultValue: RecordingSettings().cursorClickPulseStrength) {
                    var settings = session.settings
                    settings.cursorClickPulseStrength = $0
                    model.updateSessionSettings(settings)
                } onCommit: {
                    var settings = session.settings
                    settings.cursorClickPulseStrength = $0
                    model.updateSessionSettings(settings)
                    model.endUndoTransaction()
                } onBegin: { model.beginUndoTransaction() } onReset: {
                    var settings = session.settings
                    settings.cursorClickPulseStrength = $0
                    model.updateSessionSettings(settings)
                    model.endUndoTransaction()
                }
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
                Button {
                    var s = session.settings
                    s.customCursorHotspotX = RecordingSettings().customCursorHotspotX
                    model.updateSessionSettings(s, recordUndo: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(abs(session.settings.customCursorHotspotX - RecordingSettings().customCursorHotspotX) < 0.000_1)
                .help("Reset hotspot X")
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
                Button {
                    var s = session.settings
                    s.customCursorHotspotY = RecordingSettings().customCursorHotspotY
                    model.updateSessionSettings(s, recordUndo: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(abs(session.settings.customCursorHotspotY - RecordingSettings().customCursorHotspotY) < 0.000_1)
                .help("Reset hotspot Y")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.frBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.frBorder, lineWidth: 1)
        )
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

            SliderRow(label: "Bitrate", value: session.settings.bitrateMbps, range: 4...80, suffix: " Mbps", defaultValue: RecordingSettings().bitrateMbps) {
                var s = session.settings
                s.bitrateMbps = $0
                model.updateSessionSettings(s)
            } onCommit: {
                var s = session.settings
                s.bitrateMbps = $0
                model.updateSessionSettings(s)
                model.endUndoTransaction()
            } onBegin: { model.beginUndoTransaction() } onReset: {
                var s = session.settings
                s.bitrateMbps = $0
                model.updateSessionSettings(s)
                model.endUndoTransaction()
            }

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
                .tint(Color.frAccent)
                .controlSize(.large)
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(renderer.isRendering)
            }

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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.frBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.frBorder, lineWidth: 1)
        )
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
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.frBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.frBorder, lineWidth: 1)
        )
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
    var defaultValue: Double? = nil
    var onReset: ((Double) -> Void)? = nil
    @State private var draftValue: Double?

    init(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        suffix: String,
        defaultValue: Double? = nil,
        onChange: @escaping (Double) -> Void,
        onCommit: ((Double) -> Void)? = nil,
        onBegin: (() -> Void)? = nil,
        onReset: ((Double) -> Void)? = nil
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.suffix = suffix
        self.defaultValue = defaultValue
        self.onChange = onChange
        self.onCommit = onCommit
        self.onBegin = onBegin
        self.onReset = onReset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(Color.frSecondaryText)
                Spacer()
                Text("\(draftValue ?? value, specifier: range.upperBound > 10 ? "%.0f" : "%.2f")\(suffix)")
                    .monospacedDigit()
                if let defaultValue, let onReset {
                    Button {
                        draftValue = nil
                        onBegin?()
                        onReset(defaultValue)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(abs(value - defaultValue) < 0.000_1)
                    .help("Reset \(label)")
                    .accessibilityLabel("Reset \(label)")
                }
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
        case space, leftArrow, rightArrow, shiftLeft, shiftRight, home, end, f, z, s, c, duplicateZoom, selectAllZooms, delete, undo, redo, escape
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
            case 53: if handler(.escape) { return nil }
            default:
                let dup = PreferencesStore.shared.preferences.duplicateZoomEditorHotkey
                if dup.matchesKeyDown(event), handler(.duplicateZoom) { return nil }
                let selectAll = PreferencesStore.shared.preferences.selectAllZoomsEditorHotkey
                if selectAll.matchesKeyDown(event), handler(.selectAllZooms) { return nil }
                if (cmd || control), chars.lowercased() == "z" {
                    if handler(shift ? .redo : .undo) { return nil }
                }
                if cmd { break }
                if chars.lowercased() == "f" { if handler(.f) { return nil } }
                if chars.lowercased() == "z" { if handler(.z) { return nil } }
                if chars.lowercased() == "s" { if handler(.s) { return nil } }
                if chars.lowercased() == "c" { if handler(.c) { return nil } }
            }
            return event
        }
    }
}
