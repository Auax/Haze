import AppKit
import Combine
import Foundation

struct HotkeyBinding: Codable, Hashable {
    var keyCode: UInt16
    var modifierFlagsRaw: UInt

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: modifierFlagsRaw) }
        set { modifierFlagsRaw = newValue.rawValue }
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifiers.rawValue
    }

    var isEmpty: Bool { modifiers.intersection([.control, .option, .shift, .command]).isEmpty }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(keyCode: keyCode))
        return parts.joined()
    }

    static func keyName(keyCode: UInt16) -> String {
        let table: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            36: "↩", 49: "Space", 51: "⌫", 53: "Esc", 48: "⇥",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`"
        ]
        return table[keyCode] ?? "Key \(keyCode)"
    }

    static let markZoomDefault = HotkeyBinding(keyCode: 6, modifiers: [.control, .option])
    static let toggleRecordDefault = HotkeyBinding(keyCode: 15, modifiers: [.control, .option])
    /// Default ⌃D — keyCode 2 is ANSI D on US keyboards.
    static let duplicateZoomEditorDefault = HotkeyBinding(keyCode: 2, modifiers: [.control])

    /// True when this binding matches a key-down event (device-independent modifier flags).
    func matchesKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let mask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let got = event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection(mask)
        let want = modifiers.intersection(mask)
        return got == want
    }
}

struct AppPreferences: Codable {
    var defaultResolutionPreset: ResolutionPreset = .native
    var defaultFrameRate: Int = 60
    var defaultBitrateMbps: Double = 60
    var defaultRecordSystemAudio: Bool = false
    var defaultRecordMicrophone: Bool = false

    var defaultAutomaticZooms: Bool = true
    var defaultAutomaticZoomScale: Double = 1.4
    var defaultCursorScale: Double = 2.5
    var defaultCursorSmoothing: Double = 1.3
    var defaultCursorSpring: Double = 2.0
    var defaultDetectClicks: Bool = true
    var defaultDetectKeystrokes: Bool = true
    var defaultCursorClickPulse: Bool = true

    var markZoomHotkey: HotkeyBinding = .markZoomDefault
    var toggleRecordHotkey: HotkeyBinding = .toggleRecordDefault
    var duplicateZoomEditorHotkey: HotkeyBinding = .duplicateZoomEditorDefault

    var hideBarWhileRecording: Bool = false
    var openEditorWhenRecordingStops: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case defaultResolutionPreset, defaultFrameRate, defaultBitrateMbps
        case defaultRecordSystemAudio, defaultRecordMicrophone
        case defaultAutomaticZooms, defaultAutomaticZoomScale
        case defaultCursorScale, defaultCursorSmoothing, defaultCursorSpring
        case defaultDetectClicks, defaultDetectKeystrokes, defaultCursorClickPulse
        case markZoomHotkey, toggleRecordHotkey, duplicateZoomEditorHotkey
        case hideBarWhileRecording, openEditorWhenRecordingStops
    }

    init(from decoder: Decoder) throws {
        let fb = AppPreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultResolutionPreset = try c.decodeIfPresent(ResolutionPreset.self, forKey: .defaultResolutionPreset) ?? fb.defaultResolutionPreset
        defaultFrameRate = try c.decodeIfPresent(Int.self, forKey: .defaultFrameRate) ?? fb.defaultFrameRate
        defaultBitrateMbps = try c.decodeIfPresent(Double.self, forKey: .defaultBitrateMbps) ?? fb.defaultBitrateMbps
        defaultRecordSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .defaultRecordSystemAudio) ?? fb.defaultRecordSystemAudio
        defaultRecordMicrophone = try c.decodeIfPresent(Bool.self, forKey: .defaultRecordMicrophone) ?? fb.defaultRecordMicrophone
        defaultAutomaticZooms = try c.decodeIfPresent(Bool.self, forKey: .defaultAutomaticZooms) ?? fb.defaultAutomaticZooms
        defaultAutomaticZoomScale = try c.decodeIfPresent(Double.self, forKey: .defaultAutomaticZoomScale) ?? fb.defaultAutomaticZoomScale
        defaultCursorScale = try c.decodeIfPresent(Double.self, forKey: .defaultCursorScale) ?? fb.defaultCursorScale
        defaultCursorSmoothing = try c.decodeIfPresent(Double.self, forKey: .defaultCursorSmoothing) ?? fb.defaultCursorSmoothing
        defaultCursorSpring = try c.decodeIfPresent(Double.self, forKey: .defaultCursorSpring) ?? fb.defaultCursorSpring
        defaultDetectClicks = try c.decodeIfPresent(Bool.self, forKey: .defaultDetectClicks) ?? fb.defaultDetectClicks
        defaultDetectKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .defaultDetectKeystrokes) ?? fb.defaultDetectKeystrokes
        defaultCursorClickPulse = try c.decodeIfPresent(Bool.self, forKey: .defaultCursorClickPulse) ?? fb.defaultCursorClickPulse
        markZoomHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .markZoomHotkey) ?? fb.markZoomHotkey
        toggleRecordHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .toggleRecordHotkey) ?? fb.toggleRecordHotkey
        duplicateZoomEditorHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .duplicateZoomEditorHotkey) ?? fb.duplicateZoomEditorHotkey
        hideBarWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .hideBarWhileRecording) ?? fb.hideBarWhileRecording
        openEditorWhenRecordingStops = try c.decodeIfPresent(Bool.self, forKey: .openEditorWhenRecordingStops) ?? fb.openEditorWhenRecordingStops
    }

    mutating func migrateFactoryDefaults() {
        if defaultResolutionPreset == .p1080 { defaultResolutionPreset = .native }
        if defaultBitrateMbps == 18 { defaultBitrateMbps = 60 }
        if defaultCursorScale == 1.0 { defaultCursorScale = 2.5 }
        if defaultCursorSmoothing == 0.78 { defaultCursorSmoothing = 1.3 }
    }
}

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published var preferences: AppPreferences {
        didSet { save() }
    }

    private let key = "Haze.AppPreferences.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            var migrated = decoded
            migrated.migrateFactoryDefaults()
            self.preferences = migrated
        } else {
            self.preferences = AppPreferences()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func applyDefaults(to settings: inout RecordingSettings) {
        let p = preferences
        settings.resolutionPreset = p.defaultResolutionPreset
        settings.frameRate = p.defaultFrameRate
        settings.bitrateMbps = p.defaultBitrateMbps
        settings.recordSystemAudio = p.defaultRecordSystemAudio
        settings.recordMicrophone = p.defaultRecordMicrophone
        settings.automaticZooms = p.defaultAutomaticZooms
        settings.automaticZoomScale = p.defaultAutomaticZoomScale
        settings.cursorScale = p.defaultCursorScale
        settings.cursorSmoothing = p.defaultCursorSmoothing
        settings.cursorSpring = p.defaultCursorSpring
        settings.detectClicks = p.defaultDetectClicks
        settings.detectKeystrokes = p.defaultDetectKeystrokes
        settings.cursorClickPulse = p.defaultCursorClickPulse
    }
}
