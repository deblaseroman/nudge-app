//
//  TaskCategory.swift
//  Nudge
//
//  Closed set of task categories. Replaces the free-text `NudgeTask.category`
//  for all SCORING code paths — the underlying storage stays String for
//  source compatibility, but read sites that drive importance / quadrant
//  routing go through `NudgeTask.taskCategory` which maps to this enum.
//
//  Raw values match the strings the rest of the app has been writing
//  ("school", "work", "health", "personal") so existing data round-trips
//  without a SwiftData migration. New cases ("exam", "errand", "other")
//  are additive — unknown strings map to `.other`.
//

import Foundation

enum TaskCategory: String, CaseIterable, Codable, Hashable {
    /// Exam, midterm, final, quiz — anything where a single graded event
    /// caps the work. Highest importance prior because the cost of missing
    /// it is concentrated and irreversible.
    case exam

    /// Coursework that isn't an exam: assignments, problem sets, readings,
    /// lab reports, papers in progress.
    case school

    /// Job/career tasks: shifts, deliverables, interview prep, work
    /// projects. Distinct from `.school` because the time pressure pattern
    /// and the "cost of dropping" differ.
    case work

    /// Doctor, gym, therapy, medication, sleep — anything where dropping
    /// it has compounding downstream cost on functioning.
    case health

    /// Personal life: friends, family, hobbies, household routines.
    case personal

    /// Quick utilitarian tasks: pick up X, return Y, pay Z. Low importance
    /// prior because dropping one is rarely high-stakes.
    case errand

    /// Fallback for anything that doesn't fit a closed bucket OR for
    /// strings written before the enum existed that don't match a known
    /// raw value. Carries the default importance prior.
    case other
}
