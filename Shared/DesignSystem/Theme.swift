import SwiftUI

/// Tokens lifted from the artboards: pure-black canvas, graphite surfaces, white hairlines.
/// Chips show the colour each event has in Google Calendar (GoogleColor); colours the app picks itself come from here.
enum Theme {
    static let canvas = Color.black
    static let surface = Color(white: 0.11)          // #1C1C1E — cards
    static let surfaceRaised = Color(white: 0.17)    // #2C2C2E — chat bubbles, input bar
    static let bubble = Color(white: 0.24)           // #3D3D3D — user message bubble (Artboard 5)
    static let hairline = Color.white.opacity(0.18)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let deadline = Color(hex: "#F6C89F")      // peach chip "Deadline for Plan 5008" (Artboard 4)
    static let demoBadge = Color(hex: "#FFD60A")

    /// Local colour choices for a calendar (Calendar details). iOS dark-mode system colours, in hue order.
    static let calendarColorChoices = [
        "#0A84FF", "#64D2FF", "#40C8E0", "#66D4CF", "#30D158", "#FFD60A",
        "#FF9F0A", "#FF453A", "#FF375F", "#BF5AF2", "#5E5CE6", "#AC8E68"
    ]

    static let islandRadius: CGFloat = 44             // Quick Capture card mirrors the island's curvature
    static let cardRadius: CGFloat = 22

    static let weekdayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    /// `weekdayLetters` rotated to start on `firstWeekday` (1 = Sunday, 2 = Monday), like `Calendar.firstWeekday`.
    static func weekdayLetters(firstWeekday: Int) -> [String] {
        let start = (1...7).contains(firstWeekday) ? firstWeekday - 1 : 0
        return Array(weekdayLetters[start...] + weekdayLetters[..<start])
    }
}

extension Color {
    /// `#RRGGBB` or `RRGGBB`. Falls back to gray on malformed input.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).prefix(6)
        let value = UInt32(cleaned, radix: 16) ?? 0x8E8E93
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
