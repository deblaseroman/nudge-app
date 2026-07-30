//
//  ScreenHeader.swift
//  Nudge
//
//  Reusable screen header used across tab views.
//

import SwiftUI

struct ScreenHeader: View {
    let title: String
    /// Optional since Jul 2026 — the Tasks tab dropped its description line
    /// (it narrated a sort order the user doesn't need explained) and the
    /// message box speaks under the title instead.
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 28))
                .foregroundColor(NudgeTheme.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(.custom(NudgeTheme.fontBody, size: 15))
                    .foregroundColor(NudgeTheme.textMuted)
            }
        }
    }
}

struct AccountShortcutButton: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        Button(action: {
            NudgeHaptics.light()
            withAnimation(NudgeAnimation.standard) {
                selectedTab = .account
            }
        }) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(NudgeTheme.primary)
                .frame(width: 44, height: 44)
                .background(NudgeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(NudgeTheme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
