import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    static let shared = AppViewModel()

    @Published var settings = RecordingSettings()
    @Published var currentSession: RecordingSession?
    @Published var errorMessage: String?
    @Published var playbackTime: Double = 0
    @Published var selectedZoomID: UUID?
    @Published var selectedZoomIDs: Set<UUID> = []
    @Published var library: [LibraryItem] = []

    let capture = CaptureEngine()
    let renderer = ExportRenderer()
    let previewCache = PreviewCacheStore()
    private var cancellables: Set<AnyCancellable> = []
    private var undoStack: [RecordingSession] = []
    private var redoStack: [RecordingSession] = []
    private let undoLimit = 40
    private var undoTransactionIsOpen = false
    private let zoomPasteboardType = NSPasteboard.PasteboardType("local.focusrecorder.zooms")

    struct LibraryItem: Identifiable, Hashable {
        let id: UUID
        let createdAt: Date
        let name: String
        let timelineURL: URL
    }

    private var globalToggleRecordMonitor: Any?

    init() {
        capture.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        renderer.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        previewCache.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        PreferencesStore.shared.applyDefaults(to: &settings)
        loadLibrary()
        installGlobalToggleRecordMonitor()
    }

    private func installGlobalToggleRecordMonitor() {
        globalToggleRecordMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            let hotkey = PreferencesStore.shared.preferences.toggleRecordHotkey
            guard event.keyCode == hotkey.keyCode else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                            .intersection([.control, .option, .shift, .command])
            guard flags == hotkey.modifiers else { return }
            Task { @MainActor in self.toggleRecording() }
        }
    }

    func refresh() {
        Task { await capture.refreshSources() }
    }

    func toggleRecording() {
        Task {
            do {
                if capture.isRecording {
                    let session = try await capture.stop()
                    setCurrentSession(session)
                    if session != nil {
                        loadLibrary()
                        if PreferencesStore.shared.preferences.openEditorWhenRecordingStops {
                            EditorWindowController.shared.show(model: self)
                            NotificationCenter.default.post(name: .focusRecorderShowEditor, object: nil)
                        }
                        NotificationCenter.default.post(name: .focusRecorderShowRecorder, object: nil)
                    }
                } else {
                    try await capture.start(settings: settings)
                    if PreferencesStore.shared.preferences.hideBarWhileRecording {
                        NotificationCenter.default.post(name: .focusRecorderHideRecorder, object: nil)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Mark the current recording moment as a zoom point. The marker is converted to a real
    /// `ZoomKeyframe` when the recording stops, so it shows up in the editor automatically.
    func markZoomDuringRecording() {
        capture.markManualZoom()
    }

    // MARK: - Zoom edits

    func addZoomAtPlayhead() {
        guard let session = currentSession else { return }
        pushUndo(session)
        var updated = session
        let cursor = nearestCursor(in: session, at: playbackTime)
            ?? CursorSample(time: playbackTime, x: Double(session.width) / 2, y: Double(session.height) / 2)
        let zoom = ZoomKeyframe(
            start: max(0, playbackTime - 0.45),
            duration: 3.5,
            scale: max(1.05, settings.automaticZoomScale),
            centerX: cursor.x,
            centerY: cursor.y,
            easing: .smooth
        )
        updated.zooms.append(zoom)
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectOnlyZoom(zoom.id)
    }

    func deleteZoom(_ zoom: ZoomKeyframe) {
        guard let session = currentSession else { return }
        pushUndo(session)
        var updated = session
        updated.zooms.removeAll { $0.id == zoom.id }
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectedZoomIDs.remove(zoom.id)
        if selectedZoomID == zoom.id {
            selectOnlyZoom(updated.zooms.first?.id)
        }
    }

    func updateZoom(_ zoom: ZoomKeyframe, recordUndo: Bool = false) {
        guard let session = currentSession,
              let index = session.zooms.firstIndex(where: { $0.id == zoom.id })
        else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        var updated = session
        var normalized = zoom
        let duration = max(1, updated.approximateDuration)
        normalized.duration = min(max(0.6, normalized.duration), max(0.6, duration))
        normalized.start = min(max(0, normalized.start), max(0, duration - normalized.duration))
        normalized.scale = min(max(1, normalized.scale), 3)
        normalized.centerX = min(max(0, normalized.centerX), Double(updated.width))
        normalized.centerY = min(max(0, normalized.centerY), Double(updated.height))
        normalized.rampFraction = min(max(0.04, normalized.rampFraction), 0.48)
        normalized.zoomInDuration = min(max(0.08, normalized.zoomInDuration), normalized.duration)
        normalized.zoomOutDuration = min(max(0.08, normalized.zoomOutDuration), normalized.duration)
        if normalized.zoomInDuration + normalized.zoomOutDuration > normalized.duration {
            let factor = normalized.duration / max(0.001, normalized.zoomInDuration + normalized.zoomOutDuration)
            normalized.zoomInDuration *= factor
            normalized.zoomOutDuration *= factor
        }
        normalized.bezier = normalized.bezier.clamped()
        normalized.followCursorSmoothing = min(max(0, normalized.followCursorSmoothing), 2)
        normalized.followCursorDelay = min(max(0, normalized.followCursorDelay), 0.8)
        normalized.followCursorDeadZoneWidth = min(max(0.08, normalized.followCursorDeadZoneWidth), 0.92)
        normalized.followCursorDeadZoneHeight = min(max(0.08, normalized.followCursorDeadZoneHeight), 0.92)
        normalized.followCursorAnchorX = min(max(0.12, normalized.followCursorAnchorX), 0.88)
        normalized.followCursorAnchorY = min(max(0.12, normalized.followCursorAnchorY), 0.88)
        updated.zooms[index] = normalized
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectedZoomID = normalized.id
        selectedZoomIDs.insert(normalized.id)
    }

    func splitZoomAtPlayhead() {
        guard let session = currentSession else { return }
        let t = playbackTime
        let t0 = session.timelineContentStart
        let t1 = session.timelineContentEnd
        if let zoom = session.zooms.first(where: { $0.start < t && $0.start + $0.duration > t }) {
            pushUndo(session)
            var updated = session
            let firstDuration = max(0.6, t - zoom.start - 0.05)
            let secondStart = t + 0.05
            let secondDuration = max(0.6, zoom.start + zoom.duration - secondStart)
            if let index = updated.zooms.firstIndex(where: { $0.id == zoom.id }) {
                var first = zoom
                first.duration = firstDuration
                updated.zooms[index] = first

                var second = zoom
                second.id = UUID()
                second.start = secondStart
                second.duration = secondDuration
                updated.zooms.append(second)
                updated.zooms.sort { $0.start < $1.start }
                selectOnlyZoom(second.id)
            }
            applySession(updated)
            previewCache.invalidate(for: updated)
            return
        }
        // No zoom under playhead: trim the clip after the playhead (rough cut).
        guard t > t0 + 0.12, t < t1 - 0.05 else { return }
        pushUndo(session)
        var updated = session
        updated.timelineTrimEnd = max(0, updated.approximateDuration - t)
        updated.normalizeTimelineTrims()
        applySession(updated)
        previewCache.invalidate(for: updated)
        playbackTime = min(max(t, updated.timelineContentStart), updated.timelineContentEnd - 0.001)
    }

    func updateTimelineTrims(trimStart: Double? = nil, trimEnd: Double? = nil, recordUndo: Bool = true) {
        guard var session = currentSession else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        if let trimStart { session.timelineTrimStart = trimStart }
        if let trimEnd { session.timelineTrimEnd = trimEnd }
        session.normalizeTimelineTrims()
        applySession(session)
        previewCache.invalidate(for: session)
        playbackTime = min(max(playbackTime, session.timelineContentStart), session.timelineContentEnd - 0.001)
    }

    func regenerateAutomaticZooms() {
        guard let session = currentSession else { return }
        pushUndo(session)
        var updated = session
        updated.zooms = CaptureEngine.defaultZooms(
            samples: updated.cursorSamples,
            clicks: updated.clicks,
            keystrokes: updated.keystrokes,
            settings: updated.settings,
            width: Double(updated.width),
            height: Double(updated.height),
            duration: updated.measuredDuration
        )
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectOnlyZoom(updated.zooms.first?.id)
    }

    func clearAllZooms() {
        guard let session = currentSession else { return }
        pushUndo(session)
        var updated = session
        updated.zooms = []
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectOnlyZoom(nil)
    }

    func duplicateSelectedZoom() {
        guard let session = currentSession else { return }
        let selected = selectedZooms(in: session)
        guard !selected.isEmpty else { return }
        pushUndo(session)
        var updated = session
        let duration = max(1, session.approximateDuration)
        let gap = 0.05
        var newIDs: [UUID] = []
        for zoom in selected.sorted(by: { $0.start < $1.start }) {
            var duplicate = zoom
            duplicate.id = UUID()
            let proposedStart = zoom.start + zoom.duration + gap
            duplicate.start = min(max(0, proposedStart), max(0, duration - duplicate.duration))
            newIDs.append(duplicate.id)
            updated.zooms.append(duplicate)
        }
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectedZoomIDs = Set(newIDs)
        selectedZoomID = newIDs.last
    }

    func centerSelectedZoomOnCursor() {
        guard let session = currentSession,
              let id = selectedZoomID,
              var zoom = session.zooms.first(where: { $0.id == id })
        else { return }
        let cursor = nearestCursor(in: session, at: playbackTime)
            ?? CursorSample(time: playbackTime, x: Double(session.width) / 2, y: Double(session.height) / 2)
        zoom.centerX = cursor.x
        zoom.centerY = cursor.y
        updateZoom(zoom, recordUndo: true)
    }

    func selectOnlyZoom(_ id: UUID?) {
        selectedZoomID = id
        selectedZoomIDs = id.map { [$0] } ?? []
    }

    func toggleZoomSelection(_ id: UUID) {
        if selectedZoomIDs.contains(id) {
            selectedZoomIDs.remove(id)
            if selectedZoomID == id {
                selectedZoomID = selectedZoomIDs.first
            }
        } else {
            selectedZoomIDs.insert(id)
            selectedZoomID = id
        }
    }

    func selectZoom(_ id: UUID, extending: Bool = false) {
        if extending {
            toggleZoomSelection(id)
        } else {
            selectOnlyZoom(id)
        }
    }

    func deleteSelectedZooms() {
        guard let session = currentSession else { return }
        let ids = selectedZoomIDs
        guard !ids.isEmpty else { return }
        pushUndo(session)
        var updated = session
        updated.zooms.removeAll { ids.contains($0.id) }
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectOnlyZoom(updated.zooms.first?.id)
    }

    func copySelectedZooms() {
        guard let session = currentSession else { return }
        let zooms = selectedZooms(in: session)
        guard !zooms.isEmpty, let data = try? JSONEncoder().encode(zooms) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: zoomPasteboardType)
    }

    func cutSelectedZooms() {
        guard !selectedZoomIDs.isEmpty else { return }
        copySelectedZooms()
        deleteSelectedZooms()
    }

    func pasteZoomsAtPlayhead() {
        guard let session = currentSession,
              let data = NSPasteboard.general.data(forType: zoomPasteboardType),
              let pasted = try? JSONDecoder().decode([ZoomKeyframe].self, from: data),
              !pasted.isEmpty
        else { return }
        pushUndo(session)
        var updated = session
        let duration = max(1, session.approximateDuration)
        let firstStart = pasted.map(\.start).min() ?? 0
        var newIDs: [UUID] = []
        for original in pasted.sorted(by: { $0.start < $1.start }) {
            var zoom = original
            zoom.id = UUID()
            let offset = original.start - firstStart
            zoom.start = min(max(0, playbackTime + offset), max(0, duration - zoom.duration))
            newIDs.append(zoom.id)
            updated.zooms.append(zoom)
        }
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        previewCache.invalidate(for: updated)
        selectedZoomIDs = Set(newIDs)
        selectedZoomID = newIDs.first
    }

    var hasSelectedZooms: Bool { !selectedZoomIDs.isEmpty }
    var canPasteZooms: Bool { NSPasteboard.general.data(forType: zoomPasteboardType) != nil }

    func selectedZooms(in session: RecordingSession? = nil) -> [ZoomKeyframe] {
        guard let session = session ?? currentSession else { return [] }
        let ids = selectedZoomIDs.isEmpty ? Set(selectedZoomID.map { [$0] } ?? []) : selectedZoomIDs
        return session.zooms.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
    }

    func updateSelectedZooms(recordUndo: Bool = false, _ transform: (inout ZoomKeyframe) -> Void) {
        guard let session = currentSession else { return }
        let ids = selectedZoomIDs
        guard !ids.isEmpty else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        var updated = session
        for index in updated.zooms.indices where ids.contains(updated.zooms[index].id) {
            var zoom = updated.zooms[index]
            transform(&zoom)
            let duration = max(1, updated.approximateDuration)
            zoom.duration = min(max(0.6, zoom.duration), max(0.6, duration))
            zoom.start = min(max(0, zoom.start), max(0, duration - zoom.duration))
            zoom.scale = min(max(1, zoom.scale), 3)
            zoom.centerX = min(max(0, zoom.centerX), Double(updated.width))
            zoom.centerY = min(max(0, zoom.centerY), Double(updated.height))
            zoom.rampFraction = min(max(0.04, zoom.rampFraction), 0.48)
            zoom.zoomInDuration = min(max(0.08, zoom.zoomInDuration), zoom.duration)
            zoom.zoomOutDuration = min(max(0.08, zoom.zoomOutDuration), zoom.duration)
            if zoom.zoomInDuration + zoom.zoomOutDuration > zoom.duration {
                let factor = zoom.duration / max(0.001, zoom.zoomInDuration + zoom.zoomOutDuration)
                zoom.zoomInDuration *= factor
                zoom.zoomOutDuration *= factor
            }
            zoom.bezier = zoom.bezier.clamped()
            zoom.followCursorSmoothing = min(max(0, zoom.followCursorSmoothing), 2)
            zoom.followCursorDelay = min(max(0, zoom.followCursorDelay), 0.8)
            zoom.followCursorDeadZoneWidth = min(max(0.08, zoom.followCursorDeadZoneWidth), 0.92)
            zoom.followCursorDeadZoneHeight = min(max(0.08, zoom.followCursorDeadZoneHeight), 0.92)
            zoom.followCursorAnchorX = min(max(0.12, zoom.followCursorAnchorX), 0.88)
            zoom.followCursorAnchorY = min(max(0.12, zoom.followCursorAnchorY), 0.88)
            updated.zooms[index] = zoom
        }
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        previewCache.invalidate(for: updated)
    }

    func alignSelectedZoomStartToPlayhead() {
        guard let session = currentSession,
              let id = selectedZoomID,
              var zoom = session.zooms.first(where: { $0.id == id })
        else { return }
        zoom.start = playbackTime
        updateZoom(zoom, recordUndo: true)
    }

    // MARK: - Edit settings (background, padding, etc.)

    func updateEditSettings(_ edit: EditSettings, recordUndo: Bool = false) {
        guard let session = currentSession else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        var updated = session
        updated.edit = edit
        applySession(updated, persist: true)
        previewCache.invalidate(for: updated)
    }

    func updateSessionSettings(_ settings: RecordingSettings, recordUndo: Bool = false) {
        guard let session = currentSession else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        var updated = session
        updated.settings = settings
        self.settings = settings
        applySession(updated, persist: true)
        previewCache.invalidate(for: updated)
    }

    // MARK: - Undo/redo

    func undo() {
        guard let prior = undoStack.popLast(), let current = currentSession else { return }
        undoTransactionIsOpen = false
        redoStack.append(current)
        applySession(prior, recordHistory: false)
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = currentSession else { return }
        undoTransactionIsOpen = false
        undoStack.append(current)
        applySession(next, recordHistory: false)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func beginUndoTransaction() {
        guard !undoTransactionIsOpen, let session = currentSession else { return }
        pushUndo(session)
        undoTransactionIsOpen = true
    }

    func endUndoTransaction() {
        undoTransactionIsOpen = false
    }

    private func pushUndo(_ session: RecordingSession) {
        undoStack.append(session)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    // MARK: - Export

    func exportRendered() {
        guard let session = currentSession else { return }
        Task {
            do {
                let renderedURL = try await renderer.render(session: session, outputDirectory: session.exportDirectoryURL)
                var updated = session
                updated.renderedVideoURL = renderedURL
                applySession(updated, persist: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setExportDirectory(_ url: URL?) {
        guard let session = currentSession else { return }
        var updated = session
        updated.exportDirectoryURL = url
        applySession(updated, persist: true)
    }

    func revealRenderedFile() {
        guard let url = currentSession?.renderedVideoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Library

    func loadLibrary() {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusRecorder", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { library = []; return }
        let items: [LibraryItem] = contents
            .filter { $0.pathExtension == "json" || $0.lastPathComponent.hasSuffix(".focusrecorder.json") }
            .compactMap { url in
                guard let session = try? TimelineStore.load(from: url) else { return nil }
                return LibraryItem(
                    id: session.id,
                    createdAt: session.createdAt,
                    name: session.rawVideoURL.lastPathComponent,
                    timelineURL: url
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
        library = items
    }

    func openLibraryItem(_ item: LibraryItem) {
        do {
            let session = try TimelineStore.load(from: item.timelineURL)
            setCurrentSession(session)
            NotificationCenter.default.post(name: .focusRecorderShowEditor, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func applySession(_ session: RecordingSession, persist: Bool = true, recordHistory: Bool = true) {
        currentSession = session
        if persist {
            try? TimelineStore.save(session)
        }
    }

    private func setCurrentSession(_ session: RecordingSession?, keepPlayback: Bool = false) {
        currentSession = session
        selectOnlyZoom(session?.zooms.first?.id)
        if let session {
            settings = session.settings
        }
        undoStack = []
        redoStack = []
        undoTransactionIsOpen = false
        if !keepPlayback {
            playbackTime = session?.timelineContentStart ?? 0
        }
    }

    private func nearestCursor(in session: RecordingSession, at time: Double) -> CursorSample? {
        session.cursorSamples.min { abs($0.time - time) < abs($1.time - time) }
    }
}
