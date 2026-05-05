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
    @Published private(set) var finalPreviewPolicy: FinalPreviewPolicy = .pausedOnly
    @Published private(set) var previewMotionBlurEnabled = true
    @Published private(set) var isScrubbing = false
    @Published private(set) var finalPreviewVisible = false

    private(set) var frameState: PreviewFrameState?
    private var pendingRender: Task<Void, Never>?

    deinit {
        pendingRender?.cancel()
    }

    func sync(from session: RecordingSession) {
        finalPreviewPolicy = session.edit.finalPreviewPolicy
        previewMotionBlurEnabled = session.edit.previewMotionBlurEnabled
    }

    func setMode(_ newMode: PreviewRenderMode, cache: PreviewCacheStore) {
        mode = newMode
        pendingRender?.cancel()
        finalPreviewVisible = false
        cache.clearCurrentFrame()
    }

    func update(state: PreviewFrameState) {
        frameState = state
    }

    func resetToApproximate(cache: PreviewCacheStore) {
        mode = .approximate
        isScrubbing = false
        pendingRender?.cancel()
        finalPreviewVisible = false
        cache.clearCurrentFrame()
    }

    func setScrubbing(
        _ scrubbing: Bool,
        session: RecordingSession,
        time: Double,
        isPlaying: Bool,
        cache: PreviewCacheStore,
        renderer: ExportRenderer
    ) {
        isScrubbing = scrubbing
        if scrubbing {
            pendingRender?.cancel()
            finalPreviewVisible = false
            cache.clearCurrentFrame()
            return
        }
        requestFrameIfAllowed(
            session: session,
            time: time,
            isPlaying: isPlaying,
            cache: cache,
            renderer: renderer,
            debounce: true
        )
    }

    func requestFrameIfAllowed(
        session: RecordingSession,
        time: Double,
        isPlaying: Bool,
        cache: PreviewCacheStore,
        renderer: ExportRenderer,
        debounce: Bool = true
    ) {
        sync(from: session)
        guard mode != .highFidelity else {
            pendingRender?.cancel()
            finalPreviewVisible = false
            cache.clearCurrentFrame()
            return
        }
        guard let decision = renderDecision(isPlaying: isPlaying) else {
            pendingRender?.cancel()
            finalPreviewVisible = false
            cache.clearCurrentFrame()
            return
        }

        finalPreviewVisible = true
        pendingRender?.cancel()
        let delay = debounce ? decision.debounceNanoseconds : 0
        pendingRender = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await cache.displaySingleFrame(
                session: session,
                time: time,
                renderer: renderer,
                quality: decision.quality,
                previewMotionBlurEnabled: self?.previewMotionBlurEnabled ?? true
            )
        }
    }

    private func renderDecision(isPlaying: Bool) -> RenderDecision? {
        if isScrubbing {
            return nil
        }

        if isPlaying {
            return nil
        }

        switch finalPreviewPolicy {
        case .pausedOnly:
            return RenderDecision(
                quality: .previewHighFidelity,
                debounceNanoseconds: 160_000_000
            )
        case .reducedQualityPlayback:
            return RenderDecision(
                quality: .previewHighFidelity,
                debounceNanoseconds: 160_000_000
            )
        case .alwaysHighQuality:
            return RenderDecision(
                quality: .previewHighFidelity,
                debounceNanoseconds: 160_000_000
            )
        }
    }

    private struct RenderDecision {
        var quality: RenderQuality
        var debounceNanoseconds: UInt64
    }
}
