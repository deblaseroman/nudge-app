//
//  PlacementRollover.swift
//  Nudge
//
//  Day-rollover sweep for stale timeline placements.
//

import Foundation
import SwiftData

/// Clears timeline placements whose day has passed.
///
/// A placement (`plannedStartDate`) is a slot on a SPECIFIC day's timeline,
/// and nothing else ever resets one: `clearPlan()` touches only TODAY'S auto
/// placements, and both planners skip any task that is already placed. So an
/// unfinished task placed yesterday matched no list section — Unscheduled
/// requires `plannedStartDate == nil`, Scheduled requires `isDateInToday` —
/// drew nowhere on the timeline, and was invisible to both planners. It
/// silently vanished at midnight.
///
/// The rule: a placement dated before today is meaningless, so it is cleared
/// — MANUAL placements included. Rolling a manual placement forward would be
/// the app re-asserting a plan the user made for a different day; dropping
/// the task back to Unscheduled makes it visible again and lets the user (or
/// a planner) decide where it goes today. Completed tasks are swept too:
/// their stale placements are inert everywhere, and sweeping them keeps the
/// invariant simple — a non-nil placement is always today-or-later.
/// Missed app-made sessions (Roman, Sep 21 2026): a study session the app
/// built and the user did not do is neither rescheduled nor skipped; it is
/// counted as missed for the Stats page and removed. App-group defaults,
/// JSON `[dayStamp: [title]]`, pruned past `retentionDays`.
enum MissedSessionLog {
    static let key = "nudge.missedSessions"
    static let retentionDays = 60

    static func all() -> [String: [String]] {
        let defaults = SharedModelContainer.appGroupDefaults
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return decoded
    }

    static func record(title: String, day: Date, now: Date = Date()) {
        var log = all()
        let stamp = ExamPrepSweep.stamp(Calendar.current.startOfDay(for: day))
        log[stamp, default: []].append(title)
        // Prune.
        if let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) {
            let cutoffStamp = ExamPrepSweep.stamp(Calendar.current.startOfDay(for: cutoff))
            log = log.filter { $0.key >= cutoffStamp }
        }
        if let data = try? JSONEncoder().encode(log) {
            SharedModelContainer.appGroupDefaults.set(data, forKey: key)
        }
    }

    /// Missed sessions on or after `start` (by the session's own day).
    static func count(since start: Date) -> Int {
        let startStamp = ExamPrepSweep.stamp(Calendar.current.startOfDay(for: start))
        return all().filter { $0.key >= startStamp }.values.reduce(0) { $0 + $1.count }
    }
}

@MainActor
enum PlacementRollover {
    /// Clears every placement dated before today's start. Returns how many
    /// tasks were touched. Runs from `ContentView` on cold launch and on
    /// background→foreground — the practical equivalent of "at midnight",
    /// since iOS can't run code while the app is suspended. Runs BEFORE the
    /// arbiter's reevaluate at both call sites, so the arbiter never builds
    /// against placements this sweep is about to clear.
    @discardableResult
    static func sweep(modelContext: ModelContext, now: Date = Date()) -> Int {
        let startOfToday = Calendar.current.startOfDay(for: now)
        let missed = sweepMissedSessions(modelContext: modelContext, startOfToday: startOfToday, now: now)
        _ = missed
        // `??` keeps unplaced rows out at the store level; `.distantFuture`
        // can never be `< startOfToday`.
        let farFuture = Date.distantFuture
        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                (task.plannedStartDate ?? farFuture) < startOfToday
            }
        )
        let stale = (try? modelContext.fetch(descriptor)) ?? []
        guard !stale.isEmpty else { return 0 }

        #if DEBUG
        print("🧹 PlacementRollover — \(stale.count) stale placement(s):")
        for task in stale {
            let day = task.plannedStartDate?.formatted(date: .abbreviated, time: .shortened) ?? "?"
            let kind = task.plannedIsAuto ? "auto" : "manual"
            let visibility = task.isComplete
                ? "complete, placement inert"
                : "OPEN — was in no list section"
            print("   • \(task.title) [\(kind), placed \(day)] \(visibility) → Unscheduled")
        }
        #endif

        for task in stale {
            task.plannedStartDate = nil
            task.plannedDurationMinutes = nil
            task.plannedIsAuto = false

            // The Skipped rule (Roman, Sep 16 2026): a single no-due-date
            // task that sat on a day and was not finished is skipped. The
            // first skip reschedules it once, as today's floater; the
            // second moves it to the Skipped section (intent released, so
            // it leaves the day lists). Subtasks of an anchored thing and
            // owed work are cleared as before and never counted.
            guard !task.isComplete, task.isSkipCandidate else { continue }
            task.skipCount += 1
            if task.skipCount < NudgeConfig.skipsBeforeSkippedSection {
                task.intendedDate = startOfToday
            } else {
                task.intendedDate = nil
            }
            #if DEBUG
            print("   ↳ \(task.title): skip \(task.skipCount) → \(task.isSkipped ? "Skipped section" : "rescheduled to today, once")")
            #endif
        }
        try? modelContext.save()
        return stale.count
    }

    /// App-made study sessions whose own day has passed without being done
    /// (Roman, Sep 21 2026): not rescheduled, not skipped, not left in any
    /// list. Each is tombstoned (so a later Yes never recreates that day),
    /// counted in `MissedSessionLog` for the Stats page, and deleted.
    /// Applies to `source == "prep"` only: commitment dailies are the
    /// user's own instruction and keep their carry-over rules.
    @discardableResult
    private static func sweepMissedSessions(modelContext: ModelContext, startOfToday: Date, now: Date) -> Int {
        let prepSource = "prep"
        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete && $0.source == prepSource }
        )
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        var removed = 0
        for session in sessions {
            guard let own = session.dueDate ?? session.intendedDate,
                  Calendar.current.startOfDay(for: own) < startOfToday else { continue }
            ExamPrepSweep.recordDeletionIfGenerated(session, modelContext: modelContext)
            MissedSessionLog.record(title: session.title, day: own, now: now)
            modelContext.delete(session)
            removed += 1
            #if DEBUG
            print("🧹 PlacementRollover — missed session \"\(session.title)\" (\(ExamPrepSweep.stamp(own))): counted in Stats, removed, tombstoned")
            #endif
        }
        if removed > 0 { try? modelContext.save() }
        return removed
    }
}
