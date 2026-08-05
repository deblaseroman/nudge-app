//
//  MainTabView.swift
//  Nudge
//
//  Main app shell after onboarding with tab-based navigation.
//

import SwiftUI
import SwiftData

struct MainTabView: View {
    let profile: UserProfile
    @Binding var deepLinkTab: AppTab?

    @State private var selectedTab: AppTab = .home

    /// One-shot flag set by `OnboardingViewModel.completeOnboarding` so the
    /// first screen after onboarding is the Goals tab (the goals the user
    /// just set), not Home. Cleared on consumption; every later launch
    /// starts on Home as before.
    static let landOnGoalsAfterOnboardingKey = "nudge.onboarding.landOnGoals"

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .settings:
                    SettingsTabView(profile: profile, selectedTab: $selectedTab)
                case .tasks:
                    TasksTabView(profile: profile, selectedTab: $selectedTab)
                case .home:
                    HomeTabView(profile: profile, selectedTab: $selectedTab)
                case .stats:
                    StatsTabView(selectedTab: $selectedTab)
                case .calendar:
                    CalendarTabView(profile: profile, selectedTab: $selectedTab)
                case .goals:
                    GoalsTabView(selectedTab: $selectedTab)
                case .account:
                    AccountTabView(profile: profile)
                }
            }

            AppTabBar(selectedTab: $selectedTab)
        }
        .background(NudgeTheme.background)
        // HIG: the entire design system is built around a light palette
        // (intentional brand decision). Explicitly opting into Light mode is
        // the HIG-compliant way to declare "this app does not support Dark
        // Mode" rather than letting hex-defined colors fall through and
        // become unreadable in iOS Dark Mode.
        .preferredColorScheme(.light)
        .onAppear {
            let defaults = SharedModelContainer.appGroupDefaults
            if defaults.bool(forKey: Self.landOnGoalsAfterOnboardingKey) {
                defaults.removeObject(forKey: Self.landOnGoalsAfterOnboardingKey)
                selectedTab = .goals
            }
        }
        .onChange(of: deepLinkTab) { _, newTab in
            guard let tab = newTab else { return }
            // Defensive main hop. `.onChange` should already be main, but
            // when this fires during the notification-driven foregrounding
            // handoff (Not yet → cold/warm launch → scene becomes active →
            // deepLinkTab assigned), `withAnimation` + @State mutation +
            // re-render are happening inside an unstable transition window.
            // Deferring to the next runloop tick lets the scene settle on
            // main before SwiftUI commits the tab switch.
            DispatchQueue.main.async {
                withAnimation(NudgeAnimation.standard) {
                    selectedTab = tab
                }
                deepLinkTab = nil
            }
        }
    }
}

enum AppTab {
    case settings
    case tasks
    case home
    case stats
    case calendar
    case goals
    case account
}
