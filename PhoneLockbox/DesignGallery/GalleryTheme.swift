import SwiftUI

struct GalleryPalette {
    let background: Color
    let surface: Color
    let surfaceRaised: Color
    let surfaceMuted: Color
    let primary: Color
    let secondary: Color
    let accent: Color
    let rest: Color
    let focus: Color
    let border: Color
    let onAccent: Color
    let isDark: Bool

    static func make(theme: GalleryModel.Theme, scheme: ColorScheme) -> GalleryPalette {
        switch theme {
        case .midnight:
            if scheme == .dark {
                return GalleryPalette(
                    background: Color(red: 0.035, green: 0.047, blue: 0.11),
                    surface: Color(red: 0.075, green: 0.095, blue: 0.19),
                    surfaceRaised: Color(red: 0.105, green: 0.125, blue: 0.24),
                    surfaceMuted: Color(red: 0.055, green: 0.068, blue: 0.145),
                    primary: Color(red: 0.95, green: 0.94, blue: 1.0),
                    secondary: Color(red: 0.68, green: 0.70, blue: 0.82),
                    accent: Color(red: 0.76, green: 0.69, blue: 0.98),
                    rest: Color(red: 0.76, green: 0.69, blue: 0.98),
                    focus: Color(red: 0.46, green: 0.76, blue: 0.98),
                    border: Color(red: 0.25, green: 0.28, blue: 0.45),
                    onAccent: Color(red: 0.08, green: 0.055, blue: 0.16),
                    isDark: true
                )
            }
            return GalleryPalette(
                background: Color(red: 0.94, green: 0.945, blue: 0.985),
                surface: Color(red: 0.985, green: 0.985, blue: 1.0),
                surfaceRaised: Color.white,
                surfaceMuted: Color(red: 0.90, green: 0.91, blue: 0.965),
                primary: Color(red: 0.075, green: 0.09, blue: 0.20),
                secondary: Color(red: 0.29, green: 0.31, blue: 0.42),
                accent: Color(red: 0.38, green: 0.29, blue: 0.72),
                rest: Color(red: 0.47, green: 0.36, blue: 0.80),
                focus: Color(red: 0.10, green: 0.42, blue: 0.67),
                border: Color(red: 0.76, green: 0.77, blue: 0.88),
                onAccent: Color.white,
                isDark: false
            )

        case .circadian:
            if scheme == .dark {
                return GalleryPalette(
                    background: Color(red: 0.10, green: 0.11, blue: 0.13),
                    surface: Color(red: 0.16, green: 0.17, blue: 0.19),
                    surfaceRaised: Color(red: 0.21, green: 0.22, blue: 0.24),
                    surfaceMuted: Color(red: 0.135, green: 0.145, blue: 0.16),
                    primary: Color(red: 0.95, green: 0.94, blue: 0.91),
                    secondary: Color(red: 0.72, green: 0.72, blue: 0.70),
                    accent: Color(red: 0.66, green: 0.66, blue: 0.96),
                    rest: Color(red: 0.88, green: 0.62, blue: 0.63),
                    focus: Color(red: 0.35, green: 0.82, blue: 0.75),
                    border: Color(red: 0.33, green: 0.34, blue: 0.36),
                    onAccent: Color(red: 0.08, green: 0.08, blue: 0.12),
                    isDark: true
                )
            }
            return GalleryPalette(
                background: Color(red: 0.92, green: 0.92, blue: 0.90),
                surface: Color(red: 0.985, green: 0.98, blue: 0.95),
                surfaceRaised: Color.white,
                surfaceMuted: Color(red: 0.86, green: 0.87, blue: 0.86),
                primary: Color(red: 0.12, green: 0.14, blue: 0.17),
                secondary: Color(red: 0.34, green: 0.35, blue: 0.36),
                accent: Color(red: 0.28, green: 0.29, blue: 0.66),
                rest: Color(red: 0.65, green: 0.31, blue: 0.35),
                focus: Color(red: 0.02, green: 0.46, blue: 0.43),
                border: Color(red: 0.70, green: 0.71, blue: 0.69),
                onAccent: Color.white,
                isDark: false
            )

        case .lantern:
            if scheme == .dark {
                return GalleryPalette(
                    background: Color(red: 0.105, green: 0.10, blue: 0.085),
                    surface: Color(red: 0.17, green: 0.155, blue: 0.125),
                    surfaceRaised: Color(red: 0.22, green: 0.20, blue: 0.16),
                    surfaceMuted: Color(red: 0.14, green: 0.135, blue: 0.115),
                    primary: Color(red: 0.98, green: 0.94, blue: 0.84),
                    secondary: Color(red: 0.76, green: 0.72, blue: 0.64),
                    accent: Color(red: 0.97, green: 0.67, blue: 0.25),
                    rest: Color(red: 0.87, green: 0.62, blue: 0.38),
                    focus: Color(red: 0.50, green: 0.73, blue: 0.57),
                    border: Color(red: 0.38, green: 0.34, blue: 0.27),
                    onAccent: Color(red: 0.20, green: 0.12, blue: 0.04),
                    isDark: true
                )
            }
            return GalleryPalette(
                background: Color(red: 0.965, green: 0.94, blue: 0.875),
                surface: Color(red: 1.0, green: 0.985, blue: 0.94),
                surfaceRaised: Color.white,
                surfaceMuted: Color(red: 0.91, green: 0.89, blue: 0.82),
                primary: Color(red: 0.18, green: 0.16, blue: 0.12),
                secondary: Color(red: 0.39, green: 0.36, blue: 0.29),
                accent: Color(red: 0.72, green: 0.40, blue: 0.06),
                rest: Color(red: 0.72, green: 0.40, blue: 0.16),
                focus: Color(red: 0.20, green: 0.47, blue: 0.31),
                border: Color(red: 0.79, green: 0.74, blue: 0.63),
                onAccent: Color.white,
                isDark: false
            )
        }
    }
}
