import AppKit
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

final class CaptureEngine: NSObject, ObservableObject {
    @Published var displays: [CaptureSource] = []
    @Published var windows: [CaptureSource] = []
    @Published var microphones: [AudioInputDevice] = []
    @Published var selectedSourceID: String?
    @Published var status: String = "Ready"
    @Published var isRecording = false
    @Published var previewImage: NSImage?
    @Published var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @Published var hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var microphoneLevel: Double = 0
    @Published var elapsedRecordingTime: Double = 0
    @Published var manualZoomCount: Int = 0

    private var shareableContent: SCShareableContent?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstVideoTime: CMTime?
    private var frameCount = 0
    private var stopRequested = false
    private var cursorTimer: Timer?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var cursorSamples: [CursorSample] = []
    private var clickEvents: [MouseClickEvent] = []
    private var keystrokeEvents: [KeystrokeEvent] = []
    private var cursorShapeSamples: [CursorShapeSample] = []
    private var lastCursorShape: CursorShape?
    private var manualZoomTimes: [Double] = []
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var manualZoomGlobalMonitor: Any?
    private var manualZoomLocalMonitor: Any?
    private var microphoneMeterSession: AVCaptureSession?
    private var activeSettings = RecordingSettings()
    private var activeSource: CaptureSource?
    private var activeOutputSize = CGSize(width: 1920, height: 1080)
    private var activeRawURL: URL?
    private let outputQueue = DispatchQueue(label: "FocusRecorder.ScreenOutput")
    private let microphoneMeterQueue = DispatchQueue(label: "FocusRecorder.MicrophoneMeter")
    private let previewContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var lastPreviewTime = Date.distantPast

    var selectedSource: CaptureSource? {
        let all = displays + windows
        return all.first { $0.id == selectedSourceID } ?? displays.first
    }

