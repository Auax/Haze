import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var showQuality = false
    @State private var showAutomation = false
    @State private var showVideoSettings = false
    @State private var showLibrary = false

    private let barIconSize: CGFloat = 20
    private let barLabelSize: CGFloat = 11
    private let recordIconSize: CGFloat = 26

    var body: some View {
        recorderBar
            .padding(28)
            .background(Color.clear)
            .floatingRecorderWindow()
        .task {
            model.refresh()
            model.capture.refreshMicrophones()
            updateMicrophoneMonitoring()
        }
        .onChange(of: model.settings.recordMicrophone) { _, _ in updateMicrophoneMonitoring() }
        .onChange(of: model.settings.microphoneDeviceID) { _, _ in updateMicrophoneMonitoring() }
        .onChange(of: model.capture.isRecording) { _, _ in updateMicrophoneMonitoring() }
        .onReceive(NotificationCenter.default.publisher(for: .focusRecorderHideRecorder)) { _ in
            RecorderWindowController.hide()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusRecorderShowRecorder)) { _ in
            RecorderWindowController.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusRecorderShowEditor)) { _ in
            if model.currentSession != nil {
                EditorWindowController.shared.show(model: model)
            }
        }
        .alert("Focus Recorder", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var recordingScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                preview
                DisclosureGroup("Smart auto-zoom", isExpanded: $showAutomation) {
                    automationControls
                        .padding(.top, 6)
                }
                .font(.headline)
                Spacer(minLength: 6)
                recordButton
            }
            .padding(20)
        }
    }

    private var recorderBar: some View {
        HStack(spacing: 0) {
            Button {
                RecorderWindowController.hide()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: barIconSize, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 44)
            }
            .buttonStyle(.plain)
            .help("Hide Focus Recorder")

            barSeparator
                .padding(.leading, 14)

            HStack(spacing: 14) {
                displayMenu
                windowMenu
                areaButton
            }
            .padding(.horizontal, 20)

            barSeparator

            HStack(spacing: 12) {
                microphoneMenu
                if model.settings.recordMicrophone {
                    AudioLevelBar(level: model.capture.microphoneLevel)
                        .frame(width: 56, height: 6)
                        .transition(.opacity)
                }
                systemAudioToggle
            }
            .padding(.horizontal, 20)

            barSeparator
                .padding(.trailing, 16)

            HStack(spacing: 4) {
                libraryButton
                videoSettingsMenu
                preferencesButton
            }

            Button {
                if model.capture.hasScreenRecordingPermission || model.capture.isRecording {
                    model.toggleRecording()
                } else {
                    model.capture.requestScreenRecordingPermission()
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Group {
                        if model.capture.isRecording {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.red)
                                .frame(width: 14, height: 14)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 22, height: 22)
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.capture.isRecording)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.capture.isRecording ? "Stop recording" : "Start recording")
            .padding(.leading, 14)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
    }

    private var barSeparator: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 42)
    }

    private var displayMenu: some View {
        Menu {
            ForEach(model.capture.displays) { source in
                Button(source.title) {
                    model.settings.captureKind = .display
                    model.capture.selectedSourceID = source.id
                }
            }
            Divider()
            Button("Refresh Displays") { model.refresh() }
        } label: {
            sourceModeLabel(.display, title: "Display", symbol: "display")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selectedSourceHelp(fallback: "Select display"))
    }

    private var windowMenu: some View {
        Menu {
            if model.capture.windows.isEmpty {
                Text("No windows")
            } else {
                ForEach(model.capture.windows) { source in
                    Button(windowMenuLabel(for: source)) {
                        model.settings.captureKind = .window
                        model.capture.selectedSourceID = source.id
                    }
                }
            }
            Divider()
            Button("Refresh Windows") { model.refresh() }
        } label: {
            sourceModeLabel(.window, title: "Window", symbol: "macwindow")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selectedSourceHelp(fallback: "Select window"))
    }

    private var areaButton: some View {
        Button {
            selectCaptureKind(.region)
        } label: {
            sourceModeLabel(.region, title: "Area", symbol: "crop")
        }
        .buttonStyle(.plain)
        .help("Select recording area")
    }

    private func sourceModeLabel(_ kind: CaptureKind, title: String, symbol: String) -> some View {
        let isSelected = model.settings.captureKind == kind
        return VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: barIconSize, weight: .regular))
                .frame(width: 24, height: 24)
            Text(title)
                .font(.system(size: barLabelSize, weight: .medium))
        }
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .frame(width: 64, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.accentColor.opacity(isSelected ? 0.35 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private var microphoneMenu: some View {
        Menu {
            Button("No Microphone") {
                model.settings.recordMicrophone = false
                model.settings.microphoneDeviceID = nil
            }
            Divider()
            ForEach(model.capture.microphones) { microphone in
                Button(microphone.name) {
                    model.settings.recordMicrophone = true
                    model.settings.microphoneDeviceID = microphone.id
                }
            }
            if model.capture.microphones.isEmpty {
                Text("No microphones")
            }
            Divider()
            Button("Refresh Microphones") {
                model.capture.refreshMicrophones()
            }
            Button("Microphone Settings") {
                model.capture.openMicrophoneSettings()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.settings.recordMicrophone ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: barIconSize, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(model.settings.recordMicrophone ? .primary : .secondary)
            .frame(width: 44, height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(microphoneHelp)
    }

    private var systemAudioToggle: some View {
        Button {
            model.settings.recordSystemAudio.toggle()
        } label: {
            Image(systemName: model.settings.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: barIconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
                .foregroundStyle(model.settings.recordSystemAudio ? .primary : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(model.settings.recordSystemAudio ? "System audio on" : "System audio off")
    }

    private var libraryButton: some View {
        Button {
            model.loadLibrary()
            showLibrary.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: barIconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
                .frame(width: 40, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Recent recordings")
        .popover(isPresented: $showLibrary, arrowEdge: .bottom) {
            LibraryPopover(showLibrary: $showLibrary)
                .environmentObject(model)
                .environment(\.controlActiveState, .active)
        }
    }

    private var preferencesButton: some View {
        Button {
            PreferencesWindowController.shared.show()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: barIconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
                .frame(width: 40, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Preferences (⌘,)")
    }

    private var videoSettingsMenu: some View {
        Button {
            showVideoSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: barIconSize, weight: .regular))
                .frame(width: 24, height: 24)
                .frame(width: 40, height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Video settings")
        .popover(isPresented: $showVideoSettings, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Resolution", selection: $model.settings.resolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text("\(Int(model.settings.bitrateMbps)) Mbps")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { model.settings.bitrateMbps },
                        set: { model.settings.bitrateMbps = $0.rounded() }
                    ), in: 4...80)
                }
            }
            .padding(16)
            .frame(width: 260)
            .environment(\.controlActiveState, .active)
        }
    }

    private func selectCaptureKind(_ kind: CaptureKind) {
        model.settings.captureKind = kind
        switch kind {
        case .display:
            model.capture.selectedSourceID = model.capture.displays.first?.id
        case .window:
            model.capture.selectedSourceID = model.capture.windows.first?.id
        case .region:
            model.capture.selectedSourceID = model.capture.displays.first?.id
            RegionPicker.shared.pick { rect in
                model.settings.region = rect
            }
        }
    }

    private func windowMenuLabel(for source: CaptureSource) -> String {
        if source.title == source.subtitle || source.subtitle.isEmpty {
            return source.title
        }
        return "\(source.title) — \(source.subtitle)"
    }

    private var microphoneHelp: String {
        guard model.settings.recordMicrophone else { return "No microphone" }
        guard let id = model.settings.microphoneDeviceID,
              let microphone = model.capture.microphones.first(where: { $0.id == id })
        else { return "Default microphone" }
        return microphone.name
    }

    private func selectedSourceHelp(fallback: String) -> String {
        guard let id = model.capture.selectedSourceID,
              let source = (model.capture.displays + model.capture.windows).first(where: { $0.id == id })
        else { return fallback }
        return source.title
    }

    private func updateMicrophoneMonitoring() {
        model.capture.setMicrophoneMonitoring(
            enabled: model.settings.recordMicrophone && !model.capture.isRecording,
            deviceID: model.settings.microphoneDeviceID
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Focus Recorder")
                    .font(.title2.weight(.semibold))
                Text(model.capture.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh capture sources")
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.settings.captureKind == .window ? "Windows" : "Displays")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            let sources = model.settings.captureKind == .window ? model.capture.windows : model.capture.displays
            List(sources, selection: Binding(
                get: { model.capture.selectedSourceID },
                set: { model.capture.selectedSourceID = $0 }
            )) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).lineLimit(1)
                    Text(source.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Resolution", selection: $model.settings.resolutionPreset) {
                ForEach(ResolutionPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            HStack {
                Text("Bitrate").frame(width: 90, alignment: .leading)
                Slider(value: $model.settings.bitrateMbps, in: 4...80, step: 1)
                Text("\(Int(model.settings.bitrateMbps)) Mbps")
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }
            Stepper("Frame rate: \(model.settings.frameRate) fps", value: $model.settings.frameRate, in: 24...120, step: 6)
        }
    }

    private var automationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Generate zooms automatically", isOn: $model.settings.automaticZooms)
            HStack {
                Text("Zoom level").frame(width: 90, alignment: .leading)
                Slider(value: $model.settings.automaticZoomScale, in: 1.1...2.4, step: 0.05)
                Text("\(model.settings.automaticZoomScale, specifier: "%.2f")x")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Toggle("Detect mouse clicks (no permission needed)", isOn: $model.settings.detectClicks)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Detect typing (Input Monitoring permission)", isOn: $model.settings.detectKeystrokes)
                if model.settings.detectKeystrokes {
                    Button("Open Input Monitoring settings") {
                        model.capture.openInputMonitoringSettings()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Text("Cursor smoothing").frame(width: 110, alignment: .leading)
                Slider(value: $model.settings.cursorSmoothing, in: 0...2.0, step: 0.05)
                Text("\(model.settings.cursorSmoothing, specifier: "%.2f")")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Smoothing window").frame(width: 110, alignment: .leading)
                Slider(value: $model.settings.cursorSmoothingWindow, in: 0.05...0.9, step: 0.01)
                Text("\(model.settings.cursorSmoothingWindow, specifier: "%.2f")s")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Cursor size").frame(width: 110, alignment: .leading)
                Slider(value: $model.settings.cursorScale, in: 0.5...3.0, step: 0.05)
                Text("\(model.settings.cursorScale, specifier: "%.2f")x")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Cursor spring").frame(width: 110, alignment: .leading)
                Slider(value: $model.settings.cursorSpring, in: 0...1.0, step: 0.05)
                Text("\(model.settings.cursorSpring, specifier: "%.2f")")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            Picker("Cursor sprite", selection: $model.settings.cursorSprite) {
                ForEach(CursorSprite.allCases) { sprite in
                    Label(sprite.label, systemImage: sprite.symbolName).tag(sprite)
                }
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black)
            if let image = model.capture.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: model.capture.isRecording ? "record.circle" : "display")
                        .font(.system(size: 28, weight: .medium))
                    Text(model.capture.isRecording ? "Recording…" : "Preview")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            if model.capture.isRecording {
                VStack {
                    HStack {
                        Label(timecode(model.capture.elapsedRecordingTime), systemImage: "record.circle.fill")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.88), in: Capsule())
                        Spacer()
                        if model.capture.manualZoomCount > 0 {
                            Label("\(model.capture.manualZoomCount) zoom\(model.capture.manualZoomCount == 1 ? "" : "s")", systemImage: "plus.magnifyingglass")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.88), in: Capsule())
                        }
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.loadLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            VStack(spacing: 4) {
                ForEach(model.library.prefix(4)) { item in
                    Button {
                        model.openLibraryItem(item)
                    } label: {
                        HStack {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .lineLimit(1)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recordButton: some View {
        VStack(spacing: 8) {
            Button {
                model.toggleRecording()
            } label: {
                Label(
                    model.capture.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: model.capture.isRecording ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.capture.isRecording ? .red : .accentColor)
            .disabled(!model.capture.hasScreenRecordingPermission && !model.capture.isRecording)
            .keyboardShortcut(.return, modifiers: [.command])

            if model.capture.isRecording {
                VStack(spacing: 4) {
                    Button {
                        model.markZoomDuringRecording()
                    } label: {
                        Label("Mark Zoom", systemImage: "plus.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    Text("Hotkey: ⌃⌥Z (global) or ⌘⇧Z (this window)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if model.currentSession != nil {
                Button {
                    EditorWindowController.shared.show(model: model)
                } label: {
                    Label("Open Editor", systemImage: "slider.horizontal.below.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .keyboardShortcut("e", modifiers: [.command])
            }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let m = total / 60
        let s = total % 60
        let ms = Int((seconds - floor(seconds)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }
}

private struct PermissionPanel: View {
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording needed", systemImage: "lock.shield")
                .font(.headline)
            Text("Grant access once, then quit and reopen the app before recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Request") { request() }
                Button("Settings") { openSettings() }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RegionControls: View {
    @Binding var region: CGRect
    let pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Region")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { pick() } label: {
                    Label("Pick", systemImage: "selection.pin.in.out")
                }
                .controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("X", value: Binding(get: { region.origin.x }, set: { region.origin.x = $0 }))
                    NumberField("Y", value: Binding(get: { region.origin.y }, set: { region.origin.y = $0 }))
                }
                GridRow {
                    NumberField("W", value: Binding(get: { region.size.width }, set: { region.size.width = max(2, $0) }))
                    NumberField("H", value: Binding(get: { region.size.height }, set: { region.size.height = max(2, $0) }))
                }
            }
        }
    }
}

private struct LibraryPopover: View {
    @EnvironmentObject private var model: AppViewModel
    @Binding var showLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Recordings")
                    .font(.headline)
                Spacer()
                Button {
                    model.loadLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if model.library.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No recordings yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.library.prefix(20)) { item in
                            LibraryRow(item: item) {
                                model.openLibraryItem(item)
                                showLibrary = false
                            } reveal: {
                                NSWorkspace.shared.activateFileViewerSelecting([item.timelineURL])
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            HStack {
                Button {
                    let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("FocusRecorder", isDirectory: true)
                    NSWorkspace.shared.open(dir)
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }
}

private struct LibraryRow: View {
    let item: AppViewModel.LibraryItem
    let action: () -> Void
    let reveal: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                reveal()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
    }
}

private struct NumberField: View {
    let title: String
    @Binding var value: CGFloat

    init(_ title: String, value: Binding<CGFloat>) {
        self.title = title
        self._value = value
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            TextField(title, value: Binding<Double>(
                get: { Double(value) },
                set: { value = CGFloat($0) }
            ), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 88)
        }
    }
}

private struct AudioLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(.primary.opacity(0.70))
                    .frame(width: proxy.size.width * CGFloat(max(0, min(1, level))))
            }
        }
        .accessibilityLabel("Microphone level")
    }
}

private extension View {
    func floatingRecorderWindow() -> some View {
        background(FloatingRecorderWindowConfigurator())
    }
}

private struct FloatingRecorderWindowConfigurator: NSViewRepresentable {
    private static var configuredWindows = Set<ObjectIdentifier>()

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        guard window.identifier?.rawValue == "recorder" || window.title == "Focus Recorder" else { return }
        let windowID = ObjectIdentifier(window)
        let shouldPlaceWindow = !Self.configuredWindows.contains(windowID)

        window.styleMask = [.borderless, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentMinSize = CGSize(width: 860, height: 120)
        window.contentMaxSize = CGSize(width: 860, height: 120)
        window.setContentSize(CGSize(width: 860, height: 120))
        if shouldPlaceWindow {
            centerNearTop(window)
            Self.configuredWindows.insert(windowID)
        }
    }

    private func centerNearTop(_ window: NSWindow) {
        guard !window.frame.size.equalTo(.zero),
              let screen = window.screen ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.maxY - frame.height - 88
        window.setFrame(frame, display: true)
    }
}
