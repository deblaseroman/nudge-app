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
        }
        try? modelContext.save()
        return stale.count
    }
}