    func refreshMicrophones() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        DispatchQueue.main.async {
            self.microphones = devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
        }
    }

    func refreshSources() async {
        refreshMicrophones()
        guard updateScreenRecordingPermission() else {
            await MainActor.run {
                self.status = "Screen Recording permission is not granted"
                self.displays = []
                self.windows = []
            }
            return
        }

        do {
            let content = try await SCShareableContent.current
            await MainActor.run {
                self.shareableContent = content
                self.displays = content.displays.map {
                    CaptureSource(
                        id: "display-\($0.displayID)",
                        kind: .display,
                        title: "Display \($0.displayID)",
                        subtitle: "\($0.width)x\($0.height)",
                        width: $0.width,
                        height: $0.height,
                        frame: Self.screenFrame(displayID: $0.displayID, width: $0.width, height: $0.height)
                    )
                }
                self.windows = content.windows
                    .filter { $0.frame.width > 80 && $0.frame.height > 80 }
                    .map { window -> CaptureSource in
                        let appName = window.owningApplication?.applicationName ?? "Unknown app"
                        let rawTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let displayTitle = rawTitle.isEmpty ? appName : rawTitle
                        return CaptureSource(
                            id: "window-\(window.windowID)",
                            kind: .window,
                            title: displayTitle,
                            subtitle: appName,
                            width: Int(window.frame.width),
                            height: Int(window.frame.height),
                            frame: window.frame
                        )
                    }
                if self.selectedSourceID == nil {
                    self.selectedSourceID = self.displays.first?.id
                }
                self.status = "Found \(self.displays.count) display(s), \(self.windows.count) window(s)"
            }
        } catch {
            await MainActor.run {
                self.status = "Screen Recording permission is needed: \(error.localizedDescription)"
            }
        }
    }

    func start(settings: RecordingSettings) async throws {
        guard !isRecording else { return }
        guard await ensureScreenRecordingPermission() else {
            throw RecorderError.message("Screen Recording permission is not granted. Enable Focus Recorder in System Settings, then quit and reopen the app.")
        }
        if settings.recordMicrophone {
            guard await ensureMicrophonePermission() else {
                throw RecorderError.message("Microphone permission is not granted. Enable Focus Recorder in System Settings, then try again.")
            }
            await MainActor.run {
                self.stopMicrophoneMeter()
            }
        }
        if shareableContent == nil {
            await refreshSources()
        }
        guard let content = shareableContent else {
            throw RecorderError.message("No shareable screen content is available.")
        }

        let source = selectedSource
        let filter = try makeFilter(content: content, source: source, settings: settings)
        let outputSize = settings.outputSize(for: source)
        let rawURL = Self.makeOutputURL(suffix: "raw")

        let config = SCStreamConfiguration()
        config.width = Int(outputSize.width)
        config.height = Int(outputSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = settings.recordSystemAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = settings.recordMicrophone
        if let microphoneDeviceID = settings.microphoneDeviceID, !microphoneDeviceID.isEmpty {
            config.microphoneCaptureDeviceID = microphoneDeviceID
        }
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.captureResolution = .best
        if settings.captureKind == .region {
            config.sourceRect = normalizedRegion(settings.region, source: source)
        }

        let writer = try AVAssetWriter(outputURL: rawURL, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(settings.bitrateMbps * 1_000_000),
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.message("The video writer could not accept the selected settings.")
        }
        writer.add(input)
        let systemAudioInput = settings.recordSystemAudio ? makeAudioInput() : nil
        if let systemAudioInput {
            guard writer.canAdd(systemAudioInput) else {
                throw RecorderError.message("The video writer could not accept system audio.")
            }
            writer.add(systemAudioInput)
        }
        let microphoneAudioInput = settings.recordMicrophone ? makeAudioInput() : nil
        if let microphoneAudioInput {
            guard writer.canAdd(microphoneAudioInput) else {
                throw RecorderError.message("The video writer could not accept microphone audio.")
            }
            writer.add(microphoneAudioInput)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height)
        ])

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if settings.recordSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
        if settings.recordMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: outputQueue)
        }

        self.writer = writer
        self.writerInput = input
        self.systemAudioInput = systemAudioInput
        self.microphoneAudioInput = microphoneAudioInput
        self.pixelBufferAdaptor = adaptor
        self.stream = stream
        self.firstVideoTime = nil
        self.frameCount = 0
        self.stopRequested = false
        self.cursorSamples = []
        self.clickEvents = []
        self.keystrokeEvents = []
        self.cursorShapeSamples = []
        self.lastCursorShape = nil
        self.manualZoomTimes = []
        self.recordingStartedAt = Date()
        self.activeSettings = settings
        self.activeSource = source
        self.activeOutputSize = outputSize
        self.activeRawURL = rawURL

        await MainActor.run {
            self.status = "Recording \(Int(outputSize.width))x\(Int(outputSize.height)) at \(settings.frameRate) fps"
            self.isRecording = true
            self.previewImage = nil
            self.elapsedRecordingTime = 0
            self.manualZoomCount = 0
            self.startCursorTimer()
            self.startElapsedTimer()
            self.startEventMonitors(settings: settings)
        }
        try await stream.startCapture()
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess() || granted
        if hasScreenRecordingPermission {
            status = "Screen Recording permission granted"
        } else {
            status = "Enable Focus Recorder in System Settings, then quit and reopen the app"
        }
        return hasScreenRecordingPermission
    }

    func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            break
        }
    }

    func openInputMonitoringSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            break
        }
    }

    func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ]
        for value in urls {
            guard let url = URL(string: value), NSWorkspace.shared.open(url) else { continue }
            break
        }
    }

    func setMicrophoneMonitoring(enabled: Bool, deviceID: String?) {
        guard enabled else {
            stopMicrophoneMeter()
            return
        }
        Task {
            guard await ensureMicrophonePermission() else {
                await MainActor.run {
                    self.stopMicrophoneMeter()
                }
                return
            }
            await MainActor.run {
                self.startMicrophoneMeter(deviceID: deviceID)
            }
        }
    }

    @discardableResult
    private func updateScreenRecordingPermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.hasScreenRecordingPermission = granted
        }
        return granted
    }

    private func ensureScreenRecordingPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            await MainActor.run {
                self.hasScreenRecordingPermission = true
            }
            return true
        }
        return await MainActor.run {
            self.requestScreenRecordingPermission()
        }
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            await MainActor.run { self.hasMicrophonePermission = true }
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            await MainActor.run { self.hasMicrophonePermission = granted }
            return granted
        default:
            await MainActor.run { self.hasMicrophonePermission = false }
            return false
        }
    }

    private func startMicrophoneMeter(deviceID: String?) {
        stopMicrophoneMeter()
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard let device = microphoneCaptureDevice(id: deviceID) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: microphoneMeterQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()

        microphoneMeterSession = session
        microphoneMeterQueue.async {
            session.startRunning()
        }
    }

    private func stopMicrophoneMeter() {
        guard let session = microphoneMeterSession else {
            microphoneLevel = 0
            return
        }
        microphoneMeterSession = nil
        microphoneLevel = 0
        microphoneMeterQueue.async {
            session.stopRunning()
        }
    }

    private func microphoneCaptureDevice(id: String?) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        guard let id else { return devices.first }
        return devices.first { $0.uniqueID == id } ?? devices.first
    }

    func stop() async throws -> RecordingSession? {
        guard isRecording else { return nil }
        await MainActor.run {
            self.cursorTimer?.invalidate()
            self.cursorTimer = nil
            self.elapsedTimer?.invalidate()
            self.elapsedTimer = nil
            self.stopEventMonitors()
            self.status = "Finishing recording..."
        }

        stopRequested = true
        var stopError: Error?
        do {
            try await stream?.stopCapture()
        } catch {
            stopError = error
        }

        let result = await finishWriterOnOutputQueue()
        let rawURL = activeRawURL
        let capturedFrames = frameCount

        await MainActor.run {
            self.stream = nil
            self.writer = nil
            self.writerInput = nil
            self.systemAudioInput = nil
            self.microphoneAudioInput = nil
            self.pixelBufferAdaptor = nil
            self.firstVideoTime = nil
            self.isRecording = false
        }

        guard let rawURL else { return nil }
        guard capturedFrames > 0 else {
            try? FileManager.default.removeItem(at: rawURL)
            throw RecorderError.message("No video frames were captured. Check Screen Recording permission and try a display or region source first.")
        }
        if let error = result.error {
            throw error
        }
        if let stopError, result.completed == false {
            throw stopError
        }
        guard result.completed else {
            throw RecorderError.message("Recording did not finish successfully.")
        }

        let timelineURL = rawURL.deletingPathExtension().appendingPathExtension("focusrecorder.json")
        let measured = await Self.probeDuration(url: rawURL)
        var session = RecordingSession(
            createdAt: Date(),
            rawVideoURL: rawURL,
            timelineURL: timelineURL,
            width: Int(activeOutputSize.width),
            height: Int(activeOutputSize.height),
            settings: activeSettings,
            cursorSamples: cursorSamples,
            zooms: [],
            clicks: clickEvents,
            keystrokes: keystrokeEvents,
            cursorShapes: cursorShapeSamples
        )
        session.measuredDuration = measured
        let totalDuration = max(measured, cursorSamples.last?.time ?? 0)
        var zooms = Self.defaultZooms(
            samples: cursorSamples,
            clicks: clickEvents,
            keystrokes: keystrokeEvents,
            settings: activeSettings,
            width: Double(activeOutputSize.width),
            height: Double(activeOutputSize.height),
            duration: totalDuration
        )
        // Manual zoom markers (recorded via the hotkey) always become zooms regardless of the
        // automaticZooms toggle. They take priority over auto-generated ones nearby.
        let manualZooms = Self.manualZooms(
            times: manualZoomTimes,
            samples: cursorSamples,
            settings: activeSettings,
            width: Double(activeOutputSize.width),
            height: Double(activeOutputSize.height),
            duration: totalDuration
        )
        if !manualZooms.isEmpty {
            zooms = mergeZooms(automatic: zooms, manual: manualZooms)
        }
        session.zooms = zooms
        try TimelineStore.save(session)
        await MainActor.run {
            self.status = "Saved \(rawURL.lastPathComponent)"
        }
        return session
    }

    private func makeFilter(content: SCShareableContent, source: CaptureSource?, settings: RecordingSettings) throws -> SCContentFilter {
        switch settings.captureKind {
        case .display, .region:
            guard let displaySource = source ?? displays.first,
                  let display = content.displays.first(where: { "display-\($0.displayID)" == displaySource.id }) ?? content.displays.first
            else { throw RecorderError.message("Select a display to record.") }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let source,
                  let window = content.windows.first(where: { "window-\($0.windowID)" == source.id })
            else { throw RecorderError.message("Select a window to record.") }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func normalizedRegion(_ region: CGRect, source: CaptureSource?) -> CGRect {
        let maxWidth = CGFloat(source?.width ?? Int(region.maxX))
        let maxHeight = CGFloat(source?.height ?? Int(region.maxY))
        let minX = min(max(0, region.minX), max(0, maxWidth - 32))
        let minY = min(max(0, region.minY), max(0, maxHeight - 32))
        let maxX = min(maxWidth, max(minX + 32, region.maxX))
        let maxY = min(maxHeight, max(minY + 32, region.maxY))
        return CGRect(
            x: minX,
            y: minY,
            width: max(32, maxX - minX),
            height: max(32, maxY - minY)
        ).integral
    }

    private func finishWriterOnOutputQueue() async -> (completed: Bool, error: Error?) {
        return await withCheckedContinuation { (continuation: CheckedContinuation<(completed: Bool, error: Error?), Never>) in
            outputQueue.async {
                guard let writer = self.writer else {
                    continuation.resume(returning: (false, nil))
                    return
                }
                guard self.frameCount > 0 else {
                    writer.cancelWriting()
                    continuation.resume(returning: (false, writer.error))
                    return
                }
                self.writerInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneAudioInput?.markAsFinished()
                writer.finishWriting {
                    continuation.resume(returning: (writer.status == .completed, writer.error))
                }
            }
        }
    }

    private func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func startCursorTimer() {
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            let now = Date().timeIntervalSince(started)
            let point = NSEvent.mouseLocation
            let mapped = self.mapCursorToVideo(point)
            self.cursorSamples.append(CursorSample(
                time: now,
                x: mapped.x,
                y: mapped.y
            ))
            self.sampleCursorShape(at: now)
        }
    }

    /// Sample the OS-wide cursor shape and record an event whenever it changes. We only store
    /// transitions (plus a baseline at t=0) to keep the timeline JSON small.
    private func sampleCursorShape(at time: Double) {
        let shape = CursorShapeDetector.shared.currentShape()
        if cursorShapeSamples.isEmpty {
            cursorShapeSamples.append(CursorShapeSample(time: 0, shape: shape))
            lastCursorShape = shape
            return
        }
        if shape != lastCursorShape {
            cursorShapeSamples.append(CursorShapeSample(time: time, shape: shape))
            lastCursorShape = shape
        }
    }

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            DispatchQueue.main.async {
                self.elapsedRecordingTime = Date().timeIntervalSince(started)
            }
        }
    }

    private func startEventMonitors(settings: RecordingSettings) {
        if settings.detectClicks {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let started = self.recordingStartedAt else { return }
                let mapped = self.mapCursorToVideo(NSEvent.mouseLocation)
                self.clickEvents.append(MouseClickEvent(
                    time: Date().timeIntervalSince(started),
                    x: mapped.x,
                    y: mapped.y,
                    isRightClick: event.type == .rightMouseDown
                ))
            }
        }
        if settings.detectKeystrokes {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self, let started = self.recordingStartedAt else { return }
                self.keystrokeEvents.append(KeystrokeEvent(
                    time: Date().timeIntervalSince(started),
                    isModifier: event.type == .flagsChanged
                ))
            }
        }

        // Manual-zoom hotkey configured in Preferences (default ⌃⌥Z) while recording. The global
        // monitor fires when other apps are focused (Input Monitoring permission required for
        // keyDown to deliver). The local monitor handles the case where the recorder window
        // itself is focused.
        manualZoomGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            let hotkey = MainActor.assumeIsolated { PreferencesStore.shared.preferences.markZoomHotkey }
            guard event.keyCode == hotkey.keyCode else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                            .intersection([.control, .option, .shift, .command])
            guard flags == hotkey.modifiers else { return }
            self.markManualZoom()
        }
        manualZoomLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let hotkey = MainActor.assumeIsolated { PreferencesStore.shared.preferences.markZoomHotkey }
            guard event.keyCode == hotkey.keyCode else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                            .intersection([.control, .option, .shift, .command])
            guard flags == hotkey.modifiers else { return event }
            self.markManualZoom()
            return nil
        }
    }

    private func stopEventMonitors() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = manualZoomGlobalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = manualZoomLocalMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        keyMonitor = nil
        manualZoomGlobalMonitor = nil
        manualZoomLocalMonitor = nil
    }

    /// Mark the current recording time as a manual zoom point. Safe to call from any thread.
    /// Resolves to a real `ZoomKeyframe` when the recording stops.
    func markManualZoom() {
        guard isRecording, let started = recordingStartedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        // Coalesce double-presses so a held hotkey doesn't dump dozens of duplicates.
        if let last = manualZoomTimes.last, elapsed - last < 0.4 { return }
        manualZoomTimes.append(elapsed)
        let count = manualZoomTimes.count
        DispatchQueue.main.async {
            self.manualZoomCount = count
        }
    }

    private func mapCursorToVideo(_ screenPoint: CGPoint) -> CGPoint {
        let sourceRect: CGRect
        if activeSettings.captureKind == .region {
            let displayFrame = activeSource?.frame ?? NSScreen.main?.frame ?? CGRect(origin: .zero, size: activeOutputSize)
            let region = activeSettings.region
            sourceRect = CGRect(
                x: displayFrame.minX + region.minX,
                y: displayFrame.maxY - region.maxY,
                width: region.width,
                height: region.height
            )
        } else if let source = activeSource {
            sourceRect = source.frame
        } else {
            sourceRect = CGRect(origin: .zero, size: activeOutputSize)
        }

        let x = (screenPoint.x - sourceRect.minX) / max(1, sourceRect.width) * activeOutputSize.width
        let y = (sourceRect.maxY - screenPoint.y) / max(1, sourceRect.height) * activeOutputSize.height
        return CGPoint(x: min(max(0, x), activeOutputSize.width), y: min(max(0, y), activeOutputSize.height))
    }

    private static func screenFrame(displayID: CGDirectDisplayID, width: Int, height: Int) -> CGRect {
        if let screen = NSScreen.screens.first(where: { screen in
            guard let value = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return value.uint32Value == displayID
        }) {
            return screen.frame
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func makeOutputURL(suffix: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let name = "FocusRecorder-\(formatter.string(from: Date()))-\(suffix).mov"
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusRecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private static func probeDuration(url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }

    // MARK: - Auto zoom

    /// Build smart zoom keyframes from cursor samples + click events + typing intervals.
    /// Clicks are treated as the strongest signal (Screen Studio-style). Cursor dwell-after-travel
    /// is used as a secondary signal. Typing intervals suppress zoom-out so consecutive close
    /// zooms blend instead of cutting back to 1x.
    static func defaultZooms(
        samples: [CursorSample],
        clicks: [MouseClickEvent] = [],
        keystrokes: [KeystrokeEvent] = [],
        settings: RecordingSettings,
        width: Double,
        height: Double,
        duration: Double = 0
    ) -> [ZoomKeyframe] {
        guard settings.automaticZooms else { return [] }
        let totalDuration = max(duration, samples.last?.time ?? 0, clicks.last?.time ?? 0)
        guard totalDuration > 1.5 else { return [] }

        let sortedSamples = samples.sorted { $0.time < $1.time }
        let sortedClicks = clicks.sorted { $0.time < $1.time }
        let typingSpans = computeTypingSpans(keystrokes: keystrokes)
        let marginX = width * 0.16
        let marginY = height * 0.16
        let defaultScale = min(max(settings.automaticZoomScale, 1.15), 2.25)

        // 1. Build click-based candidates (primary signal). This mirrors the Screen Studio model:
        // automatic zooms focus areas where clicks occurred; cursor dwell is only a fallback.
        var candidates: [Candidate] = []
        // If another click lands before the current zoom would naturally settle, keep it in the
        // same cursor-following zoom segment instead of creating overlapping timeline blocks.
        let clickClusterGap = 2.15
        var i = 0
        while i < sortedClicks.count {
            var clusterEnd = i
            while clusterEnd + 1 < sortedClicks.count,
                  sortedClicks[clusterEnd + 1].time - sortedClicks[clusterEnd].time < clickClusterGap {
                clusterEnd += 1
            }
            let cluster = Array(sortedClicks[i...clusterEnd])
            let avgX = cluster.reduce(0.0) { $0 + $1.x } / Double(cluster.count)
            let avgY = cluster.reduce(0.0) { $0 + $1.y } / Double(cluster.count)
            let clusterStart = cluster.first!.time
            let clusterStop = cluster.last!.time
            candidates.append(Candidate(
                time: clusterStart,
                endTime: clusterStop,
                x: avgX,
                y: avgY,
                weight: 3.0 + Double(cluster.count) * 0.4,
                kind: .click
            ))
            i = clusterEnd + 1
        }

        // 2. Cursor dwell-after-travel candidates only when no click data exists.
        if candidates.isEmpty, !sortedSamples.isEmpty {
            let minMove = max(90, min(width, height) * 0.075)
            let maxDwell = max(55, min(width, height) * 0.055)
            let step = max(1, sortedSamples.count / 600)
            for index in stride(from: 0, to: sortedSamples.count, by: step) {
                let sample = sortedSamples[index]
                guard sample.time > 0.8, sample.time < totalDuration - 0.6,
                      let before = nearestSample(to: sample.time - 0.7, in: sortedSamples),
                      let after = nearestSample(to: sample.time + 0.85, in: sortedSamples)
                else { continue }
                let approach = hypot(sample.x - before.x, sample.y - before.y)
                let dwell = hypot(after.x - sample.x, after.y - sample.y)
                if approach >= minMove, dwell <= maxDwell {
                    candidates.append(Candidate(
                        time: sample.time,
                        endTime: sample.time,
                        x: sample.x,
                        y: sample.y,
                        weight: 1.0,
                        kind: .dwell
                    ))
                }
            }
        }

        // 3. Merge candidates into clusters by proximity in time
        candidates.sort { $0.time < $1.time }
        let mergeGap = candidates.contains(where: { $0.kind == .click }) ? 2.25 : 2.0
        var merged: [Candidate] = []
        for candidate in candidates {
            if let last = merged.last, candidate.time - last.endTime < mergeGap {
                merged[merged.count - 1] = last.merged(with: candidate)
            } else {
                merged.append(candidate)
            }
        }

        // 4. Convert clusters to keyframes. Each click zoom has an anticipation lead-in, a fixed
        // focal point, and a relaxed zoom-out. Keeping the target fixed makes the camera travel
        // directly from A to B instead of bending along the cursor's smoothed path.
        var zooms: [ZoomKeyframe] = []
        for cluster in merged {
            let preroll = cluster.kind == .click ? 0.62 : 0.78
            let trailing = cluster.kind == .click ? 1.45 : 1.1
            var start = max(0, cluster.time - preroll)
            var endTime = cluster.endTime + trailing

            // Extend to cover any typing span overlapping this cluster
            if let span = typingSpans.first(where: { $0.start <= cluster.endTime + 0.6 && $0.end + 0.4 >= cluster.time }) {
                endTime = max(endTime, span.end + 0.6)
            }

            let dur = max(cluster.kind == .click ? 1.9 : 1.6, endTime - start)
            if start + dur > totalDuration {
                start = max(0, totalDuration - dur)
            }
            let focalCursor = nearestSample(to: cluster.time, in: sortedSamples)
                ?? CursorSample(time: cluster.time, x: cluster.x, y: cluster.y)
            let cx = min(max(focalCursor.x, marginX), width - marginX)
            let cy = min(max(focalCursor.y, marginY), height - marginY)
            zooms.append(ZoomKeyframe(
                start: start,
                duration: min(dur, max(1.5, totalDuration - start)),
                scale: defaultScale,
                centerX: cx,
                centerY: cy,
                easing: cluster.kind == .click ? .smooth : .gentle,
                rampFraction: cluster.kind == .click ? 0.26 : 0.36,
                followCursor: false,
                followCursorSmoothing: cluster.kind == .click ? 1.15 : 0.72,
                followCursorDelay: cluster.kind == .click ? 0.16 : 0.10
            ))
        }
        return coalescedZooms(zooms, totalDuration: totalDuration)
    }

    private struct Candidate {
        var time: Double
        var endTime: Double
        var x: Double
        var y: Double
        var weight: Double
        var kind: Kind

        enum Kind { case click, dwell }

        func merged(with other: Candidate) -> Candidate {
            let totalWeight = weight + other.weight
            return Candidate(
                time: min(time, other.time),
                endTime: max(endTime, other.endTime),
                x: (x * weight + other.x * other.weight) / totalWeight,
                y: (y * weight + other.y * other.weight) / totalWeight,
                weight: totalWeight,
                kind: kind == .click || other.kind == .click ? .click : .dwell
            )
        }
    }

    private struct TypingSpan {
        var start: Double
        var end: Double
    }

    private static func coalescedZooms(_ zooms: [ZoomKeyframe], totalDuration: Double) -> [ZoomKeyframe] {
        let sorted = zooms.sorted { $0.start < $1.start }
        var output: [ZoomKeyframe] = []
        let overlapSlack = 0.14
        for zoom in sorted {
            guard var last = output.last else {
                output.append(zoom)
                continue
            }
            let lastEnd = last.start + last.duration
            if zoom.start <= lastEnd + overlapSlack {
                let mergedStart = min(last.start, zoom.start)
                let mergedEnd = min(totalDuration, max(lastEnd, zoom.start + zoom.duration))
                let lastWeight = max(0.001, last.duration)
                let zoomWeight = max(0.001, zoom.duration)
                let totalWeight = lastWeight + zoomWeight
                last.start = mergedStart
                last.duration = max(1.6, mergedEnd - mergedStart)
                last.scale = max(last.scale, zoom.scale)
                last.centerX = (last.centerX * lastWeight + zoom.centerX * zoomWeight) / totalWeight
                last.centerY = (last.centerY * lastWeight + zoom.centerY * zoomWeight) / totalWeight
                last.easing = .smooth
                last.rampFraction = min(last.rampFraction, zoom.rampFraction, 0.28)
                last.followCursor = last.followCursor || zoom.followCursor
                last.followCursorSmoothing = max(last.followCursorSmoothing, zoom.followCursorSmoothing)
                last.followCursorDelay = max(last.followCursorDelay, zoom.followCursorDelay)
                output[output.count - 1] = last
            } else {
                output.append(zoom)
            }
        }
        return output
    }

    private static func computeTypingSpans(keystrokes: [KeystrokeEvent]) -> [TypingSpan] {
        let chars = keystrokes.filter { !$0.isModifier }.map(\.time).sorted()
        guard chars.count >= 4 else { return [] }
        var spans: [TypingSpan] = []
        var spanStart = chars[0]
        var spanEnd = chars[0]
        for time in chars.dropFirst() {
            if time - spanEnd <= 1.4 {
                spanEnd = time
            } else {
                if spanEnd - spanStart >= 0.8 {
                    spans.append(TypingSpan(start: spanStart, end: spanEnd))
                }
                spanStart = time
                spanEnd = time
            }
        }
        if spanEnd - spanStart >= 0.8 {
            spans.append(TypingSpan(start: spanStart, end: spanEnd))
        }
        return spans
    }

    /// Build zoom keyframes from manual hotkey markers.
    static func manualZooms(
        times: [Double],
        samples: [CursorSample],
        settings: RecordingSettings,
        width: Double,
        height: Double,
        duration: Double
    ) -> [ZoomKeyframe] {
        guard !times.isEmpty, duration > 0.5 else { return [] }
        let sortedSamples = samples.sorted { $0.time < $1.time }
        let marginX = width * 0.16
        let marginY = height * 0.16
        let scale = min(max(settings.automaticZoomScale, 1.15), 2.4)
        let preroll = 0.55
        let trailing = 1.85
        let zooms = times.map { mark in
            let cursor = nearestSample(to: mark, in: sortedSamples)
                ?? CursorSample(time: mark, x: width / 2, y: height / 2)
            let cx = min(max(cursor.x, marginX), width - marginX)
            let cy = min(max(cursor.y, marginY), height - marginY)
            let start = max(0, mark - preroll)
            let rawDuration = preroll + trailing
            let dur = max(1.5, min(rawDuration, max(1.5, duration - start)))
            return ZoomKeyframe(
                start: start,
                duration: dur,
                scale: scale,
                centerX: cx,
                centerY: cy,
                easing: .smooth,
                rampFraction: 0.26,
                followCursor: false,
                followCursorSmoothing: 1.05,
                followCursorDelay: 0.14
            )
        }
        return coalescedZooms(zooms, totalDuration: duration)
    }

    /// Merge manual zooms over auto-generated ones. Auto zooms whose window overlaps a manual
    /// marker are dropped so the manual one wins.
    private func mergeZooms(automatic: [ZoomKeyframe], manual: [ZoomKeyframe]) -> [ZoomKeyframe] {
        let kept = automatic.filter { auto in
            let autoEnd = auto.start + auto.duration
            return !manual.contains { manualZoom in
                let manualEnd = manualZoom.start + manualZoom.duration
                return auto.start < manualEnd && autoEnd > manualZoom.start
            }
        }
        var out = kept + manual
        out.sort { $0.start < $1.start }
        return out
    }

    private static func nearestSample(to time: Double, in samples: [CursorSample]) -> CursorSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return samples[0] }
        let previous = samples[low - 1]
        let current = samples[low]
        return abs(previous.time - time) < abs(current.time - time) ? previous : current
    }
}

