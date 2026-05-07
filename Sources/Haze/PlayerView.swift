import AVFoundation
import AppKit
import SwiftUI

/// AVPlayerLayer-backed NSView. Bypasses the SwiftUI VideoPlayer crash on macOS 26.5.
final class PlayerHostNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}

struct PlayerHostView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostNSView {
        let view = PlayerHostNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostNSView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Convenience controller that wraps AVPlayer with periodic time observation.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = false
    /// When set, playback seeks and periodic updates are clamped to this half-open range in asset seconds.
    var playableTimeRange: ClosedRange<Double>?

    let player: AVPlayer
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        attachObservers()
        Task { await loadDuration(item: item) }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        statusObserver?.invalidate()
        rateObserver?.invalidate()
    }

    func replace(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        Task { await loadDuration(item: item) }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            let end = playableTimeRange?.upperBound ?? duration
            let start = playableTimeRange?.lowerBound ?? 0
            if currentTime >= end - 0.05 {
                seek(to: start)
            }
            player.play()
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double, precise: Bool = true) {
        let target = max(0, min(seconds, duration))
        let cm = CMTime(seconds: target, preferredTimescale: 600)
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = target
    }

    func step(by frames: Int) {
        guard let item = player.currentItem else { return }
        item.step(byCount: frames)
        if let pts = player.currentItem?.currentTime() {
            currentTime = max(0, min(CMTimeGetSeconds(pts), duration))
        }
    }

    private func attachObservers() {
        // Keep the SwiftUI overlay clock close to the display refresh rate. The video itself is
        // drawn by AVPlayerLayer; this observer only drives cursor/zoom overlay transforms.
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = max(0, CMTimeGetSeconds(time))
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying, let r = self.playableTimeRange, seconds > r.upperBound + 0.02 {
                    self.player.pause()
                    let end = r.upperBound
                    self.player.seek(to: CMTime(seconds: end, preferredTimescale: 600))
                    self.currentTime = end
                    return
                }
                self.currentTime = seconds
            }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
    }

    private func loadDuration(item: AVPlayerItem) async {
        do {
            let dur = try await item.asset.load(.duration)
            await MainActor.run {
                self.duration = max(0, CMTimeGetSeconds(dur))
            }
        } catch {
            // ignore
        }
    }
}
