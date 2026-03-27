//
//  NudgeHabit.swift
//  Nudge
//
//  Habit model with streak tracking. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class NudgeHabit {
    var id: UUID
    var title: String
    var emoji: String
    var reminderTime: Date?
    var currentStreak: Int
    var longestStreak: Int
    var lastCompletedDate: Date?
    var isActive: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        emoji: String = "",
        reminderTime: Date? = nil,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        lastCompletedDate: Date? = nil,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.reminderTime = reminderTime
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastCompletedDate = lastCompletedDate
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
