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
        source: String = "manual"
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
    }
}
