//
//  ChatBubbleView.swift
//  Nudge
//
//  Renders a single chat message bubble.
//  Mascot bubbles: white card with border, left-aligned, small avatar.
//  User bubbles: coral background, white text, right-aligned.
//

import SwiftUI

struct ChatBubbleView: View {
    let message: OnboardingMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .mascot {
                mascotBubble
            } else {
                userBubble
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .mascot ? .leading : .trailing
        )
    }

    // MARK: - Mascot Bubble (left-aligned, white + border)

    private var mascotBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            MascotAvatarView(size: 28)

            Text(message.text)
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(NudgeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                        .stroke(NudgeTheme.border, lineWidth: 1)
                )
                .frame(maxWidth: 280, alignment: .leading)
        }
    }

    // MARK: - User Bubble (right-aligned, coral)

    private var userBubble: some View {
        Text(message.text)
            .font(.custom(NudgeTheme.fontBody, size: 15))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(NudgeTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .frame(maxWidth: 280, alignment: .trailing)
    }
}
