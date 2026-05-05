import AppKit
import Foundation

@MainActor
final class PreviewCacheStore: ObservableObject {
    @Published private(set) var cachedBuckets: Set<Int> = []
    @Published private(set) var renderingBuckets: Set<Int> = []
    @Published var currentImage: NSImage?
    @Published var status: String?

    let bucketDuration: Double = 1.0 / 60.0
    private var cacheKey: UUID?
    private var warmTask: Task<Void, Never>?
    private var memory: [Int: NSImage] = [:]
    private var memoryOrder: [Int] = []
    private let maxMemoryFrames = 180

    func bucket(for time: Double) -> Int {
        max(0, Int((time / bucketDuration).rounded(.down)))
    }

    func time(for bucket: Int) -> Double {
        Double(bucket) * bucketDuration
    }

    func resetIfNeeded(for session: RecordingSession) {
        guard cacheKey != session.id else { return }
        warmTask?.cancel()
        cacheKey = session.id
        memory = [:]
        memoryOrder = []
        renderingBuckets = []
        cachedBuckets = loadExistingBuckets(for: session)
        currentImage = nil
        status = nil
    }

    func invalidate(for session: RecordingSession) {
        warmTask?.cancel()
        memory = [:]
        memoryOrder = []
        renderingBuckets = []
        cachedBuckets = []
        currentImage = nil
        status = nil
        try? FileManager.default.removeItem(at: directory(for: session))
    }

    func displayFrame(session: RecordingSession, time: Double, renderer: ExportRenderer) {
        resetIfNeeded(for: session)
        let center = bucket(for: time)
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            guard let self else { return }
            await self.renderWindow(session: session, centerBucket: center, renderer: renderer)
        }
    }

    func displaySingleFrame(
        session: RecordingSession,
        time: Double,
        renderer: ExportRenderer,
        quality: RenderQuality
    ) async {
        resetIfNeeded(for: session)
        let requestedTime = min(max(0, time), session.approximateDuration)
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            self.status = statusText(for: quality)
            do {
                var previewSession = session
                if quality == .previewApproximate {
                    previewSession.edit.motionBlur = 0
                }
                let image = try await renderer.previewImage(session: previewSession, time: requestedTime)
                guard !Task.isCancelled else { return }
                self.currentImage = image
                self.status = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.status = "Preview frame failed"
            }
        }
    }

    func renderAll(session: RecordingSession, renderer: ExportRenderer) {
        resetIfNeeded(for: session)
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            guard let self else { return }
            let count = max(1, Int(ceil(session.approximateDuration / self.bucketDuration)))
            for bucket in 0..<count {
                if Task.isCancelled { return }
                _ = await self.image(session: session, bucket: bucket, renderer: renderer)
            }
            self.status = nil
        }
    }

    func clearCurrentFrame() {
        warmTask?.cancel()
        currentImage = nil
        status = nil
    }

    private func renderWindow(session: RecordingSession, centerBucket: Int, renderer: ExportRenderer) async {
        let order = previewOrder(center: centerBucket, duration: session.approximateDuration)
        for bucket in order {
            if Task.isCancelled { return }
            if let image = await image(session: session, bucket: bucket, renderer: renderer),
               bucket == centerBucket {
                currentImage = image
            }
        }
        status = nil
    }

    private func previewOrder(center: Int, duration: Double) -> [Int] {
        let maxBucket = max(0, Int(ceil(duration / bucketDuration)))
        var out: [Int] = []
        for offset in 0...24 {
            let right = center + offset
            if right <= maxBucket { out.append(right) }
            if offset > 0 {
                let left = center - offset
                if left >= 0 { out.append(left) }
            }
        }
        return out
    }

    private func image(session: RecordingSession, bucket: Int, renderer: ExportRenderer) async -> NSImage? {
        if let image = memory[bucket] {
            touch(bucket)
            return image
        }
        if let image = NSImage(contentsOf: fileURL(session: session, bucket: bucket)) {
            store(image, for: bucket)
            cachedBuckets.insert(bucket)
            return image
        }
        guard !renderingBuckets.contains(bucket) else { return nil }
        renderingBuckets.insert(bucket)
        status = "Rendering preview cache"
        defer { renderingBuckets.remove(bucket) }
        do {
            let time = min(session.approximateDuration, self.time(for: bucket))
            let image = try await renderer.previewImage(session: session, time: time)
            store(image, for: bucket)
            try save(image: image, to: fileURL(session: session, bucket: bucket))
            cachedBuckets.insert(bucket)
            return image
        } catch {
            status = "Preview cache failed"
            return nil
        }
    }

    private func loadExistingBuckets(for session: RecordingSession) -> Set<Int> {
        let dir = directory(for: session)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return Set(urls.compactMap { url in
            guard url.pathExtension == "png" else { return nil }
            return Int(url.deletingPathExtension().lastPathComponent)
        })
    }

    private func directory(for session: RecordingSession) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusRecorderPreviewCache60fps", isDirectory: true)
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
    }

    private func store(_ image: NSImage, for bucket: Int) {
        memory[bucket] = image
        touch(bucket)
        while memoryOrder.count > maxMemoryFrames, let evicted = memoryOrder.first {
            memoryOrder.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func touch(_ bucket: Int) {
        memoryOrder.removeAll { $0 == bucket }
        memoryOrder.append(bucket)
    }

    private func fileURL(session: RecordingSession, bucket: Int) -> URL {
        directory(for: session).appendingPathComponent(String(format: "%06d.png", bucket))
    }

    private func statusText(for quality: RenderQuality) -> String {
        switch quality {
        case .previewApproximate:
            return "Rendering reduced preview"
        case .previewHighFidelity:
            return "Rendering final preview"
        case .export:
            return "Rendering export frame"
        }
    }

    private func save(image: NSImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: url, options: .atomic)
    }
}
