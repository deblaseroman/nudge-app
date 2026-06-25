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
    @Environment(\.scenePhase) private var scenePhase
    @Query private var profiles: [UserProfile]
    @Query private var tasks: [NudgeTask]

    @State private var deepLinkTab: AppTab?

    private var currentProfile: UserProfile? {
        profiles.first
    }

    var body: some View {
        Group {
            if let profile = currentProfile, profile.onboardingComplete {
                MainTabView(profile: profile, deepLinkTab: $deepLinkTab)
            } else {
                OnboardingCoordinatorView()
            }
        }
        .onAppear {
            ensureProfileExists()
            EngagementTracker.shared.recordAppOpen(modelContext: modelContext)
            EngagementTracker.shared.updateInactivityState(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nudgeNotificationOpenTab)) { note in
            // Notification tap / action button told us which tab to land on.
            // The userInfo "tab" string maps to AppTab cases — keep the keys
            // in lockstep with the switch below.
            guard let tabName = note.userInfo?["tab"] as? String else { return }
            switch tabName {
            case "tasks":    deepLinkTab = .tasks
            case "home":     deepLinkTab = .home
            case "calendar": deepLinkTab = .calendar
            case "stats":    deepLinkTab = .stats
            case "settings": deepLinkTab = .settings
            case "account":  deepLinkTab = .account
            default: break
            }
        }
        .onOpenURL { url in
            guard let deepLink = DeepLink(url: url) else { return }
            switch deepLink {
            case .startSession:
                // Widget-driven auto-start. Pick the highest-priority/most-
                // overdue incomplete task and kick off a session immediately.
                if !SessionCoordinator.shared.isSessionActive,
                   let profile = currentProfile {
                    let comparator = TaskSortComparator()
                    let pick = tasks
                        .filter { !$0.isInformationalEvent && !$0.isComplete }
                        .sorted { comparator.compare($0, $1) }
                        .first
                    if let task = pick {
                        SessionCoordinator.shared.startSession(
                            task: task,
                            userName: profile.name
                        )
                    }
                }
                deepLinkTab = .tasks
            case .focusSession:
                deepLinkTab = .tasks
            case .open:
                break
            }
        }
        .task(id: notificationToken) {
            // Trailing-edge debounce. The notification token changes every
            // time the user nudges a wheel-picker tick — rapid spins would
            // otherwise fire `purgePastEvents`, the daily scheduler, and the
            // arbiter dozens of times in a few seconds, each doing a fresh
            // SwiftData fetch into the shared main-app context. The context
            // bloats and the app eventually gets killed for memory.
            //
            // `.task(id:)` cancels the previous task whenever the id
            // changes, and `Task.sleep` honors cancellation — so only the
            // run AFTER the user stops changing things ever proceeds.
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }

            guard let profile = currentProfile else { return }
            // Clear yesterday's events before anything else uses the event list.
            CalendarService.shared.purgePastEvents(modelContext: modelContext)
            // Factual repeating notifications (bedtime planning + morning
            // kickoff). Not part of the arbiter.
            NotificationScheduler.shared.scheduleDailyNotifications(for: profile)
            // Every other notification decision goes through the arbiter.
            NudgeArbiter.shared.reevaluate(
                reason: .appLaunch,
                profile: profile,
                modelContext: modelContext
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Always pause the 60s countdown ticker when leaving the
            // foreground — battery hygiene. The next .active branch restarts.
            if newPhase == .background || newPhase == .inactive {
                CountdownClock.shared.stop()
                return
            }

            guard newPhase == .active, let profile = currentProfile else { return }
            // If the user ended the session from the home-screen widget while
            // the app was backgrounded, the Live Activity is gone but the
            // coordinator may still hold internal state. Reconcile.
            SessionCoordinator.shared.syncIfActivityDismissed()

            // Resume the 60s countdown ticker. We explicitly stop it on
            // background (below) so the Timer doesn't sit registered while
            // suspended — fewer wake-up registrations = better battery.
            CountdownClock.shared.start()

            // Drop yesterday's events the moment the app foregrounds — this
            // is the practical equivalent of "remove at midnight" since iOS
            // can't run code while the app is suspended.
            CalendarService.shared.purgePastEvents(modelContext: modelContext)

            // Every notification decision flows through the arbiter.
            NudgeArbiter.shared.reevaluate(
                reason: .sceneActive,
                profile: profile,
                modelContext: modelContext
            )

            // Extend the rolling calendar window when a week has passed.
            // No-op if the user hasn't connected a calendar yet.
            if profile.calendarSource == "Apple Calendar" {
                Task {
                    _ = await CalendarService.shared.refreshRollingWindow(
                        modelContext: modelContext
                    )
                }
            }
        }
    }

    /// Re-trigger notification scheduling whenever any field that affects
    /// notification timing OR per-kind enablement changes. Flipping any of
    /// the consumed toggles in Settings should reflect immediately, so each
    /// toggle is part of the token.
    private var notificationToken: String {
        guard let profile = currentProfile else { return "no-profile" }
        return [
            profile.bedtime.timeIntervalSinceReferenceDate.description,
            (profile.wakeTime ?? profile.morningCheckInTime).timeIntervalSinceReferenceDate.description,
            profile.notificationsEnabled.description,
            profile.morningCheckInNotificationsEnabled.description,
            profile.eveningCheckInNotificationsEnabled.description,
            profile.taskDueSoonNotificationsEnabled.description,
            profile.sessionStarterNotificationsEnabled.description,
            profile.deadlinePrepNotificationsEnabled.description
        ].joined(separator: "-")
    }

    /// Creates a default UserProfile if none exists
    private func ensureProfileExists() {
        if profiles.isEmpty {
            let profile = UserProfile()
            modelContext.insert(profile)
        }
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
            DailySession.self,
            CheckIn.self,
            EngagementState.self,
            NotificationEvent.self,
            SentNotificationFlag.self,
            NudgeOutcome.self,
            TaskIntelligence.self,
        ], inMemory: true)
}
