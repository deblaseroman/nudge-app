//
//  TaskStakes.swift
//  Nudge
//
//  Canonical CONSEQUENCE signal for tasks and events: how bad is it if this
//  item is missed or handled badly? Explicitly NOT urgency (the logistic
//  slack curve owns time pressure — a thing due tomorrow is not
//  automatically high stakes) and NOT category (a job interview, a doctor's
//  appointment, and a final exam are all high; nothing here is
//  school-specific).
//
//  Stored raw on `NudgeTask.stakesRaw` so an unknown string from a drifting
//  AI response or a future schema can never crash decoding — unknown maps
//  to nil, and nil means "never classified", which is the hook any later
//  backfill/upgrade pass keys on. That is why there is no catch-all case
//  like `TaskCategory.other`.
//
//  Lives in Models/ because the widget target compiles Nudge/Models/*.swift
//  and nothing else from Nudge/. Widget membership is NOT automatic for new
//  Models files: this file is listed in the widget target's
//  membershipExceptions in project.pbxproj (see ARCHITECTURE.md,
//  cross-cutting invariant 3).
//
//  Data-only for now: nothing scores, ranks, or renders stakes yet.
//  Writers all go through `NudgeTask.setStakesFromAutomation`.
//

import Foundation

enum TaskStakes: String, CaseIterable, Codable, Sendable {
    /// Missing it or handling it badly has lasting consequences: exams,
    /// job interviews, flights, medical appointments, deadlines with real
    /// penalties (rent, visa, registration), significant personal
    /// occasions.
    case high

    /// Matters but recoverable: regular assignments, work shifts, routine
    /// classes, dated errands.
    case medium

    /// Minor or optional: someday tasks, loose intentions ("read more",
    /// "clean my desk"), hobby items.
    case low

    /// Tolerant parse for AI/import strings: trims + lowercases; unknown,
    /// empty, or nil input → nil, never a crash. Follows the
    /// `NudgeTask.taskCategory` tolerance convention, except unknowns map
    /// to nil rather than a catch-all case (see header).
    static func parse(_ raw: String?) -> TaskStakes? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return TaskStakes(rawValue: key)
    }
}
