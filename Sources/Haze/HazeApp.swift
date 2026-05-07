import AppKit
import Combine
import SwiftUI

@main
struct HazeApp: App {
    @NSApplicationDelegateAdaptor(HazeAppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel.shared

    var body: some Scene {
        Window("Haze Editor", id: "editor") {
            EditorView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 740)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1500, height: 920)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recorder") {
                Button("Show Recorder Controls") {
                    RecorderPanelController.shared.show(model: model)
                }
                Button(model.capture.isRecording ? "Stop Recording" : "Start Recording") {
                    model.toggleRecording()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                Button("Mark Zoom During Recording") {
                    model.markZoomDuringRecording()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.capture.isRecording)
                Divider()
                Button("Show Editor") {
                    EditorWindowController.shared.show(model: model)
                }
                .keyboardShortcut("e", modifiers: [.command])
                .disabled(model.currentSession == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    PreferencesWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { model.cutSelectedZooms() }
                    .keyboardShortcut("x", modifiers: [.command])
                    .disabled(!model.hasSelectedZooms)
                Button("Copy") { model.copySelectedZooms() }
                    .keyboardShortcut("c", modifiers: [.command])
                    .disabled(!model.hasSelectedZooms)
                Button("Paste") { model.pasteZoomsAtPlayhead() }
                    .keyboardShortcut("v", modifiers: [.command])
                    .disabled(model.currentSession == nil)
                Button("Delete") { model.deleteSelectedZooms() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!model.hasSelectedZooms)
            }
            CommandMenu("Timeline") {
                Button("Add Zoom") { model.addZoomAtPlayhead() }
                Button("Duplicate Zoom") { model.duplicateSelectedZoom() }
                    .keyboardShortcut("d", modifiers: .control)
                    .disabled(!model.hasSelectedZooms)
                Button("Center Zoom on Cursor") { model.centerSelectedZoomOnCursor() }
                    .disabled(model.selectedZoomID == nil || model.selectedZoomIDs.count > 1)
                Button("Split Zoom or Trim Clip") { model.splitZoomAtPlayhead() }
            }
        }
    }
}

final class HazeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        RecordingStatusItemController.shared.install(model: AppViewModel.shared)
        RecorderPanelController.shared.show(model: AppViewModel.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if EditorWindowController.shared.isPreferredForDockActivation {
                EditorWindowController.shared.bringToFront()
            } else {
                RecorderPanelController.shared.show(model: AppViewModel.shared)
            }
        }
        return true
    }
}

final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(size: CGSize) {
        let frame = RecorderPanel.initialFrame(size: size)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    private static func initialFrame(size: CGSize) -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 88,
            width: size.width,
            height: size.height
        )
    }
}

final class EditorAppWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()

    private var window: EditorAppWindow?

    /// True when the editor window exists and is open or minimized (dock click should return here instead of the recorder bar).
    var isPreferredForDockActivation: Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func show(model: AppViewModel) {
        let window = window ?? makeWindow(model: model)
        self.window = window
        RecorderPanelController.shared.hide()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func bringToFront() {
        guard let window else { return }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(model: AppViewModel) -> EditorAppWindow {
        let window = EditorAppWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1500, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("editor")
        window.title = "Haze Editor"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 1180, height: 740)
        window.contentViewController = NSHostingController(
            rootView: EditorView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 740)
        )
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? EditorAppWindow === window else { return }
        RecorderPanelController.shared.show(model: AppViewModel.shared)
    }
}

@MainActor
final class RecordingStatusItemController: NSObject {
    static let shared = RecordingStatusItemController()

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private weak var model: AppViewModel?

    func install(model: AppViewModel) {
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        configureButton(item.button)
        updateVisibility(isRecording: model.capture.isRecording)

        model.capture.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                self?.updateVisibility(isRecording: isRecording)
            }
            .store(in: &cancellables)
    }

    @objc private func stopRecordingFromStatusItem() {
        guard model?.capture.isRecording == true else { return }
        model?.toggleRecording()
    }

    private func configureButton(_ button: NSStatusBarButton?) {
        guard let button else { return }
        let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Stop recording and open editor"
        button.target = self
        button.action = #selector(stopRecordingFromStatusItem)
    }

    private func updateVisibility(isRecording: Bool) {
        statusItem?.isVisible = isRecording
    }
}

@MainActor
final class RecorderPanelController {
    static let shared = RecorderPanelController()

    private var panel: RecorderPanel?
    private let panelSize = CGSize(width: 860, height: 120)

    func show(model: AppViewModel) {
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        positionNearTop(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppViewModel) -> RecorderPanel {
        let panel = RecorderPanel(size: panelSize)
        panel.identifier = NSUserInterfaceItemIdentifier("recorder")
        panel.title = "Haze"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = panelSize
        panel.contentMaxSize = panelSize
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(model)
                .frame(width: panelSize.width, height: panelSize.height)
        )
        panel.layoutIfNeeded()
        positionNearTop(panel)
        return panel
    }

    private func positionNearTop(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = CGRect(origin: panel.frame.origin, size: panelSize)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.maxY - frame.height - 88
        panel.setFrame(frame, display: true)
    }
}

extension Notification.Name {
    static let hazeShowEditor = Notification.Name("Haze.showEditor")
    static let hazeHideRecorder = Notification.Name("Haze.hideRecorder")
    static let hazeShowRecorder = Notification.Name("Haze.showRecorder")
}

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PreferencesView())
        return window
    }
}

@MainActor
enum RecorderWindowController {
    static func hide() {
        RecorderPanelController.shared.hide()
    }

    static func show() {
        RecorderPanelController.shared.show(model: AppViewModel.shared)
    }
}
