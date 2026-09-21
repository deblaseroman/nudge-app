//
//  ContentView.swift
//  Nudge
//
//  Root view — routes to onboarding or home based on user profile state.
//

import Combine
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
            recordForegroundAndClassifyOutcomes()
        }
        .onReceive(
            // `.receive(on: DispatchQueue.main)` is the canonical Combine
            // main-hop. NotificationCenter.Publisher emits SYNCHRONOUSLY on
            // the post()-thread; without this operator, the @State mutation
            // below runs on whatever thread called post(). When that thread
            // wasn't main, SwiftUI's sheet/tab presentation eventually hit
            // `_performBlockAfterCATransactionCommitSynchronizes` off-main
            // and the app crashed with "Call must be made on main thread".
            // Forcing delivery onto the main queue at the publisher level
            // means the .onReceive closure (and the @State write inside)
            // are guaranteed to run on main no matter who posted.
            NotificationCenter.default
                .publisher(for: .nudgeNotificationOpenTab)
                .receive(on: DispatchQueue.main)
        ) { note in
            // Notification tap / action button told us which tab to land on.
            // The userInfo "tab" string maps to AppTab cases — keep the keys
            // in lockstep with the switch below.
            guard let tabName = note.userInfo?["tab"] as? String else { return }
            switch tabName {
            case "tasks":    deepLinkTab = .tasks
            case "home":     deepLinkTab = .home
            case "calendar": deepLinkTab = .calendar
            case "stats":    deepLinkTab = .stats
            case "goals":    deepLinkTab = .goals
            case "settings": deepLinkTab = .settings
            case "account":  deepLinkTab = .account
            default: break
            }
        }
        .onOpenURL { url in
            guard let deepLink = DeepLink(url: url) else { return }
            switch deepLink {
            case .startSession:
                // Widget-driven auto-start. Pick the same task the rest of the
                // app calls "next" and kick off a session immediately.
                if !SessionCoordinator.shared.isSessionActive,
                   let profile = currentProfile {
                    let open = tasks
                        .filter { !$0.isInformationalEvent && !$0.isComplete }
                    // The comparator is plan-first: the plan's NEXT item
                    // (lowest sequenceIndex) wins when one exists, matching
                    // NudgeNotificationService.pickTopOpenTask and the
                    // widget's display order by construction.
                    let comparator = TaskSortComparator()
                    let pick = open.min { comparator.compare($0, $1) }
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
            // Clear stale timeline placements the same way — an unfinished
            // task placed on a past day matches no list section and both
            // planners skip it, so without this it vanishes at midnight.
            PlacementRollover.sweep(modelContext: modelContext)
            // Turn exam events inside their prep window into daily study
            // tasks (idempotent; tombstoned days never recreated). BEFORE
            // the reevaluate so fresh tasks are in the store when the
            // arbiter builds candidates.
            ExamPrepSweep.shared.run(modelContext: modelContext)
            // Plan proposals (cycle 2026-09-16-01): the reader judges the
            // anchored items ahead and stores proposals for the message
            // box to ask about. Async, proposes only, writes nothing.
            PlanProposalSweep.shared.runIfNeeded(modelContext: modelContext)
            // Fold any stored "urgent" priority into "high" (retired value;
            // idempotent, zero rows after the first pass).
            LegacyPriorityNormalizer.sweep(modelContext: modelContext)
            // Sweep the retired fixed daily notifications (pre-Jul-2026
            // repeating requests that outlive the code that scheduled them).
            NotificationScheduler.shared.cancelRetiredDailyNotifications()
            // EVERY notification decision goes through the arbiter — the
            // morning prompt included.
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
            // Same rollover treatment for stale timeline placements.
            PlacementRollover.sweep(modelContext: modelContext)

            // Exam → study-task sweep, same cadence as the rollover (launch
            // covers cold start; this covers the day changing while the app
            // was backgrounded). Runs before the reevaluate below.
            ExamPrepSweep.shared.run(modelContext: modelContext)
            PlanProposalSweep.shared.runIfNeeded(modelContext: modelContext)

            // Stamp the foreground and resolve any delivered-but-unanswered
            // nudges. `.onAppear` above covers cold launch; this covers
            // background → foreground, which nothing recorded before.
            recordForegroundAndClassifyOutcomes()

            // Every notification decision flows through the arbiter.
            NudgeArbiter.shared.reevaluate(
                reason: .sceneActive,
                profile: profile,
                modelContext: modelContext
            )

            // Extend the rolling calendar window (daily; no-op without a
            // connected calendar), THEN auto-plan the day. The auto-plan
            // lives inside this Task, after the await, deliberately: it
            // must see fresh events, and the sweeps above (rollover, exam
            // prep) have already run synchronously in this branch — so the
            // ordering is purge → rollover → prep sweep → calendar refresh
            // → auto-plan, and the plan is never built against stale
            // events or stale placements.
            //
            // Explicit @MainActor on the Task. `CalendarService` is
            // @MainActor and `modelContext` is bound to the main context;
            // touching either from a cooperative-pool Task body raises
            // "Call must be made on main thread". @_inheritActorContext
            // *should* carry main isolation in from this SwiftUI closure
            // automatically, but being explicit removes any ambiguity
            // across Swift compiler versions / concurrency modes.
            Task { @MainActor in
                var importedEvents = 0
                if profile.calendarSource == "Apple Calendar" {
                    let result = await CalendarService.shared.refreshRollingWindow(
                        modelContext: modelContext
                    )
                    importedEvents = result?.importedCount ?? 0
                } else if profile.calendarSource == "Calendar Link (iCal)" || profile.calendarSource == "Canvas iCal",
                          let url = profile.calendarImportURL,
                          !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // The iCal feed refreshes daily like Apple Calendar
                    // (cycle 2026-09-16-01 item 4); it used to be a one-time
                    // snapshot taken on the tap.
                    let result = await CalendarService.shared.refreshICalFeedIfNeeded(
                        urlString: url, modelContext: modelContext
                    )
                    importedEvents = result?.importedCount ?? 0
                }
                // First foreground of a new day → plan it (once; never
                // touches manual placements; skips if a plan exists).
                if let outcome = DayPlanEngine.autoPlanIfNewDay(
                    profile: profile,
                    modelContext: modelContext
                ), case .placed = outcome {
                    // Placements changed the store after the reevaluate
                    // above — run the arbiter against the planned day.
                    NudgeArbiter.shared.reevaluate(
                        reason: .taskCreatedOrEdited,
                        profile: profile,
                        modelContext: modelContext
                    )
                }
                // Refresh the AI nudge-copy cache — the same first-open-of-
                // a-new-day hook the rollover and calendar refresh share,
                // deliberately AFTER both so generation sees fresh events
                // and today's placements. A real calendar import counts as
                // a shift in what the day is about even when the day
                // marker says the baseline already ran. NOT on every
                // reevaluate — `generateIfNeeded` owns the day-marker,
                // min-interval, and daily-cap throttles.
                let copyTrigger: NudgeCopyGenerator.Trigger =
                    importedEvents > 0 ? .calendarImport : .newDay
                if await NudgeCopyGenerator.shared.generateIfNeeded(
                    trigger: copyTrigger,
                    modelContext: modelContext
                ) {
                    // New copy landed after the reevaluate above — run the
                    // arbiter again so scheduled notifications carry it.
                    NudgeArbiter.shared.reevaluate(
                        reason: .taskCreatedOrEdited,
                        profile: profile,
                        modelContext: modelContext
                    )
                }
            }
        }
    }

    /// Re-trigger notification scheduling whenever any field that affects
    /// notification timing OR per-kind enablement changes. Flipping any of
    /// the consumed toggles in Settings should reflect promptly, so each
    /// toggle is part of the token. (The reevaluate this drives uses a
    /// time-triggered reason, so a toggle flip within the arbiter's 60s
    /// debounce window lands on the next run — same latency as every other
    /// arbiter toggle.)
    private var notificationToken: String {
        guard let profile = currentProfile else { return "no-profile" }
        return [
            profile.bedtime.timeIntervalSinceReferenceDate.description,
            (profile.wakeTime ?? profile.morningCheckInTime).timeIntervalSinceReferenceDate.description,
            profile.notificationsEnabled.description,
            profile.morningCheckInNotificationsEnabled.description,
            profile.taskDueSoonNotificationsEnabled.description,
            profile.dueSoonReminderNotificationsEnabled.description,
            profile.sessionStarterNotificationsEnabled.description,
            profile.floaterCheckInNotificationsEnabled.description,
            profile.eventReminderNotificationsEnabled.description,
            profile.comeBackNotificationsEnabled.description,
            profile.placementLeadNotificationsEnabled.description,
            profile.placementMissedNotificationsEnabled.description,
            // Quiet hours. All three, not just the toggle: with custom hours
            // active, moving a time is the whole change and the toggle never
            // moves — a token that only watched the switch would leave the
            // gate running on the old window until something else happened
            // to trigger a reevaluate.
            profile.quietHoursFollowSleepSchedule.description,
            profile.quietHoursStartTime?.timeIntervalSinceReferenceDate.description ?? "nil",
            profile.quietHoursEndTime?.timeIntervalSinceReferenceDate.description ?? "nil"
        ].joined(separator: "-")
    }

    /// Foreground bookkeeping for the outcome-recording loop: stamp the
    /// open into `AppOpenLog`, then classify every delivered nudge whose
    /// response window has closed.
    ///
    /// Record-then-classify is safe in that order because
    /// `outcomeClassificationGraceMinutes` > `outcomeActionWindowMinutes`:
    /// every window being judged is already closed, so THIS open can never
    /// be counted as engagement with a row it's classifying.
    ///
    /// Independent of the arbiter's reevaluate — `cancelAll` no longer
    /// touches past-due pending rows, so neither ordering can lose data.
    private func recordForegroundAndClassifyOutcomes() {
        AppOpenLog.record()
        NudgeOutcomeClassifier.shared.classifyPending(modelContext: modelContext)
        #if DEBUG
        NudgeOutcomeClassifier.shared.debugDumpRecentOutcomes(modelContext: modelContext)
        #endif
    }

    /// Creates a default UserProfile if none exists
    private func ensureProfileExists() {
        if profiles.isEmpty {
            let profile = UserProfile()
            modelContext.insert(profile)
        }
        #if DEBUG
        // Simulator-only launch arguments so a build can be looked at
        // without typing through onboarding:
        //   -nudge-skip-onboarding      marks the profile complete
        //   -nudge-tab tasks|home|calendar   lands on that tab
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-nudge-skip-onboarding"),
           let profile = profiles.first ?? (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first {
            profile.onboardingComplete = true
            if profile.name.isEmpty { profile.name = "Test" }
            try? modelContext.save()
        }
        // -nudge-import-screenshot <path>: run the real screenshot importer
        // on an image file (simulator can read Mac paths) and print what it
        // did. How a reported schedule gets reproduced without a device.
        if let i = args.firstIndex(of: "-nudge-import-screenshot"), i + 1 < args.count,
           let image = UIImage(contentsOfFile: args[i + 1]) {
            let context = modelContext
            Task { @MainActor in
                let result = await ScreenshotCalendarImporter.shared.importFromImage(
                    image, defaultCategory: "work", modelContext: context
                )
                print("[DEBUG import] \(result.summary) errors=\(result.errors)")
                let events = (try? context.fetch(FetchDescriptor<NudgeTask>(
                    predicate: #Predicate<NudgeTask> { $0.source == "screenshot" }
                ))) ?? []
                let fmt = DateFormatter(); fmt.dateFormat = "EEE yyyy-MM-dd h:mm a"
                for e in events.sorted(by: { ($0.specificTime ?? .distantPast) < ($1.specificTime ?? .distantPast) }) {
                    print("[DEBUG import] row: \(e.title) @ \(e.specificTime.map { fmt.string(from: $0) } ?? "-") \(e.estimatedMinutes ?? 0) min")
                }
            }
        }
        if let i = args.firstIndex(of: "-nudge-tab"), i + 1 < args.count {
            let wanted: AppTab? = switch args[i + 1] {
                case "tasks": .tasks
                case "home": .home
                case "calendar": .calendar
                default: nil
            }
            // After the tab bar exists: MainTabView consumes this on change.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { deepLinkTab = wanted }
        }
        #endif
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
    // One of the THREE hand-synced schema lists (Cross-cutting invariant 2
    // in ARCHITECTURE.md) — keep in lockstep with
    // `SharedModelContainer.schema` and `widgetSchema`. It had drifted:
    // four models were missing until Jul 2026.
    ContentView()
        .modelContainer(for: [
            NudgeTask.self,
            NudgeGoal.self,
            NudgeHabit.self,
            UserProfile.self,
            DailyStats.self,
            DailySession.self,
            CheckIn.self,
            CompletedTaskRecord.self,
            TimeBlock.self,
            EngagementState.self,
            NotificationEvent.self,
            SentNotificationFlag.self,
            NudgeOutcome.self,
            TaskIntelligence.self,
            CategoryDurationStats.self,
            EventDurationStats.self,
            PrepTombstone.self,
            NudgeCommitment.self,
        ], inMemory: true)
}
