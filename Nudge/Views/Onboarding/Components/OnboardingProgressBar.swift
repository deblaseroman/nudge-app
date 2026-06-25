//
//  OnboardingProgressBar.swift
//  Nudge
//
//  Step progress bar for the onboarding header.
//  Animates with NudgeAnimation.progress on step changes.
//

import SwiftUI

struct OnboardingProgressBar: View {
    let currentStep: Int
    let totalSteps: Int

    private var progress: CGFloat {
        CGFloat(currentStep) / CGFloat(totalSteps)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(NudgeTheme.border)
                    .frame(height: 4)

                // Fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(NudgeTheme.primary)
                    .frame(width: geo.size.width * progress, height: 4)
                    .animation(NudgeAnimation.progress, value: progress)
            }
        }
        .frame(height: 4)
    }
}
