//
//  NudgeCommitment.swift
//  Nudge
//
//  The durable anchor for an expanded commitment — the general form of the
//  role the exam EVENT plays for prep tasks (cycle 2026-08-03-01). A brain
//  dump like "testing my app, an hour a day, until Friday" captures as one
//  task; once its shape and numbers are known, `ExamPrepSweep` converts
//  that task into one of these rows plus one generated task per day
//  (`source == "commitment"`, `linkedEventId` = this row's UUID string).
//
//  The row must outlive the daily tasks it spawns, for three reasons:
//    • idempotence — the sweep keys "which days already exist" on it;
//    • tombstones — a deleted day is recorded against this ID and never
//      recreated (`PrepTombstone`, shared with exam prep);
//    • memory — answered questions persist here ("Module 4 ≈ 8 hours"),
//      so a later module of the same course is never asked again. Rows
//      are deliberately NOT purged when `endDate` passes: an expired row
//      generates nothing (the window is empty) but keeps its answer.
//
//  Registered in the THREE hand-synced schema lists
//  (`SharedModelContainer.schema`, `widgetSchema` in
//  `NudgeWidget/NudgeWidget.swift`, the `#Preview` container in
//  `ContentView.swift`) and in the widget target's `membershipExceptions`
//  in project.pbxproj — a Models file is invisible to the widget until
//  hand-added there.
//

import Foundation
import SwiftData

// MARK: - Shape

/// The three commitment shapes the capture classifier can detect. Each
/// needs different numbers before it can expand into daily tasks:
///
///   • `splitWork` — a finite body of work with a deadline ("module 4 by
///     Friday"). Needs a TOTAL effort estimate; the app divides it across
///     the days available.
///   • `rate` — a stated per-day cadence ("an hour a day"). Needs an END
///     date; a rate without one is infinite.
///   • `quantity` — a per-day count ("three applications a day"). Needs an
///     end date; each day becomes ONE task with a target count, not N
///     tasks (`NudgeTask.targetCount`).
///
/// Lowercase raw values so the tolerant `parse` survives the AI's
/// camelCase — the `TaskTimeWindow` convention.
enum CommitmentShape: String, CaseIterable, Codable, Sendable {
    case splitWork = "splitwork"
    case rate
    case quantity

    /// Tolerant parse for AI strings: trims + lowercases; unknown, empty,
    /// or nil input → nil, never a crash. Same convention as
    /// `TaskStakes.parse` / `TaskTimeWindow.parse`.
    static func parse(_ raw: String?) -> CommitmentShape? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return CommitmentShape(rawValue: key)
    }
}

// MARK: - Model

@Model
final class NudgeCommitment {
    var id: UUID
    /// The user's own phrasing from the brain dump ("Python course module
    /// 4") — generated daily tasks carry it verbatim, and the known-sizes
    /// prompt context quotes it so a matching later commitment can reuse
    /// the answer.
    var title: String
    /// Raw storage for `CommitmentShape`. Read through `shape`; unknown
    /// strings read as nil, never crash.
    var shapeRaw: String
    /// The commitment's last day (start-of-day). For `splitWork` this is
    /// the DEADLINE day (sessions stop the day before, the prep-sweep
    /// buffer-day pattern); for `rate`/`quantity` the cadence runs through
    /// this day inclusive — "an hour a day until Friday" includes Friday.
    var endDate: Date
    /// `splitWork` only: the user's total-effort answer, in minutes.
    /// THIS is the remembered answer the known-sizes context serves back.
    var totalMinutes: Int?
    /// Per-day session length in minutes: stated for `rate`, computed
    /// (total ÷ days, rounded to half-hour blocks) for `splitWork`.
    var dailyMinutes: Int?
    /// `quantity` only: units per day ("three applications" → 3).
    var dailyCount: Int?
    /// Inherited onto every generated daily task (via
    /// `setStakesFromAutomation`, same as prep).
    var stakesRaw: String?
    var category: String?
    /// Inherited appropriateness band (`TaskTimeWindow`) for placement.
    var timeWindowRaw: String?
    var createdAt: Date
    /// The capture task this row was expanded from — provenance only;
    /// that task is deleted at expansion (its daily tasks replace it).
    var sourceTaskId: UUID?

    var shape: CommitmentShape? {
        get { CommitmentShape.parse(shapeRaw) }
        set { shapeRaw = newValue?.rawValue ?? "" }
    }

    var stakes: TaskStakes? {
        get { TaskStakes.parse(stakesRaw) }
        set { stakesRaw = newValue?.rawValue }
    }

    var timeWindow: TaskTimeWindow? {
        get { TaskTimeWindow.parse(timeWindowRaw) }
        set { timeWindowRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        shape: CommitmentShape,
        endDate: Date,
        totalMinutes: Int? = nil,
        dailyMinutes: Int? = nil,
        dailyCount: Int? = nil,
        stakesRaw: String? = nil,
        category: String? = nil,
        timeWindowRaw: String? = nil,
        createdAt: Date = Date(),
        sourceTaskId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.shapeRaw = shape.rawValue
        self.endDate = endDate
        self.totalMinutes = totalMinutes
        self.dailyMinutes = dailyMinutes
        self.dailyCount = dailyCount
        self.stakesRaw = stakesRaw
        self.category = category
        self.timeWindowRaw = timeWindowRaw
        self.createdAt = createdAt
        self.sourceTaskId = sourceTaskId
    }
}
