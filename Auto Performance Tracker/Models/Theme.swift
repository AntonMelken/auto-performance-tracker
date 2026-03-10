import SwiftUI

// MARK: - Theme
// Zentrale Farb-Definitionen für Dark / Light Mode.
// Verwendung in Views:
//   @Environment(\.colorScheme) private var cs
//   .background(Theme.card(cs))

enum Theme {

    /// Haupt-Seitenhintergrund
    static func bg(_ cs: ColorScheme) -> Color {
        cs == .dark ? Color(hex: "080C14") : Color(hex: "F2F4F8")
    }

    /// Karten / ListRow-Hintergründe
    static func card(_ cs: ColorScheme) -> Color {
        cs == .dark ? Color(hex: "0F1A2E") : Color(.secondarySystemBackground)
    }

    /// Tiefe Sheet-Hintergründe (Formulare, Picker)
    static func cardDeep(_ cs: ColorScheme) -> Color {
        cs == .dark ? Color(hex: "080C14") : Color(.systemBackground)
    }

    /// Segmented-Picker / alternativer Karten-Hintergrund
    static func pickerBg(_ cs: ColorScheme) -> Color {
        cs == .dark ? Color(hex: "0D1117") : Color(.tertiarySystemBackground)
    }

    /// Rahmenlinien
    static func border(_ cs: ColorScheme) -> Color {
        cs == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.09)
    }

    /// Primärtext (war .white)
    static func text(_ cs: ColorScheme) -> Color {
        cs == .dark ? .white : Color(.label)
    }

    /// Subtiler Trenn-Divider
    static func divider(_ cs: ColorScheme) -> Color {
        cs == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }

    /// Aufnahme-Hintergrundgradient
    static func recGradient(_ cs: ColorScheme) -> LinearGradient {
        cs == .dark
            ? LinearGradient(
                colors: [Color(hex: "080C14"), Color(hex: "0D1320")],
                startPoint: .top, endPoint: .bottom)
            : LinearGradient(
                colors: [Color(hex: "F2F4F8"), Color(hex: "E8ECF2")],
                startPoint: .top, endPoint: .bottom)
    }
}
