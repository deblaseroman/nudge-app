//
//  TaskIntelligence.swift
//  Nudge
//
//  Cached output of the per-task LLM signal extractor. The model used to
//  hold a dozen AI-vibed numbers — effort, cognitive load, session count,
//  recommended start-by — that drove the scorer directly. Those moved to
//  deterministic Swift services (`DurationModel`, `StartByPlanner`,
//  `EisenhowerScorer`) once we accepted that AI estimates of numbers drift
//  and aren't auditable.
//
//  What survives here is the part LLMs are genuinely good at: pulling
//  linguistic signal from the task title.
//
//    • `statedUrgency` — did the user write "urgent", "asap", "due
//      tomorrow", etc? Feeds `EisenhowerScorer.importance(...)` as a
//      +0.25 bump.
//    • `suggestedFirstStep` — a tiny concrete action ("Open the doc and
//      write one sentence") that lowers activation energy. Used in
//      `CountdownLabel` and the under-3-hour state in the editor.
//
//  Always check `analyzedAt` against `NudgeConfig.intelligenceCacheDays`
//  before assuming the row is current.
//

import Foundation
import SwiftData

@Model
final class TaskIntelligence {
    /// FK to NudgeTask.id. Not a SwiftData relationship — tasks can be
    /// deleted before their signals row is, so we hold a UUID.
    var taskID: UUID

    /// Raw value of `StatedUrgency`. Stored as String so an unknown value
    /// from a future schema doesn't crash decoding.
    var statedUrgencyRaw: String

    /// Concrete first action to lower activation energy. Never longer than
    /// ~80 chars; falls back to a generic phrase when the AI is unreachable.
    var suggestedFirstStep: String

    /// When the row was last produced. Compared against
    /// `NudgeConfig.intelligenceCacheDays` to decide if a refresh is due.
    var analyzedAt: Date

    /// Typed view of `statedUrgencyRaw`. Unknown values map to `.none`.
    var statedUrgency: StatedUrgency {
        get { StatedUrgency(rawValue: statedUrgencyRaw) ?? .none }
        set { statedUrgencyRaw = newValue.rawValue }
    }

    init(
        taskID: UUID,
        statedUrgency: StatedUrgency = .none,
        suggestedFirstStep: String = "Open it and read the first line.",
        analyzedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.statedUrgencyRaw = statedUrgency.rawValue
        self.suggestedFirstStep = suggestedFirstStep
        self.analyzedAt = analyzedAt
    }
}
