//
//  NudgeTheme.swift
//  Nudge
//
//  Every color and font in the app. Never hardcode hex values inline.
//
//  COMPILED INTO BOTH TARGETS (Jul 2026): this file is in the widget's
//  membershipExceptions list in project.pbxproj, so `WidgetColors` can
//  alias these values instead of hand-copying RGB triples (which had
//  drifted — off-by-one channels in background/textPrimary, divergent
//  alphas). One palette, two targets.
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
    /// Green for goal-linked accents — the widget's goal-fallback rows and
    /// the "All Done" session tint. Was hardcoded as an RGB triple in both
    /// targets before joining the theme (Jul 2026).
    static let goalAccent = Color(hex: "#54A477")

    // MARK: - Day slot tints
    //
    // One tint per position in today's schedule: slot 1 is the first thing on
    // the timeline, slot 2 the second, and so on. The same tint fills that
    // task's row under Today, so a block and its row are matched by color
    // instead of by re-reading titles.
    //
    // Deliberately very light and fully opaque — no `.opacity()` at the call
    // site. These are a wayfinding channel, not a priority signal, and must
    // never out-shout `overdue` / `coral`, which are the only colors in the
    // app allowed to mean urgency.

    /// Card/block fills, in rotation order. Six hues is enough separation for
    /// a day's worth of blocks; `daySlotFill(_:)` wraps past the end.
    static let daySlotFills: [Color] = [
        Color(hex: "#DEE9F6"),   // blue
        Color(hex: "#E1F0E0"),   // green
        Color(hex: "#F9F0D6"),   // gold
        Color(hex: "#FBE5E2"),   // rose
        Color(hex: "#ECE4F6"),   // violet
        Color(hex: "#DAEFEE")    // teal
    ]

    /// Stroke / numeral companion for each fill — the same hue, deep enough
    /// to read as an outline against `background`. Index-matched to
    /// `daySlotFills`; the two arrays must stay the same length.
    static let daySlotAccents: [Color] = [
        Color(hex: "#8CA8CB"),
        Color(hex: "#8CB78A"),
        Color(hex: "#CBAE5F"),
        Color(hex: "#D69C95"),
        Color(hex: "#A493CB"),
        Color(hex: "#74B0AE")
    ]

    /// Events sit outside the numbered rotation — they're fixed points in the
    /// day, not steps in a plan — so they get one desaturated stone tint that
    /// no task slot uses. Grey against six hues reads as a different kind of
    /// thing, which is exactly what it is.
    static let eventSlotFill = Color(hex: "#E3E7EA")
    static let eventSlotAccent = Color(hex: "#91A0AA")

    /// The neutral a finished task's tint fades toward. Not `surfaceAlt` —
    /// this needs to be a true grey so the surviving hue reads as a hint of
    /// the original rather than as a second, muddier color.
    static let daySlotCompletedGrey = Color(hex: "#E7E9E8")

    /// How far a completed tint travels toward grey. High enough that a
    /// finished row recedes at a glance, short of 1.0 so you can still tell
    /// which block it was — that identification is the whole point of the
    /// slot colors, and it shouldn't switch off the moment you check the box.
    private static let daySlotCompletedBlend = 0.72

    /// Wrapping lookups — a day with more blocks than hues reuses tints from
    /// the top rather than crashing or falling off the palette.
    static func daySlotFill(_ slot: Int) -> Color {
        daySlotFills[wrappedSlot(slot, count: daySlotFills.count)]
    }

    static func daySlotAccent(_ slot: Int) -> Color {
        daySlotAccents[wrappedSlot(slot, count: daySlotAccents.count)]
    }

    /// Completed variants — mixed toward grey rather than hand-picked, so a
    /// change to a base hue carries into its finished state automatically
    /// instead of leaving a third array to hand-sync.
    static func daySlotFillCompleted(_ slot: Int) -> Color {
        completed(daySlotFill(slot))
    }

    static func daySlotAccentCompleted(_ slot: Int) -> Color {
        completed(daySlotAccent(slot))
    }

    static var eventSlotFillCompleted: Color { completed(eventSlotFill) }
    static var eventSlotAccentCompleted: Color { completed(eventSlotAccent) }

    static func completed(_ color: Color) -> Color {
        color.mix(with: daySlotCompletedGrey, by: daySlotCompletedBlend)
    }

    private static func wrappedSlot(_ slot: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((slot % count) + count) % count
    }

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
