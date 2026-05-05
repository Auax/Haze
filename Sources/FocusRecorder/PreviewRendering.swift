import AppKit
import AVFoundation
import CoreGraphics
import Foundation

protocol LivePreviewRendering {
    func attach(to view: NSView)
    func detach()
    func update(state: PreviewFrameState)
    func setPlayer(_ player: AVPlayer?)
}

protocol FinalFrameRendering {
    func renderFrame(at time: TimeInterval, quality: RenderQuality) async throws -> CGImage
}

struct PreviewFrameState {
    let time: TimeInterval
    let isPlaying: Bool
    let isScrubbing: Bool
    let zoom: Double
    let cameraCenter: CGPoint
    let cursorPosition: CGPoint?
    let activeClicks: [ClickEffectState]
    let motionBlurAmount: Double
    let previewMotionBlurEnabled: Bool
}

struct ClickEffectState {
    let position: CGPoint
    let age: TimeInterval
    let duration: TimeInterval
}

enum RenderQuality: Equatable {
    case previewApproximate
    case previewHighFidelity
    case export
}

final class SessionFinalFrameRenderer: FinalFrameRendering {
    private let session: RecordingSession
    private let renderer: ExportRenderer

    init(session: RecordingSession, renderer: ExportRenderer) {
        self.session = session
        self.renderer = renderer
    }

    func renderFrame(at time: TimeInterval, quality: RenderQuality) async throws -> CGImage {
        try await renderer.previewCGImage(session: session, time: time, quality: quality)
    }
}

@MainActor
final class PreviewRenderController: ObservableObject {
    @Published private(set) var mode: PreviewRenderMode = .approximate
    @Published private(set) var previewMotionBlurEnabled = true
    @Published private(set) var isScrubbing = false
    @Published private(set) var finalPreviewVisible = false

    private(set) var frameState: PreviewFrameState?
    private var pendingRender: Task<Void, Never>?

    deinit {
        pendingRender?.cancel()
    }

    func sync(from session: RecordingSession) {
        previewMotionBlurEnabled = session.edit.previewMotionBlurEnabled
    }

    /// Switch between approximate (SwiftUI overlay) and highFidelity (Metal) live preview.
    func setMode(_ newMode: PreviewRenderMode, cache: PreviewCacheStore) {
        mode = newMode
        pendingRender?.cancel()
        finalPreviewVisible = false
        cache.clearCurrentFrame()
    }

    func update(state: PreviewFrameState) {
        frameState = state
    }

    /// Resets to approximate mode; called when a new session is loaded.
    func resetToApproximate(cache: PreviewCacheStore) {
        mode = .approximate
        isScrubbing = false
        pendingRender?.cancel()
        finalPreviewVisible = false
        cache.clearCurrentFrame()
    }

    /// Hide the on-demand final preview overlay and clear any rendered frame.
    func dismissFinalPreview(cache: PreviewCacheStore) {
        pendingRender?.cancel()
        finalPreviewVisible = false
        cache.clearCurrentFrame()
    }

    func setScrubbing(_ scrubbing: Bool, cache: PreviewCacheStore) {
        isScrubbing = scrubbing
        if scrubbing {
            dismissFinalPreview(cache: cache)
        }
    }

    /// Renders one final-quality preview frame on demand. Triggered by the editor's
    /// "Preview Frame" button — the final preview is never shown automatically.
    func requestSingleFrame(
        session: RecordingSession,
        time: Double,
        cache: PreviewCacheStore,
        renderer: ExportRenderer
    ) {
        sync(from: session)
        pendingRender?.cancel()
        finalPreviewVisible = true
        pendingRender = Task { [weak self] in
            await cache.displaySingleFrame(
                session: session,
                time: time,
                renderer: renderer,
                quality: .previewHighFidelity,
                previewMotionBlurEnabled: self?.previewMotionBlurEnabled ?? true
            )
        }
    }
}