extension CaptureEngine: @unchecked Sendable {}

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            appendVideoSample(sampleBuffer)
        case .audio:
            appendAudioSample(sampleBuffer, input: systemAudioInput)
        case .microphone:
            publishAudioLevel(from: sampleBuffer)
            appendAudioSample(sampleBuffer, input: microphoneAudioInput)
        @unknown default:
            return
        }
    }

    private func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        publishPreviewIfNeeded(from: imageBuffer)

        guard let writer, let input = writerInput, let adaptor = pixelBufferAdaptor else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstVideoTime == nil {
            firstVideoTime = presentationTime
            guard writer.startWriting() else {
                DispatchQueue.main.async {
                    self.status = "Could not start video writer: \(writer.error?.localizedDescription ?? "Unknown writer error")"
                }
                return
            }
            writer.startSession(atSourceTime: .zero)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }

        let relativeTime = CMTimeSubtract(presentationTime, firstVideoTime ?? presentationTime)
        let appendTime = relativeTime < .zero ? .zero : relativeTime
        guard let frameBuffer = frameBufferForWriting(from: imageBuffer, adaptor: adaptor) else { return }
        if adaptor.append(frameBuffer, withPresentationTime: appendTime) {
            frameCount += 1
        }
    }

    private func appendAudioSample(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        guard let writer, writer.status == .writing, let input, input.isReadyForMoreMediaData else { return }
        guard let retimedSample = retimedSampleBuffer(sampleBuffer) else { return }
        input.append(retimedSample)
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let firstVideoTime else { return nil }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let relativeTime = CMTimeSubtract(presentationTime, firstVideoTime)
        guard relativeTime >= .zero else { return nil }

        let sampleCount = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: sampleCount
        )
        var timingCount = 0
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timing.count,
            arrayToFill: &timing,
            entriesNeededOut: &timingCount
        )
        guard timingStatus == noErr, timingCount > 0 else { return nil }

        for index in 0..<timingCount {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, firstVideoTime)
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, firstVideoTime)
            }
        }

        var retimedSample: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimedSample
        )
        guard copyStatus == noErr else { return nil }
        return retimedSample
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stopRequested { return }
        DispatchQueue.main.async {
            self.status = "Capture stopped: \(error.localizedDescription)"
            self.isRecording = false
        }
    }

    private func publishPreviewIfNeeded(from imageBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewTime) >= 1.0 / 15.0 else { return }
        lastPreviewTime = now

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = previewContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        DispatchQueue.main.async {
            self.previewImage = nsImage
        }
    }

    private func frameBufferForWriting(
        from imageBuffer: CVPixelBuffer,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        let outputWidth = max(2, Int(activeOutputSize.width))
        let outputHeight = max(2, Int(activeOutputSize.height))
        let inputWidth = CVPixelBufferGetWidth(imageBuffer)
        let inputHeight = CVPixelBufferGetHeight(imageBuffer)
        guard inputWidth != outputWidth || inputHeight != outputHeight else {
            return imageBuffer
        }
        guard let pool = adaptor.pixelBufferPool else { return nil }

        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer) == kCVReturnSuccess,
              let outBuffer
        else { return nil }

        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let scaleX = CGFloat(outputWidth) / CGFloat(max(1, inputWidth))
        let scaleY = CGFloat(outputHeight) / CGFloat(max(1, inputHeight))
        let image = CIImage(cvPixelBuffer: imageBuffer)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: outputRect)
        previewContext.render(
            image,
            to: outBuffer,
            bounds: outputRect,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return outBuffer
    }
}

