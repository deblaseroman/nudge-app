//
//  DurationModel.swift
//  Nudge
//
//  Deterministic, on-device replacement for the LLM-vibed effort estimate
//  that used to live in `NudgeIntelligence`. Combines a static per-category
//  prior with the user's own learned mean (stored in
//  `CategoryDurationStats`) using prior-weighted shrinkage.
//
//  Why deterministic? `EisenhowerScorer.urgency` is a function of
//  `effortHoursRemaining`. A wrong effort estimate makes EVERY urgency
//  reading wrong. A determining method that learns from actuals is more
//  trustworthy AND drift-free than an LLM that might score the same task
//  differently on different days.
//
//  Wire-up:
//  ─ `estimate(for:modelContext:)` is called from `NudgeArbiter` when
//    building idle and get-ahead candidates.
//  ─ `record(actualMinutes:for:modelContext:)` is called from
//    `SessionCoordinator.completeCurrentTask` (wired in step 7) every time
//    a real session ends with a finished task. The mean updates via EWMA.
//
//  Cold-start path:
//  ─ No `CategoryDurationStats` row → return `NudgeConfig.categoryEffortPriors[cat]`.
//  ─ Row exists with sampleCount = 0 → same as no row.
//  ─ Row with samples → prior-weighted blend (see `estimate` docs).
//

import Foundation
import SwiftData

@MainActor
final class DurationModel {

    static let shared = DurationModel()
    private init() {}

    // MARK: - Estimate
    //
    // Returns an effort estimate in MINUTES. Resolution order:
    //   1. `task.estimatedMinutes` if set — explicit per-task override
    //      (user input or screenshot import). Always wins.
    //   2. Per-category learned mean blended with the static prior:
    //         estimate = (prior * priorWeight + learnedMean * sampleCount)
    //                  / (priorWeight + sampleCount)
    //      With priorWeight = 5: 1 sample still trusts the prior 5×,
    //      ~20 samples lets learning fully take over.
    //   3. Cold start (no row, no samples): static prior from
    //      `NudgeConfig.categoryEffortPriors`.
    //   4. No category at all: `NudgeConfig.defaultEffortPriorMinutes`.

    func estimate(for task: NudgeTask, modelContext: ModelContext) -> Int {
        // 1. Explicit override wins.
        if let explicit = task.estimatedMinutes, explicit > 0 {
            return explicit
        }

        let category = task.taskCategory
        let prior = Double(priorMinutes(for: category))

        // 2 & 3. Look up the user's learned row (if any).
        guard
            let category,
            let stats = fetchStats(category: category, modelContext: modelContext),
            stats.sampleCount > 0
        else {
            return Int(prior.rounded())
        }

        // Prior-weighted shrinkage.
        let n = Double(stats.sampleCount)
        let w = NudgeConfig.durationPriorWeight
        let blended = (prior * w + stats.learnedMeanMinutes * n) / (w + n)
        return Int(blended.rounded())
    }

    // MARK: - Record
    //
    // EWMA update with `NudgeConfig.durationLearningAlpha`. The first
    // sample seeds the mean directly; subsequent samples blend.
    //
    // `actualMinutes` should be the WALL-CLOCK minutes of focused work on
    // a task that the user marked complete. Don't call this with partial
    // sessions — partial data biases the mean downward.

    func record(
        actualMinutes: Int,
        for category: TaskCategory,
        modelContext: ModelContext
    ) {
        guard actualMinutes > 0 else { return }

        let stats = fetchStats(category: category, modelContext: modelContext)
            ?? makeStats(for: category, modelContext: modelContext)

        let sample = Double(actualMinutes)
        if stats.sampleCount == 0 {
            stats.learnedMeanMinutes = sample
        } else {
            let alpha = NudgeConfig.durationLearningAlpha
            stats.learnedMeanMinutes = (1 - alpha) * stats.learnedMeanMinutes + alpha * sample
        }
        stats.sampleCount += 1
        stats.updatedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Internal helpers

    private func priorMinutes(for category: TaskCategory?) -> Int {
        guard let category else { return NudgeConfig.defaultEffortPriorMinutes }
        return NudgeConfig.categoryEffortPriors[category] ?? NudgeConfig.defaultEffortPriorMinutes
    }

    private func fetchStats(
        category: TaskCategory,
        modelContext: ModelContext
    ) -> CategoryDurationStats? {
        let raw = category.rawValue
        let descriptor = FetchDescriptor<CategoryDurationStats>(
            predicate: #Predicate<CategoryDurationStats> { $0.categoryRaw == raw }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func makeStats(
        for category: TaskCategory,
        modelContext: ModelContext
    ) -> CategoryDurationStats {
        let stats = CategoryDurationStats(category: category)
        modelContext.insert(stats)
        return stats
    }
}
