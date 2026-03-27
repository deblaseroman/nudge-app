//
//  DailyStats.swift
//  Nudge
//
//  Daily productivity stats. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class DailyStats {
    var id: UUID
    var date: Date
    var tasksCompleted: Int
    var tasksTotal: Int
    var goalsHit: Int
    var goalsTotal: Int
    var habitsCompleted: Int
    var habitsTotal: Int
    var screenTimeMinutes: Int
    var productivityScore: Int

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        tasksCompleted: Int = 0,
        tasksTotal: Int = 0,
        goalsHit: Int = 0,
        goalsTotal: Int = 0,
        habitsCompleted: Int = 0,
        habitsTotal: Int = 0,
        screenTimeMinutes: Int = 0,
        productivityScore: Int = 0
    ) {
        self.id = id
        self.date = date
        self.tasksCompleted = tasksCompleted
        self.tasksTotal = tasksTotal
        self.goalsHit = goalsHit
        self.goalsTotal = goalsTotal
        self.habitsCompleted = habitsCompleted
        self.habitsTotal = habitsTotal
        self.screenTimeMinutes = screenTimeMinutes
        self.productivityScore = productivityScore
    }
}