extension CaptureEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        publishAudioLevel(from: sampleBuffer)
    }

    private func publishAudioLevel(from sampleBuffer: CMSampleBuffer) {
        guard let level = Self.audioLevel(from: sampleBuffer) else { return }
        DispatchQueue.main.async {
            self.microphoneLevel = max(0, min(1, level))
        }
    }

    private static func audioLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var neededSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let flags = streamDescription.pointee.mFormatFlags
        let bitsPerChannel = streamDescription.pointee.mBitsPerChannel
        var sumSquares = 0.0
        var sampleCount = 0
        var storage = [UInt8](repeating: 0, count: max(neededSize, MemoryLayout<AudioBufferList>.size))
        let ok = storage.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let audioBufferList = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: rawBuffer.count,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return false }

            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                guard let data = buffer.mData else { continue }
                let byteCount = Int(buffer.mDataByteSize)
                if flags & kAudioFormatFlagIsFloat != 0 {
                    let samples = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
                    let count = byteCount / MemoryLayout<Float>.size
                    for index in 0..<count {
                        let value = Double(samples[index])
                        sumSquares += value * value
                    }
                    sampleCount += count
                } else if bitsPerChannel == 16 {
                    let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
                    let count = byteCount / MemoryLayout<Int16>.size
                    for index in 0..<count {
                        let value = Double(samples[index]) / Double(Int16.max)
                        sumSquares += value * value
                    }
                    sampleCount += count
                }
            }
            return true
        }
        guard ok else { return nil }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return min(1, pow(rms * 8, 0.7))
    }
}

enum RecorderError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
