import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var store = PreferencesStore.shared

    var body: some View {
        TabView {
            recordingTab
                .tabItem { Label("Recording", systemImage: "video") }
            editorTab
                .tabItem { Label("Editor", systemImage: "slider.horizontal.below.rectangle") }
            hotkeysTab
                .tabItem { Label("Hotkeys", systemImage: "command") }
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 520)
        .padding(20)
    }

    private var recordingTab: some View {
        Form {
            Section("Defaults for new recordings") {
                Picker("Resolution", selection: $store.preferences.defaultResolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper(
                    "Frame rate: \(store.preferences.defaultFrameRate) fps",
                    value: $store.preferences.defaultFrameRate,
                    in: 24...120,
                    step: 6
                )
                HStack {
                    Text("Bitrate")
                    Slider(
                        value: Binding(
                            get: { store.preferences.defaultBitrateMbps },
                            set: { store.preferences.defaultBitrateMbps = $0.rounded() }
                        ),
                        in: 4...80
                    )
                    Text("\(Int(store.preferences.defaultBitrateMbps)) Mbps")
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Audio") {
                Toggle("Record microphone by default", isOn: $store.preferences.defaultRecordMicrophone)
                Toggle("Record system audio by default", isOn: $store.preferences.defaultRecordSystemAudio)
            }
        }
        .formStyle(.grouped)
    }

    private var editorTab: some View {
        Form {
            Section("Smart auto-zoom") {
                Toggle("Generate zooms automatically", isOn: $store.preferences.defaultAutomaticZooms)
                HStack {
                    Text("Zoom level")
                    Slider(value: $store.preferences.defaultAutomaticZoomScale, in: 1.1...2.4, step: 0.05)
                    Text(String(format: "%.2fx", store.preferences.defaultAutomaticZoomScale))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Cursor") {
                HStack {
                    Text("Smoothing")
                    Slider(value: $store.preferences.defaultCursorSmoothing, in: 0...2.0, step: 0.05)
                    Text(String(format: "%.2f", store.preferences.defaultCursorSmoothing))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Cursor size")
                    Slider(value: $store.preferences.defaultCursorScale, in: 0.5...5.0, step: 0.05)
                    Text(String(format: "%.2fx", store.preferences.defaultCursorScale))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Spring")
                    Slider(value: $store.preferences.defaultCursorSpring, in: 0...2.0, step: 0.05)
                    Text(String(format: "%.2f", store.preferences.defaultCursorSpring))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                Toggle("Click pulse animation", isOn: $store.preferences.defaultCursorClickPulse)
            }
            Section("Input detection") {
                Toggle("Detect mouse clicks", isOn: $store.preferences.defaultDetectClicks)
                Toggle("Detect typing (Input Monitoring permission)", isOn: $store.preferences.defaultDetectKeystrokes)
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeysTab: some View {
        Form {
            Section("Global hotkeys (work while recording)") {
                hotkeyRow(
                    label: "Mark zoom",
                    binding: $store.preferences.markZoomHotkey,
                    fallback: .markZoomDefault
                )
                hotkeyRow(
                    label: "Start / stop recording",
                    binding: $store.preferences.toggleRecordHotkey,
                    fallback: .toggleRecordDefault
                )
            }
            Section("Editor (when the editor window is focused)") {
                hotkeyRow(
                    label: "Duplicate selected zoom",
                    binding: $store.preferences.duplicateZoomEditorHotkey,
                    fallback: .duplicateZoomEditorDefault
                )
            }
            Section("Editor shortcuts (not reassignable here)") {
                editorShortcutRow("Play / pause", "Space")
                editorShortcutRow("Previous / next frame", "←  →")
                editorShortcutRow("Seek −1s / +1s", "⇧←  ⇧→")
                editorShortcutRow("Go to clip start / end", "Home  End")
                editorShortcutRow("Add zoom at playhead", "Z")
                editorShortcutRow("Split zoom or trim clip after playhead", "S")
                editorShortcutRow("Center selected zoom on cursor", "C")
                editorShortcutRow("Delete selected zooms", "Delete")
                editorShortcutRow("Undo / redo", "⌘Z  ⇧⌘Z")
            }
            Section {
                Text("Click a field, then press the desired key combination. Use ⌃, ⌥, ⇧ or ⌘ as modifiers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func editorShortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func hotkeyRow(label: String, binding: Binding<HotkeyBinding>, fallback: HotkeyBinding) -> some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyRecorderField(binding: binding)
                .frame(width: 160, height: 26)
            Button("Reset") { binding.wrappedValue = fallback }
                .controlSize(.small)
        }
    }

    private var generalTab: some View {
        Form {
            Section("Floating bar") {
                Toggle("Hide while recording", isOn: $store.preferences.hideBarWhileRecording)
            }
            Section("After recording") {
                Toggle("Open editor automatically when recording stops", isOn: $store.preferences.openEditorWhenRecordingStops)
            }
            Section {
                Button("Reset all preferences") {
                    store.preferences = AppPreferences()
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var binding: HotkeyBinding

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.binding = binding
        view.onChange = { newValue in
            DispatchQueue.main.async { self.binding = newValue }
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.binding = binding
        nsView.needsDisplay = true
    }
}

final class HotkeyRecorderNSView: NSView {
    var binding: HotkeyBinding = .markZoomDefault {
        didSet { needsDisplay = true }
    }
    var onChange: ((HotkeyBinding) -> Void)?
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                     .intersection([.control, .option, .shift, .command])
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        guard !mods.isEmpty else { return }
        let newBinding = HotkeyBinding(keyCode: event.keyCode, modifiers: mods)
        binding = newBinding
        onChange?(newBinding)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isLight = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let bg = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.textBackgroundColor.withAlphaComponent(isLight ? 1.0 : 0.5)
        let border = isRecording
            ? NSColor.controlAccentColor
            : NSColor.separatorColor
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = border.cgColor

        let display = isRecording
            ? "Press keys…"
            : (binding.isEmpty ? "—" : binding.displayString)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = display.size(withAttributes: attrs)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        display.draw(at: origin, withAttributes: attrs)
    }
}
