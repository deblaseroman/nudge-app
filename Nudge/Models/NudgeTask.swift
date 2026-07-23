//
//  NudgeTask.swift
//  Nudge
//
//  Core task model. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class NudgeTask {
    var id: UUID
    var title: String
    var dueDate: Date?
    var dueTime: String?            // "morning" | "afternoon" | "evening" | "specific"
    var specificTime: Date?
    var priority: String            // "high" | "medium" | "low"
    var category: String?           // "school" | "health" | "personal" | "work"
    var isComplete: Bool
    var completedAt: Date?
    var nudgeInsight: String?       // cached once, never regenerated
    var insightGeneratedAt: Date?
    var createdAt: Date
    var source: String              // "manual" | "capture" | "calendar" | "screenshot"
    var estimatedMinutes: Int?      // AI-estimated duration for time blocking
    var recurrence: String?         // "daily" | "weekly" | "monthly" — nil means one-off
    var linkedEventId: String?      // links to a calendar event that spawned this task
    var dependsOnTaskId: UUID?      // optional dependency — this task blocked by another
    var isInformationalEvent: Bool

    /// Where the user has PLACED this task on today's horizontal timeline.
    /// Independent of `dueDate`/`specificTime` (which represent the deadline
    /// and must not change when a task is placed). Nil = unscheduled.
    var plannedStartDate: Date?
    /// How long the placed block should span on the timeline, in minutes.
    /// Nil falls back to `estimatedMinutes`, then a default.
    var plannedDurationMinutes: Int?
    /// True when the placement was created by "Plan my day" (auto), false
    /// when the user placed it manually. Lets "Clear plan" remove only the
    /// auto placements and keep manual ones.
    var plannedIsAuto: Bool = false

    /// Position (1-based) in an ordered "Today's plan" captured from the
    /// brain dump ("first X, then Y…"). Nil means the task is NOT part of an
    /// ordered plan. Independent of the timeline — a plan is a numbered,
    /// reorderable list, not a placement.
    var sequenceIndex: Int?

    /// Canonical consequence signal — raw storage for `TaskStakes`
    /// ("high" | "medium" | "low"). Nil = never classified, which is what
    /// a later backfill pass keys on. Read through `stakes`; unknown
    /// strings read as nil, never crash. Deliberately NOT part of the
    /// memberwise init: every automated writer must go through
    /// `setStakesFromAutomation` so the user-override guard below cannot
    /// be bypassed.
    var stakesRaw: String? = nil
    /// True once the user has set stakes by hand (manual editor — not
    /// built yet). While set, `setStakesFromAutomation` is a no-op, so no
    /// AI or import pass can clobber the user's choice. Only user-driven
    /// UI may write `stakes` directly, and it must set this flag too.
    var stakesIsUserSet: Bool = false

    init(
        id: UUID = UUID(),
        title: String,
        dueDate: Date? = nil,
        dueTime: String? = nil,
        specificTime: Date? = nil,
        priority: String = "medium",
        category: String? = nil,
        isComplete: Bool = false,
        completedAt: Date? = nil,
        nudgeInsight: String? = nil,
        insightGeneratedAt: Date? = nil,
        createdAt: Date = Date(),
        source: String = "manual",
        estimatedMinutes: Int? = nil,
        recurrence: String? = nil,
        linkedEventId: String? = nil,
        dependsOnTaskId: UUID? = nil,
        isInformationalEvent: Bool = false,
        plannedStartDate: Date? = nil,
        plannedDurationMinutes: Int? = nil,
        plannedIsAuto: Bool = false,
        sequenceIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.specificTime = specificTime
        self.priority = priority
        self.category = category
        self.isComplete = isComplete
        self.completedAt = completedAt
        self.nudgeInsight = nudgeInsight
        self.insightGeneratedAt = insightGeneratedAt
        self.createdAt = createdAt
        self.source = source
        self.estimatedMinutes = estimatedMinutes
        self.recurrence = recurrence
        self.linkedEventId = linkedEventId
        self.dependsOnTaskId = dependsOnTaskId
        self.isInformationalEvent = isInformationalEvent
        self.plannedStartDate = plannedStartDate
        self.plannedDurationMinutes = plannedDurationMinutes
        self.plannedIsAuto = plannedIsAuto
        self.sequenceIndex = sequenceIndex
    }

    /// Typed view of `category` for scoring code. Reads the underlying
    /// free-text string, lowercases it, and maps via `TaskCategory.rawValue`.
    /// Unknown strings → `.other`. `nil` category → `nil`.
    ///
    /// Writes round-trip back to the underlying String storage so existing
    /// SwiftData rows continue to behave as-is. Use this accessor whenever
    /// downstream code needs to switch on category — `category` itself stays
    /// as the canonical write field for compatibility with older call sites.
    var taskCategory: TaskCategory? {
        get {
            guard let key = category?.lowercased(), !key.isEmpty else { return nil }
            return TaskCategory(rawValue: key) ?? .other
        }
        set { category = newValue?.rawValue }
    }

    /// Typed view of `stakesRaw`. Unknown or empty strings → nil (unlike
    /// `taskCategory`, there is no catch-all case — nil means "never
    /// classified" and later passes rely on that). The setter is for
    /// user-driven editors only; automated writers use
    /// `setStakesFromAutomation`.
    var stakes: TaskStakes? {
        get { TaskStakes.parse(stakesRaw) }
        set { stakesRaw = newValue?.rawValue }
    }

    /// The single write path for every NON-USER stakes writer — the
    /// brain-dump classifier, the screenshot import, the deterministic
    /// calendar-import fallback, and any future backfill/upgrade pass.
    /// Refuses to overwrite a hand-set value (`stakesIsUserSet`), and
    /// treats nil as "the classifier didn't say" (keeps the current
    /// value) rather than a clear.
    func setStakesFromAutomation(_ newValue: TaskStakes?) {
        guard !stakesIsUserSet else { return }
        guard let newValue else { return }
        stakesRaw = newValue.rawValue
    }
}
