//
//  CategoryDurationStats.swift
//  Nudge
//
//  One SwiftData row per `TaskCategory`. Tracks the user's own learned
//  average task duration plus a sample count. Combined with the static
//  prior from `NudgeConfig.categoryEffortPriors`, this lets
//  `DurationModel.estimate(for:)` return a number that starts from a
//  reasonable default and gets more personal as real sessions land.
//
//  Why per-category and not per-task?
//  ─────────────────────────────────
//  Per-task data is too sparse — a typical user finishes the same EXACT
//  task once. Per-category aggregates the right signal: this user takes
//  about 90 minutes on an "errand" task on average, regardless of which
//  errand. The category dictionary in NudgeConfig provides the cold-start
//  prior; this row corrects toward the user's actual behavior.
//
//  Update policy is owned by `DurationModel.record(actualMinutes:for:)` —
//  use that, never write to these fields directly from feature code.
//

import Foundation
import SwiftData

@Model
final class CategoryDurationStats {
    /// Closed-enum raw value (e.g. "school", "exam"). One row per category.
    /// Stored as a String so SwiftData can index it and so unknown rows from
    /// older versions don't crash the schema.
    var categoryRaw: String

    /// Exponentially-weighted moving average of actual session durations
    /// the user has logged for this category. Starts at 0 with sampleCount
    /// 0 — `DurationModel.estimate` falls back to the static prior when
    /// sampleCount is 0.
    var learnedMeanMinutes: Double

    /// How many real sessions have contributed to `learnedMeanMinutes`.
    /// Drives the prior-weighted shrinkage in `DurationModel.estimate`:
    /// few samples → trust the static prior more; many samples → trust
    /// the learned mean more.
    var sampleCount: Int

    /// Last time `DurationModel.record` updated this row. Currently
    /// diagnostic only; future work may decay confidence if a category
    /// hasn't been touched in months.
    var updatedAt: Date

    /// Typed view of `categoryRaw`. Unknown raw values map to `.other`.
    var category: TaskCategory {
        get { TaskCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    init(
        category: TaskCategory,
        learnedMeanMinutes: Double = 0,
        sampleCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.categoryRaw = category.rawValue
        self.learnedMeanMinutes = learnedMeanMinutes
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }
}
