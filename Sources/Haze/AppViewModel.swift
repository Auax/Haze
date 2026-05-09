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
    private var cancellables: Set<AnyCancellable> = []
    private var undoStack: [RecordingSession] = []
    private var redoStack: [RecordingSession] = []
    private let undoLimit = 40
    private var undoTransactionIsOpen = false
    private let zoomPasteboardType = NSPasteboard.PasteboardType("local.haze.zooms")

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
        NotificationCenter.default.publisher(for: .hazeCursorAssetFailed)
            .compactMap { $0.userInfo?["message"] as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.errorMessage = message
            }
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
                            NotificationCenter.default.post(name: .hazeShowEditor, object: nil)
                        }
                        NotificationCenter.default.post(name: .hazeShowRecorder, object: nil)
                    }
                } else {
                    try await capture.start(settings: settings)
                    if PreferencesStore.shared.preferences.hideBarWhileRecording {
                        NotificationCenter.default.post(name: .hazeHideRecorder, object: nil)
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
        let timelineStart = session.timelineContentStart
        let timelineEnd = max(timelineStart + 0.6, session.timelineContentEnd)
        let zoomDuration = min(
            HazeDefaults.NewEditorZoom.maximumDuration,
            max(HazeDefaults.NewEditorZoom.minimumDuration, timelineEnd - timelineStart)
        )
        let cursor = nearestCursor(in: session, at: playbackTime)
            ?? CursorSample(time: playbackTime, x: Double(session.width) / 2, y: Double(session.height) / 2)
        let zoom = ZoomKeyframe(
            start: min(max(timelineStart, playbackTime - HazeDefaults.NewEditorZoom.preroll), max(timelineStart, timelineEnd - zoomDuration)),
            duration: zoomDuration,
            scale: max(1.05, settings.automaticZoomScale),
            centerX: cursor.x,
            centerY: cursor.y,
            easing: .smooth
        )
        updated.zooms.append(zoom)
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        selectOnlyZoom(zoom.id)
    }

    func deleteZoom(_ zoom: ZoomKeyframe) {
        guard let session = currentSession else { return }
        pushUndo(session)
        var updated = session
        updated.zooms.removeAll { $0.id == zoom.id }
        applySession(updated)
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
        selectedZoomID = normalized.id
        selectedZoomIDs.insert(normalized.id)
    }

    func updateZooms(_ zooms: [ZoomKeyframe], recordUndo: Bool = false) {
        guard let session = currentSession, !zooms.isEmpty else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        var updated = session
        let duration = max(1, updated.approximateDuration)
        for incoming in zooms {
            guard let index = updated.zooms.firstIndex(where: { $0.id == incoming.id }) else { continue }
            updated.zooms[index] = normalizedZoom(incoming, timelineDuration: duration, width: updated.width, height: updated.height)
        }
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
        if let selectedZoomID, zooms.contains(where: { $0.id == selectedZoomID }) {
            self.selectedZoomID = selectedZoomID
        } else if let id = zooms.last?.id {
            selectedZoomID = id
        }
        selectedZoomIDs.formUnion(zooms.map(\.id))
    }

    private func normalizedZoom(_ input: ZoomKeyframe, timelineDuration duration: Double, width: Int, height: Int) -> ZoomKeyframe {
        var zoom = input
        zoom.duration = min(max(0.6, zoom.duration), max(0.6, duration))
        zoom.start = min(max(0, zoom.start), max(0, duration - zoom.duration))
        zoom.scale = min(max(1, zoom.scale), 3)
        zoom.centerX = min(max(0, zoom.centerX), Double(width))
        zoom.centerY = min(max(0, zoom.centerY), Double(height))
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
        return zoom
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
            return
        }
        // No zoom under playhead: trim the clip after the playhead (rough cut).
        guard t > t0 + 0.12, t < t1 - 0.05 else { return }
        pushUndo(session)
        var updated = session
        updated.timelineTrimEnd = max(0, updated.approximateDuration - t)
        updated.normalizeTimelineTrims()
        applySession(updated)
        playbackTime = min(max(t, updated.timelineContentStart), updated.timelineContentEnd - 0.001)
    }

    func splitClipAtPlayhead() {
        guard let session = currentSession else { return }
        let t = playbackTime
        let t0 = session.timelineContentStart
        let t1 = session.timelineContentEnd
        guard t > t0 + 0.12, t < t1 - 0.05 else { return }

        pushUndo(session)
        var updated = session
        updated.timelineTrimEnd = max(0, updated.approximateDuration - t)
        updated.normalizeTimelineTrims()
        applySession(updated)
        playbackTime = min(max(t, updated.timelineContentStart), updated.timelineContentEnd - 0.001)
    }

    func updateTimelineTrims(trimStart: Double? = nil, trimEnd: Double? = nil, recordUndo: Bool = true) {
        guard var session = currentSession else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        let oldStart = session.timelineContentStart
        let oldEnd = session.timelineContentEnd
        if let trimStart { session.timelineTrimStart = trimStart }
        if let trimEnd { session.timelineTrimEnd = trimEnd }
        session.normalizeTimelineTrims()
        pushEdgeAttachedZooms(
            in: &session,
            oldStart: oldStart,
            oldEnd: oldEnd,
            startChanged: trimStart != nil,
            endChanged: trimEnd != nil
        )
        applySession(session)
        playbackTime = min(max(playbackTime, session.timelineContentStart), session.timelineContentEnd - 0.001)
    }

    private func pushEdgeAttachedZooms(
        in session: inout RecordingSession,
        oldStart: Double,
        oldEnd: Double,
        startChanged: Bool,
        endChanged: Bool
    ) {
        let newStart = session.timelineContentStart
        let newEnd = session.timelineContentEnd
        let sourceDuration = max(0.2, session.approximateDuration)
        let edgeSlack = 0.08

        for index in session.zooms.indices {
            var zoom = session.zooms[index]
            let zoomEnd = zoom.start + zoom.duration
            let wasStartAttached = zoom.start <= oldStart + edgeSlack && zoomEnd > oldStart + edgeSlack
            let wasEndAttached = zoom.start < oldEnd - edgeSlack && zoomEnd >= oldEnd - edgeSlack

            if startChanged, wasStartAttached {
                zoom.start = newStart
            }

            if endChanged, wasEndAttached {
                zoom.start = newEnd - zoom.duration
            }

            zoom.start = min(max(0, zoom.start), max(0, sourceDuration - zoom.duration))
            session.zooms[index] = zoom
        }

        session.zooms.sort { $0.start < $1.start }
    }

    func regenerateAutomaticZooms() {
        guard let session = currentSession else { return }
        let generated = automaticZoomsForVisibleRange(in: session)
        guard !generated.isEmpty else { return }
        pushUndo(session)
        var updated = session
        updated.zooms = generated
        applySession(updated)
        selectOnlyZoom(updated.zooms.first?.id)
    }

    func canRegenerateAutomaticZooms(in session: RecordingSession? = nil) -> Bool {
        guard let session = session ?? currentSession else { return false }
        return !automaticZoomsForVisibleRange(in: session).isEmpty
    }

    private func automaticZoomsForVisibleRange(in session: RecordingSession) -> [ZoomKeyframe] {
        let start = session.timelineContentStart
        let end = session.timelineContentEnd
        let visibleDuration = max(0, end - start)
        guard visibleDuration > 1.5 else { return [] }

        let samples = session.cursorSamples
            .filter { $0.time >= start && $0.time <= end }
            .map { CursorSample(time: $0.time - start, x: $0.x, y: $0.y) }
        let clicks = session.clicks
            .filter { $0.time >= start && $0.time <= end }
            .map { MouseClickEvent(time: $0.time - start, x: $0.x, y: $0.y, isRightClick: $0.isRightClick) }
        let keystrokes = session.keystrokes
            .filter { $0.time >= start && $0.time <= end }
            .map { KeystrokeEvent(time: $0.time - start, isModifier: $0.isModifier) }

        let generated = CaptureEngine.defaultZooms(
            samples: samples,
            clicks: clicks,
            keystrokes: keystrokes,
            settings: session.settings,
            width: Double(session.width),
            height: Double(session.height),
            duration: visibleDuration
        )

        return generated.map { zoom in
            var shifted = zoom
            shifted.start = min(max(start, shifted.start + start), max(start, end - shifted.duration))
            return shifted
        }
    }

    func clearAllZooms() {
        guard let session = currentSession else { return }
        pushUndo(session)
        var updated = session
        updated.zooms = []
        applySession(updated)
        selectOnlyZoom(nil)
    }

    func duplicateSelectedZoom() {
        guard let session = currentSession else { return }
        let selected = selectedZooms(in: session)
        guard !selected.isEmpty else { return }
        pushUndo(session)
        var updated = session
        let timelineStart = session.timelineContentStart
        let timelineEnd = max(timelineStart + 0.6, session.timelineContentEnd)
        let visibleDuration = max(0.6, timelineEnd - timelineStart)
        let gap = 0.05
        var newIDs: [UUID] = []
        for zoom in selected.sorted(by: { $0.start < $1.start }) {
            var duplicate = zoom
            duplicate.id = UUID()
            duplicate.duration = min(max(0.6, duplicate.duration), visibleDuration)
            let proposedStart = zoom.start + zoom.duration + gap
            duplicate.start = min(max(timelineStart, proposedStart), max(timelineStart, timelineEnd - duplicate.duration))
            newIDs.append(duplicate.id)
            updated.zooms.append(duplicate)
        }
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
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

    func selectAllZooms() {
        guard let session = currentSession else { return }
        selectedZoomIDs = Set(session.zooms.map(\.id))
        selectedZoomID = session.zooms.last?.id
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
        let timelineStart = session.timelineContentStart
        let timelineEnd = max(timelineStart + 0.6, session.timelineContentEnd)
        let visibleDuration = max(0.6, timelineEnd - timelineStart)
        let firstStart = pasted.map(\.start).min() ?? 0
        var newIDs: [UUID] = []
        for original in pasted.sorted(by: { $0.start < $1.start }) {
            var zoom = original
            zoom.id = UUID()
            zoom.duration = min(max(0.6, zoom.duration), visibleDuration)
            let offset = original.start - firstStart
            zoom.start = min(max(timelineStart, playbackTime + offset), max(timelineStart, timelineEnd - zoom.duration))
            newIDs.append(zoom.id)
            updated.zooms.append(zoom)
        }
        updated.zooms.sort { $0.start < $1.start }
        applySession(updated)
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
    }

    func updateSessionSettings(_ settings: RecordingSettings, recordUndo: Bool = false) {
        guard let session = currentSession else { return }
        if recordUndo, !undoTransactionIsOpen { pushUndo(session) }
        var updated = session
        updated.settings = settings
        self.settings = settings
        applySession(updated, persist: true)
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
            .appendingPathComponent("Haze", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { library = []; return }
        let items: [LibraryItem] = contents
            .filter { $0.pathExtension == "json" || $0.lastPathComponent.hasSuffix(".haze.json") }
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
            NotificationCenter.default.post(name: .hazeShowEditor, object: nil)
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
