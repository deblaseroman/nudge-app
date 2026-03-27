//
//  NudgeTheme.swift
//  Nudge
//
//  Every color and font in the app. Never hardcode hex values inline.
//

import SwiftUI

struct NudgeTheme {
    // MARK: - Backgrounds
    static let background = Color(hex: "#FAFAF8")      // warm off-white (headers)
    static let surface = Color.white                    // chat areas, cards
    static let surfaceAlt = Color(hex: "#F5F4F0")

    // MARK: - Brand
    static let primary = Color(hex: "#FF6040")          // coral orange
    static let primaryLight = Color(hex: "#FF8C5A")
    static let yellow = Color(hex: "#FFD166")
    static let pink = Color(hex: "#FF6B9D")

    // MARK: - Text
    static let textPrimary = Color(hex: "#1a1a18")
    static let textSecondary = Color(hex: "#6b6860")
    static let textMuted = Color(hex: "#a09880")
    static let textPlaceholder = Color(hex: "#c4b8a0")

    // MARK: - Semantic
    static let success = Color(hex: "#4CAF50")
    static let warning = Color(hex: "#FFD166")
    static let danger = Color(hex: "#FF6040")

    // MARK: - Border
    static let border = Color(hex: "#1a1a18").opacity(0.08)

    // MARK: - Fonts (Lexend — add .ttf files to project and Info.plist)
    static let fontBrand = "Lexend-Bold"
    static let fontLight = "Lexend-Light"
    static let fontBody = "Lexend-Regular"
    static let fontMedium = "Lexend-Medium"
    static let fontSemiBold = "Lexend-SemiBold"
    static let fontBold = "Lexend-Bold"

    // MARK: - Corner Radius
    static let radiusCard: CGFloat = 16
    static let radiusButton: CGFloat = 14
    static let radiusChip: CGFloat = 20
    static let radiusSheet: CGFloat = 24
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
