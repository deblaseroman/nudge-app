//
//  TaskTimeWindow.swift
//  Nudge
//
//  Coarse "when is this task appropriate" band — the planner's answer to
//  placing "Call Grandma" at 10:30 PM. A judgment about a task's NATURE
//  (calling people happens in waking hours; studying happens whenever), so
//  the bands are deliberately coarse and few: no per-task hour ranges, no
//  invented precision. Band boundaries live in `NudgeConfig`.
//
//  This is the first field where the AI reasons about what a task *is*
//  rather than when it's due — the prerequisite errand pairing builds on.
//
//  Stored raw on `NudgeTask.timeWindowRaw` so an unknown string from a
//  drifting AI response can never crash decoding — unknown maps to nil,
//  and nil falls back to the deterministic inference, whose own fallback
//  is `.anytime`. A wrong `.anytime` is invisible; a wrong
//  `.businessHours` blocks placement — which is why the inference is
//  conservative and the unknown-input default is the loosest band.
//
//  Lives in Models/ because `NudgeTask` (widget-compiled) references it.
//  Widget membership is NOT automatic for new Models files: this file must
//  be listed in the widget target's membershipExceptions in project.pbxproj
//  (see ARCHITECTURE.md, cross-cutting invariant 3).
//

import Foundation

enum TaskTimeWindow: String, CaseIterable, Codable, Sendable {
    /// No constraint — the default and the common case. Study, reading,
    /// writing, laundry, tidying: anything doable at 11 PM without cost.
    case anytime

    /// Reasonable waking hours. Calling people, errands, chores that
    /// involve leaving the house or making noise.
    case daytime

    /// Weekday working hours. Calling an office, a bank, a doctor's front
    /// desk — anything with staff on the other end.
    /// Lowercase raw value so the tolerant lowercasing `parse` accepts the
    /// AI's camelCase "businessHours" and any casing drift.
    case businessHours = "businesshours"

    /// Tolerant parse for AI strings: trims + lowercases; unknown, empty,
    /// or nil input → nil, never a crash. Same convention as
    /// `TaskStakes.parse`.
    static func parse(_ raw: String?) -> TaskTimeWindow? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return TaskTimeWindow(rawValue: key)
    }

    /// Deterministic fallback for tasks with no classification (manual
    /// quick-adds, rows predating the field) — the `inferStakes` pattern:
    /// synchronous keyword scan, offline, no API. Conservative on purpose:
    /// `.businessHours` needs BOTH a contact word and an institution word
    /// ("call the bank", "schedule dentist appointment"), because a wrong
    /// `.businessHours` blocks placement where a wrong `.anytime` merely
    /// places freely — the failure mode we already had.
    static func infer(title: String, category: TaskCategory?) -> TaskTimeWindow {
        let t = title.lowercased()

        let contactWords = ["call", "phone", "schedule", "book", "appointment"]
        let institutionWords = [
            "bank", "doctor", "dentist", "clinic", "dmv", "insurance",
            "office", "registrar", "advisor", "pharmacy", "landlord"
        ]
        if institutionWords.contains(where: t.contains),
           contactWords.contains(where: t.contains) {
            return .businessHours
        }

        if t.contains("call") || t.contains("phone") {
            return .daytime
        }
        let errandWords = [
            "buy ", "pick up", "pickup", "drop off", "return ", "grocer",
            "store", "mail ", "ship ", "errand", "haircut", "mow", "vacuum"
        ]
        if errandWords.contains(where: t.contains) || category == .errand {
            return .daytime
        }

        return .anytime
    }
}
