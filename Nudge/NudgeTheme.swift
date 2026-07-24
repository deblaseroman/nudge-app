//
//  NudgeTheme.swift
//  Nudge
//
//  Every color and font in the app. Never hardcode hex values inline.
//

import SwiftUI

struct NudgeTheme {
    // MARK: - Backgrounds
    static let background = Color(hex: "#F6F8F6")
    static let surface = Color(hex: "#FFFFFF").opacity(0.88)
    static let surfaceAlt = Color(hex: "#F0F3F0")

    // MARK: - Brand
    static let primary = Color(hex: "#7393B3")
    static let primaryLight = Color(hex: "#9CB2C8")
    static let yellow = Color(hex: "#D7DDD8")
    static let pink = Color(hex: "#B9C6BC")

    // MARK: - Text
    static let textPrimary = Color(hex: "#1C211D")
    static let textSecondary = Color(hex: "#5F665F")
    static let textMuted = Color(hex: "#8C948E")
    static let textPlaceholder = Color(hex: "#B6BDB7")

    // MARK: - Semantic
    static let success = Color(hex: "#7393B3")
    static let warning = Color(hex: "#9FA7A1")
    static let danger = Color(hex: "#7C8A7F")
    static let overdue = Color(hex: "#D94141")
    /// Soft coral used for countdown urgency indicators. Calmer than red —
    /// signals attention without screaming.
    static let coral = Color(hex: "#FF7F50")
    /// Amber for the STAKES / importance channel — the "High" pill and the
    /// high-stakes left bar in the task list. Deliberately its own hue,
    /// distinct from `coral` and `overdue`, which both track TIME pressure
    /// (approaching / overdue). Stakes is importance and stays constant
    /// while a row's time colors change, so it must not share their red
    /// family — that separation is the whole point of the signal.
    static let amber = Color(hex: "#C98A1F")

    // MARK: - Border
    static let border = Color(hex: "#7E8780").opacity(0.22)

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
