//
//  NudgeApp.swift
//  Nudge
//
//  Created by Roman DeBlase on 3/25/26.
//

import BackgroundTasks
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Identifier for the daily 6 AM recalculation background task.
/// MUST also be listed in Info.plist under
/// `BGTaskSchedulerPermittedIdentifiers` for iOS to allow registration.
let dailyRecalcTaskID = "com.deblaser.nudge.dailyRecalc"

final class NudgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Delegate must be set synchronously before launch completes,
        // otherwise notification responses that triggered the launch are lost.
        UNUserNotificationCenter.current().delegate = NudgeNotificationService.shared
        // Register the action-button categories so the arbiter can attach
        // them to its notifications via UNNotificationContent.categoryIdentifier.
        Task { @MainActor in
            NudgeNotificationCategories.registerAll()
        }
        Task { @MainActor in
            // NudgeNotificationService is @MainActor — explicit isolation
            // here because UIApplicationDelegate's methods aren't
            // @MainActor-isolated, so this Task wouldn't inherit it.
            await NudgeNotificationService.shared.configure()
        }

        // Register the background task that runs the smart-notification
        // recalculation each morning. The handler runs in the background when
        // the OS decides to wake the app; nothing happens here at launch time.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: dailyRecalcTaskID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.handleDailyRecalc(refreshTask)
            }
        }
        Self.scheduleNextDailyRecalc()

        // One-shot repair of the stakes signal on rows that predate it or
        // got the deterministic calendar-import value. Fire-and-forget and
        // fails silently — it must never delay or block launch. Lives here
        // rather than in a view because it is a data migration, not UI.
        Task { @MainActor in
            StakesBackfill.shared.runIfNeeded()
        }

        // ⚠️ TEMP-STAKES-DUMP — remove after verifying capture-assigned
        // stakes. Grep the tag to delete every trace (this block + the
        // method below).
        #if DEBUG
        Task { @MainActor in
            Self.tempDumpAllTaskStakes()
        }
        #endif

        return true
    }

    /// Submits a request for the next 6 AM. iOS chooses the actual delivery
    /// time — this is "earliest begin", not a guarantee. ContentView's
    /// app-open trigger is the reliable fallback.
    static func scheduleNextDailyRecalc() {
        let request = BGAppRefreshTaskRequest(identifier: dailyRecalcTaskID)
        request.earliestBeginDate = Self.nextSixAM()
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("[NudgeApp] Failed to schedule BG recalc: \(error)")
            #endif
        }
    }

    private static func nextSixAM() -> Date {
        let calendar = Calendar.current
        let now = Date()
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = 6
        comps.minute = 0
        guard var target = calendar.date(from: comps) else {
            return now.addingTimeInterval(24 * 60 * 60)
        }
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }

    /// Runs in the background when iOS wakes us at (or after) 6 AM. Recompute
    /// today's smart notifications, then immediately schedule the next 6 AM
    /// run so the cycle continues.
    @MainActor
    static func handleDailyRecalc(_ task: BGAppRefreshTask) {
        // Always re-arm the next run, regardless of how this one goes.
        Self.scheduleNextDailyRecalc()

        let context = ModelContext(SharedModelContainer.container)
        // Purge yesterday's events so the new day's notification recalculation
        // doesn't re-schedule reminders for events that already happened.
        CalendarService.shared.purgePastEvents(modelContext: context)

        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        if let profile {
            // All notification decisions go through the arbiter — including
            // the morning prompt, which is why this ~6 AM run matters: it
            // reassesses today's day-load with the morning's data before
            // the wake+30 fire time.
            NudgeArbiter.shared.reevaluate(
                reason: .backgroundTask,
                profile: profile,
                modelContext: context
            )
            // Sweep the retired pre-Jul-2026 repeating daily notifications.
            NotificationScheduler.shared.cancelRetiredDailyNotifications()
        }
        task.setTaskCompleted(success: true)
    }

    // ⚠️ TEMP-STAKES-DUMP — remove after verifying capture-assigned stakes.
    // Prints every NudgeTask at launch so we can eyeball what stakes freshly
    // captured tasks receive. The StakesBackfill dry-run table excludes them
    // by design (they're neither nil-stakes nor calendar rows), so this is
    // the only place we see the capture flow's own output. Sorted by source
    // so capture / calendar / manual rows cluster. Grep "TEMP-STAKES-DUMP".
    #if DEBUG
    @MainActor
    static func tempDumpAllTaskStakes() {
        let context = SharedModelContainer.container.mainContext
        let tasks = ((try? context.fetch(FetchDescriptor<NudgeTask>())) ?? [])
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        print("\n── TEMP-STAKES-DUMP · \(tasks.count) task(s) ──────────────────────")
        for t in tasks {
            let userSet = t.stakesIsUserSet ? " (user-set)" : ""
            print("  stakes=\(t.stakes?.rawValue ?? "nil")\(userSet)"
                + "\tsrc=\(t.source)"
                + "\tcat=\(t.category ?? "nil")"
                + "\tpri=\(t.priority)"
                + "\t\(t.title)")
        }
        print("── TEMP-STAKES-DUMP end ───────────────────────────────────────\n")
    }
    #endif
}

@main
struct NudgeApp: App {
    @UIApplicationDelegateAdaptor(NudgeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(SharedModelContainer.container)
    }
}

// MARK: - Deep Link Routing

/// Parses incoming URLs from widgets and notifications
enum DeepLink {
    case startSession
    case focusSession
    case open

    init?(url: URL) {
        guard url.scheme == "nudge" else { return nil }
        switch url.host {
        case "start-session":
            self = .startSession
        case "focus-session":
            self = .focusSession
        case "open":
            self = .open
        default:
            return nil
        }
    }
}
