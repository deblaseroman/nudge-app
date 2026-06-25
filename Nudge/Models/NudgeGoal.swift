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
}
