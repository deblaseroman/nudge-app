//
//  NudgeApp.swift
//  Nudge
//
//  Created by Roman DeBlase on 3/25/26.
//

import BackgroundTasks
import EventKit
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

        // ⚠️ TEMP-STAKES-DUMP — remove after verifying capture-assigned
        // stakes. Grep the tag to delete every trace (this block + the
        // method below).
        #if DEBUG
        Task { @MainActor in
            Self.tempDumpAllTaskStakes()
        }
        #endif

        // Eval harness (`eval/run.sh`): `-nudge-eval <cases.json>` runs the
        // cases against the real capture / arbiter code on an isolated
        // in-memory store, prints EVAL lines, and exits the process. DEBUG
        // only; a normal launch never sees the flag.
        #if DEBUG
        if EvalHarness.isRequested {
            Task { @MainActor in
                await EvalHarness.runFromLaunchArguments()
                exit(0)
            }
            return true
        }
        // `-nudge-export-captures [path]`: write the capture-history draft
        // (`scripts/export-captures.sh`) and exit. Reads the real store,
        // writes two files in Documents, changes nothing else.
        if CaptureHistoryExporter.isRequested {
            Task { @MainActor in
                CaptureHistoryExporter.runFromLaunchArguments()
                exit(0)
            }
            return true
        }
        // `-nudge-check-calendar`: call the real calendar request and print
        // the result. A missing usage description kills the process before
        // the dialog, so one console line proves the key matches the API.
        if ProcessInfo.processInfo.arguments.contains("-nudge-check-calendar") {
            Task { @MainActor in
                let before = EKEventStore.authorizationStatus(for: .event)
                let granted = await CalendarService.shared.requestCalendarAccess()
                let after = EKEventStore.authorizationStatus(for: .event)
                print("[CalendarCheck] requestFullAccessToEvents granted=\(granted) status before=\(before.rawValue) after=\(after.rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 fullAccess, 4 writeOnly)")
                exit(0)
            }
            return true
        }
        #endif

        // ⚠️ TEMP-INTENT-AUDIT (cycle 2026-09-03-01 item 4) — every open
        // dated task predates the deadline/intent split and carries a
        // possibly-fabricated deadline. This PRINTS a proposed
        // classification and writes NOTHING; Roman reviews the table and
        // fixes rows by hand (or approves a one-shot apply in a later
        // cycle). Grep the tag to delete every trace.
        #if DEBUG
        Task { @MainActor in
            Self.tempDumpDeadlineIntentAudit()
        }
        #endif

        // ⚠️ TEMP-VISIBILITY-AUDIT (cycle 2026-09-30-01 item 4) — for every
        // open task, the Tasks-tab lists it is in under the OLD rules
        // (frozen inline here) and under `NudgeTask.lists(on:)`. The
        // before/after evidence for the day model. Grep the tag to delete.
        #if DEBUG
        Task { @MainActor in
            Self.tempDumpVisibilityAudit()
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
    // captured tasks receive. This is the one place we see the capture
    // flow's own stakes output. Sorted by source
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

    /// ⚠️ TEMP-INTENT-AUDIT — proposes deadline-vs-intent for every open
    /// dated task, WRITES NOTHING. "keep deadline" is proposed only where
    /// the row shows owed-work signals (deadline-shaped title keywords, or
    /// a generated prep/commitment row whose date IS its plan day);
    /// everything else dated is proposed as intent — the same asymmetry as
    /// capture's default, and these proposals are read by a human, not
    /// applied by code.
    @MainActor
    static func tempDumpDeadlineIntentAudit() {
        let context = SharedModelContainer.container.mainContext
        let all = ((try? context.fetch(FetchDescriptor<NudgeTask>())) ?? [])
        let dated = all
            .filter { !$0.isComplete && !$0.isInformationalEvent && $0.hasDeadline }
            .sorted { ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title) }
        print("\n── TEMP-INTENT-AUDIT · \(dated.count) open dated task(s), nothing written ──")
        let deadlineWords = ["due", "submit", "turn in", "deadline", "exam",
                             "midterm", "final", "quiz", "essay", "assignment",
                             "application", "apply by", "register", "renew"]
        for t in dated {
            let title = t.title.lowercased()
            let generated = t.source == "prep" || t.source == "commitment"
            let wordHit = deadlineWords.first { title.contains($0) }
            let proposal: String
            if generated {
                proposal = "keep deadline (generated \(t.source) row — its date is its plan day)"
            } else if let wordHit {
                proposal = "keep deadline (\"\(wordHit)\")"
            } else {
                proposal = "→ intent (no owed-work signal in the row)"
            }
            let day = t.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? "?"
            let time = t.specificTime?.formatted(date: .omitted, time: .shortened) ?? "—"
            print("  \(day) \(time)\tsrc=\(t.source)\t\(proposal)\t\(t.title)")
        }
        print("── TEMP-INTENT-AUDIT end (review by hand; no auto-apply exists) ──\n")
    }

    /// ⚠️ TEMP-VISIBILITY-AUDIT — old rules frozen here on purpose so the
    /// dump keeps meaning after the readers switch: Today = intent day ??
    /// placement day == today (a dateless plan task reads as today);
    /// Unscheduled = not a plan row, not skipped, unplaced or placed on
    /// another day; Overdue = past deadline and stakes != low; Skipped =
    /// skipped twice, undated, unplaced.
    @MainActor
    static func tempDumpVisibilityAudit() {
        let context = SharedModelContainer.container.mainContext
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let open = ((try? context.fetch(FetchDescriptor<NudgeTask>())) ?? [])
            .filter { !$0.isComplete && !$0.isInformationalEvent }
            .sorted { $0.title < $1.title }
        print("\n── TEMP-VISIBILITY-AUDIT · \(open.count) open task(s) · today \(today.formatted(date: .abbreviated, time: .omitted)) ──")
        var hiddenOld = 0, hiddenNew = 0
        for t in open {
            let oldDay = t.intendedDate.map { cal.startOfDay(for: $0) }
                ?? t.plannedStartDate.map { cal.startOfDay(for: $0) }
            let oldSkipped = !t.hasDeadline && t.linkedEventId == nil && t.commitmentShapeRaw == nil
                && t.skipCount >= NudgeTask.skipsBeforeSkippedSection && t.plannedStartDate == nil
            var old: [String] = []
            let inTodayLens = t.sequenceIndex != nil
                ? cal.isDate(oldDay ?? today, inSameDayAs: today)
                : (oldDay.map { cal.isDate($0, inSameDayAs: today) } ?? false)
            if inTodayLens { old.append("today") }
            if t.sequenceIndex == nil, !oldSkipped,
               t.plannedStartDate.map({ !cal.isDateInToday($0) }) ?? true { old.append("unscheduled") }
            if t.isOverdue, t.stakes != .low { old.append("overdue") }
            if oldSkipped { old.append("skipped") }
            let new = t.lists(on: today, now: now).sorted().map(\.rawValue)
            let aheadDay = [t.planDay, t.anchorDay].compactMap { $0 }.filter { $0 > today }.min()
            if old.isEmpty { hiddenOld += 1 }
            if new.isEmpty, aheadDay == nil { hiddenNew += 1 }
            // A row in none of TODAY's lists is in another day's lens when
            // its plan or anchor day is ahead (R1); only a row with neither
            // is truly hidden.
            let flag: String
            if old.isEmpty && !new.isEmpty {
                flag = "  ← was hidden"
            } else if new.isEmpty, let aheadDay {
                flag = "  ← in the \(aheadDay.formatted(date: .abbreviated, time: .omitted)) lens"
            } else if new.isEmpty {
                flag = "  ← STILL HIDDEN"
            } else {
                flag = ""
            }
            let due = t.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
            let plan = t.intendedDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"
            let placed = t.plannedStartDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
            print("  \(t.title)\n      due \(due) · plan \(plan) · placed \(placed) · stakes \(t.stakes?.rawValue ?? "nil") · slips \(t.skipCount)\n      OLD [\(old.joined(separator: ", "))]  NEW [\(new.joined(separator: ", "))]\(flag)")
        }
        print("  → hidden under OLD rules: \(hiddenOld)   hidden under NEW rules: \(hiddenNew)")
        print("── TEMP-VISIBILITY-AUDIT end ──\n")
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
