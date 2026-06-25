//
//  CompletedTaskRecord.swift
//  Nudge
//
//  Lightweight record of a completed task. Persists in stats even after
//  the original NudgeTask is deleted from the task list.
//

import Foundation
import SwiftData

@Model
final class CompletedTaskRecord {
    var id: UUID
    var title: String
    var priority: String
    var completedAt: Date
    /// The original NudgeTask ID — used to prevent duplicate records
    var sourceTaskID: UUID

    init(
        id: UUID = UUID(),
        title: String,
        priority: String = "medium",
        completedAt: Date = Date(),
        sourceTaskID: UUID
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.completedAt = completedAt
        self.sourceTaskID = sourceTaskID
    }
}
