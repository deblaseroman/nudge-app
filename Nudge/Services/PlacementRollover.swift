//
//  PlacementRollover.swift
//  Nudge
//
//  Day-rollover sweep: keeps I3 of the day model (a plan is today-or-later).
//

import Foundation
import SwiftData

/// The day-rollover sweep (cycle 2026-09-30-01, the day model).
///
/// A placement time before today is cleared, MANUAL placements included —
/// a slot belongs to one day, and rolling a manual slot forward would be
/// the app re-asserting a plan the user made for a different day. A plan
/// DAY before today slips: the first slip re-plans the task for today
/// (Roman's one retry, Sep 16 2026), the second releases it to Unscheduled
/// where its slip count shows. Every open task counts, owed or not; a task
/// is never left in no list (the shape this sweep was born to end — an
/// unfinished task placed yesterday used to match no section and vanish at
/// midnight). Completed tasks lose their past plan too; it is inert.
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
        // I3: a plan is today-or-later. A time earlier than today is
        // cleared (manual included — a slot belongs to one day). A plan
        // DAY earlier than today slips: the first slip re-plans the task
        // for today (Roman's one retry, Sep 16 2026), the second releases
        // it to Unscheduled, where its slip count shows. Every open task,
        // owed or not (owed ones also sit in Overdue — R3 overlap).
        // Generated rows keep their own rules: prep sessions above,
        // commitment dailies carry over and are never counted.
        // `??` keeps unplanned rows out at the store level; `.distantFuture`
        // can never be `< startOfToday`.
        let farFuture = Date.distantFuture
        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                (task.plannedStartDate ?? farFuture) < startOfToday
                    || (task.intendedDate ?? farFuture) < startOfToday
            }
        )
        let stale = (try? modelContext.fetch(descriptor)) ?? []

        // Legacy: a plan item captured before cycle 2026-09-30-01 with no
        // plan day read as "today" on the read side. Give it the day.
        let openPlanDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                !task.isComplete && !task.isInformationalEvent
                    && task.sequenceIndex != nil && task.intendedDate == nil
            }
        )
        let datelessPlan = (try? modelContext.fetch(openPlanDescriptor)) ?? []
        for task in datelessPlan { task.setPlanDay(startOfToday) }

        guard !stale.isEmpty else {
            if !datelessPlan.isEmpty { try? modelContext.save() }
            return 0
        }

        #if DEBUG
        print("🧹 PlacementRollover — \(stale.count) task(s) with a plan before today:")
        #endif
        for task in stale {
            let staleTime = task.plannedStartDate.map { $0 < startOfToday } ?? false
            let stalePlanDay = task.planDay.map { $0 < startOfToday } ?? false
            #if DEBUG
            let placed = task.plannedStartDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            let plan = task.planDay?.formatted(date: .abbreviated, time: .omitted) ?? "—"
            print("   • \(task.title) [plan \(plan), placed \(placed), \(task.isComplete ? "complete" : "open")]")
            #endif
            if staleTime { task.clearPlanTime() }
            guard stalePlanDay else { continue }
            guard !task.isComplete, task.countsSlips else {
                // Complete, or a generated row with its own rules: the
                // past day is history, nothing to re-plan.
                if task.isComplete { task.intendedDate = nil }
                continue
            }
            task.skipCount += 1
            if task.skipCount < NudgeConfig.skipsBeforeSkippedSection {
                task.setPlanDay(startOfToday)
            } else {
                task.clearPlan()
            }
            #if DEBUG
            print("   ↳ slip \(task.skipCount) → \(task.planDay == nil ? "released to Unscheduled" : "re-planned for today, once")")
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
