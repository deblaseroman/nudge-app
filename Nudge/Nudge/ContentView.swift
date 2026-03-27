//
//  ContentView.swift
//  Nudge
//
//  Root view — routes to onboarding or home based on user profile state.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    private var currentProfile: UserProfile? {
        profiles.first
    }

    var body: some View {
        Group {
            if let profile = currentProfile, profile.onboardingComplete {
                // TODO: Replace with MainTabView in Phase 4
                HomePlaceholderView(profile: profile)
            } else {
                // TODO: Replace with OnboardingView in Phase 3
                OnboardingPlaceholderView()
            }
        }
        .onAppear {
            ensureProfileExists()
        }
    }

    /// Creates a default UserProfile if none exists
    private func ensureProfileExists() {
        if profiles.isEmpty {
            let profile = UserProfile()
            modelContext.insert(profile)
        }
    }
}

// MARK: - Placeholder Views (replaced in later phases)

struct HomePlaceholderView: View {
    let profile: UserProfile

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(NudgeTheme.primary)

            Text("Welcome back, \(profile.name.isEmpty ? "friend" : profile.name)!")
                .font(.custom(NudgeTheme.fontSemiBold, size: 22))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("Home screen coming in Phase 4")
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NudgeTheme.background)
    }
}

struct OnboardingPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 60))
                .foregroundColor(NudgeTheme.primary)

            Text("Nudge")
                .font(.custom(NudgeTheme.fontBrand, size: 32))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("Onboarding coming in Phase 3")
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NudgeTheme.background)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            NudgeTask.self,
            NudgeGoal.self,
            NudgeHabit.self,
            UserProfile.self,
            DailyStats.self,
            CheckIn.self,
        ], inMemory: true)
}
