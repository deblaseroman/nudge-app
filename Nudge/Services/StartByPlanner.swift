//
//  StartByPlanner.swift
//  Nudge
//
//  Deterministic replacement for `NudgeIntelligence.recommendedStartBy` —
//  computes WHEN the user should start a task in order to finish without
//  cramming, plus how many sessions it'll take and whether it qualifies
//  as deep work.
//
//  All three numbers used to come from a single LLM call that "vibed" the
//  values. Now they're functions of:
//    • `task.dueDate` (user-set / extracted at capture time)
//    • Effort estimate from `DurationModel.estimate(for:)`
//    • Task category (closed enum on `NudgeTask.taskCategory`)
//
//  Two branches inside `plan(for:)`:
//    DEEP WORK   — effort > deepWorkThresholdMinutes AND category in
//                  {exam, school, work}. Targets one session per day at
//                  `typicalDeepWorkSessionHours`, plus a buffer day so
//                  the last session isn't on the deadline itself.
//    SHALLOW     — everything else. Treats the task as single-shot and
//                  reserves `effortHours × (1 + shallowBufferMultiplier)`
//                  of lead time before the deadline.
//
//  Why deterministic? `recommendedStartBy` is the fire-time for an entire
//  class of nudges. If the AI varies its guess from day to day, the nudge
//  appears/disappears/moves and the user can't form a mental model of when
//  they'll be reminded. A formula doesn't drift.
//

import Foundation
import SwiftData

struct StartByPlan {
    let startBy: Date
    let sessionsNeeded: Int
    let isDeepWork: Bool
}

@MainActor
enum StartByPlanner {

    // MARK: - Public API

    /// Returns a plan for a dated task. `nil` when the task has no
    /// `dueDate` (floaters — handled separately by the lowPriority quadrant
    /// and the age-based promotion that lands later).
    static func plan(
        for task: NudgeTask,
        modelContext: ModelContext,
        now: Date = Date()
    ) -> StartByPlan? {
        guard let due = task.dueDate else { return nil }

        let effortMinutes = DurationModel.shared.estimate(for: task, modelContext: modelContext)
        let effortHours = Double(effortMinutes) / 60.0
        let category = task.taskCategory
        let deep = isDeepWork(category: category, effortMinutes: effortMinutes)

        let calendar = Calendar.current

        if deep {
            // Multi-session path. Aim for one session per day at the
            // typical deep-work session length; include a buffer day so
            // the LAST session doesn't sit on the deadline itself.
            let sessionLength = NudgeConfig.typicalDeepWorkSessionHours
            let sessionsNeeded = max(1, Int(ceil(effortHours / sessionLength)))
            let daysNeeded = sessionsNeeded + NudgeConfig.deepWorkBufferDays
            guard let startBy = calendar.date(byAdding: .day, value: -daysNeeded, to: due) else {
                return nil
            }
            // Clamp so the startBy never lands in the past — if the user
            // adds an exam they have 1 day for, we still want SOME nudge,
            // just immediately.
            let clamped = max(startBy, now)
            return StartByPlan(
                startBy: clamped,
                sessionsNeeded: sessionsNeeded,
                isDeepWork: true
            )
        } else {
            // Shallow / single-shot path. Reserve effort × (1 + buffer)
            // hours of lead time. A 30-minute task with shallowBufferMultiplier
            // = 1.0 gets startBy = due − 60 min.
            let totalLeadHours = effortHours * (1.0 + NudgeConfig.shallowBufferMultiplier)
            let startBy = due.addingTimeInterval(-totalLeadHours * 3600)
            let clamped = max(startBy, now)
            return StartByPlan(
                startBy: clamped,
                sessionsNeeded: 1,
                isDeepWork: false
            )
        }
    }

    /// Deterministic "is this deep work?" heuristic. Used both inside
    /// `plan(for:)` and by `NudgeArbiter` builders that need the bool to
    /// pass into `EisenhowerScorer.importance`. Step 6 may replace this
    /// with an LLM-extracted signal — until then the formula is:
    ///     deepWork = effort > threshold AND category is academic/work.
    static func isDeepWork(category: TaskCategory?, effortMinutes: Int) -> Bool {
        guard effortMinutes > NudgeConfig.deepWorkThresholdMinutes else { return false }
        switch category {
        case .exam, .school, .work: return true
        default: return false
        }
    }
}
