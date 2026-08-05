//
//  NudgeGoal.swift
//  Nudge
//
//  Goal model. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class NudgeGoal {
    var id: UUID
    var title: String
    var emoji: String
    var frequency: String           // "daily" | "3x_week" | "weekly"
    var isActive: Bool
    var createdAt: Date
    /// When the user last actually worked on this goal — completing a task
    /// linked to it, or starting a session on one. Nil = never, and that
    /// nil is load-bearing: elapsed time then runs from `createdAt`, and
    /// copy must say "you set this a month ago", never imply a lapse that
    /// never started. Additive with a property-level default so existing
    /// stores open unchanged.
    var lastActivityAt: Date? = nil

    init(
        id: UUID = UUID(),
        title: String,
        emoji: String = "",
        frequency: String = "daily",
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.frequency = frequency
        self.isActive = isActive
        self.createdAt = createdAt
    }

    /// The one write path for goal activity. Both targets call this from
    /// their task-completion / session-start sites; keeping it here means
    /// the "only move forward" rule can't drift between them. A no-op when
    /// `goalID` is nil (the overwhelmingly common case) or dangling (the
    /// goal was removed — links are soft, by UUID).
    static func recordActivity(
        goalID: UUID?,
        at date: Date = Date(),
        in context: ModelContext
    ) {
        guard let goalID else { return }
        let descriptor = FetchDescriptor<NudgeGoal>(
            predicate: #Predicate<NudgeGoal> { $0.id == goalID }
        )
        guard let goal = try? context.fetch(descriptor).first else { return }
        // Only move forward — completing an old backlog task must not
        // rewind a goal that was worked on more recently.
        if let existing = goal.lastActivityAt, existing >= date { return }
        goal.lastActivityAt = date
        #if DEBUG
        print("[GoalActivity] \"\(goal.title)\" lastActivityAt → \(date)")
        #endif
    }
}
