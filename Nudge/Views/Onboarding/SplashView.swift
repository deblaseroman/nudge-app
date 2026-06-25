//
//  SplashView.swift
//  Nudge
//
//  Screen 01 — Splash. Standalone (no chat shell).
//  Mascot springs in, wordmark fades up with "u" in coral,
//  three pulsing coral dots, auto-advances after 2 seconds.
//

import SwiftUI
import UIKit

struct SplashView: View {
    let viewModel: OnboardingViewModel

    @State private var showMascot = false
    @State private var showWordmark = false
    @State private var pulsingDot = 0
    /// Held in state so `.onDisappear` can invalidate it. The previous
    /// version dropped the timer reference on the floor — the run loop
    /// kept firing the 350 ms tick forever even after the splash was
    /// gone, mutating `pulsingDot` on a dead view and growing memory.
    @State private var pulseTimer: Timer?
    @State private var didAdvance = false

    /// The splash uses the large hero pose (`mascot-hero`) rather than
    /// the circular avatar — this is the "main app cover" character
    /// shot. Falls back to the small avatar when the hero asset isn't
    /// in the catalog yet, so the build never breaks.
    @ViewBuilder
    private var heroMascot: some View {
        if UIImage(named: "mascot-hero") != nil {
            Image("mascot-hero")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 240, height: 240)
        } else {
            MascotAvatarView(size: 200)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Mascot — springs in
            heroMascot
                .scaleEffect(showMascot ? 1.0 : 0.3)
                .opacity(showMascot ? 1.0 : 0.0)

            // Wordmark "nudge" — "u" in coral
            HStack(spacing: 0) {
                Text("n")
                    .foregroundColor(NudgeTheme.textPrimary)
                Text("u")
                    .foregroundColor(NudgeTheme.primary)
                Text("dge")
                    .foregroundColor(NudgeTheme.textPrimary)
            }
            .font(.custom(NudgeTheme.fontBrand, size: 36))
            .padding(.top, 16)
            .opacity(showWordmark ? 1.0 : 0.0)
            .offset(y: showWordmark ? 0 : 10)

            Spacer()

            // Three pulsing coral dots
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(NudgeTheme.primary)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulsingDot == index ? 1.3 : 0.8)
                        .opacity(pulsingDot == index ? 1.0 : 0.4)
                        .animation(NudgeAnimation.snappy, value: pulsingDot)
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NudgeTheme.background)
        .onAppear {
            // Mascot springs in immediately
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                showMascot = true
            }

            // Wordmark fades up with 0.3s delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(NudgeAnimation.gentle) {
                    showWordmark = true
                }
            }

            // Pulsing dots — keep a handle so `.onDisappear` can stop it.
            // The timer references no captured state other than the simple
            // `@State` integer, which is value-typed under the hood, so no
            // self-capture worries.
            pulseTimer?.invalidate()
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                pulsingDot = (pulsingDot + 1) % 3
            }

            // Auto-advance after 2 seconds. Guard against double-fire if
            // the view re-appears (e.g. navigation pop back to splash).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard !didAdvance else { return }
                didAdvance = true
                viewModel.advance()
            }
        }
        .onDisappear {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }
}
