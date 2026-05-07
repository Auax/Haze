import SwiftUI

extension Color {
    static let frBackground    = Color(hex: "#0D0F12")
    static let frPanel         = Color(hex: "#16191F")
    static let frBorder        = Color(hex: "#2A2F36")
    static let frPrimaryText   = Color(hex: "#E6E8EB")
    static let frSecondaryText = Color(hex: "#A1A7B3")
    static let frAccent        = Color(hex: "#2684FF")
    static let frMutedAccent   = Color(hex: "#5B77A6")

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >>  8) & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}
