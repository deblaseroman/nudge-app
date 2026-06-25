//
//  TypingIndicatorView.swift
//  Nudge
//
//  Three bouncing dots inside a mascot-styled chat bubble.
//  Shows when Nudge is "typing" a message during onboarding.
//

import SwiftUI

struct TypingIndicatorView: View {
    @State private var activeDot = 0
    /// Held in state so `.onDisappear` can invalidate it. The previous
    /// version called `Timer.scheduledTimer` without retaining the timer
    /// — the run loop kept firing the 300 ms tick forever after the chat
    /// shell moved past the typing state. Across an onboarding session
    /// each typing-indicator appearance leaked another tick source.
    @State private var animationTimer: Timer?

    private let dotSize: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MascotAvatarView(size: 28)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(NudgeTheme.textMuted)
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: activeDot == index ? -4 : 0)
                        .animation(NudgeAnimation.snappy, value: activeDot)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
        }
        .onAppear { startAnimation() }
        .onDisappear {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            withAnimation(NudgeAnimation.snappy) {
                activeDot = (activeDot + 1) % 3
            }
        }
    }
}
