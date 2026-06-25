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

    /// Time the user started their first session that day
    var sessionStartTime: Date?
    /// Minutes off target bedtime (positive = late, negative = early)
    var bedtimeDeviationMinutes: Int?
    /// Minutes off target wake time (positive = late, negative = early)
    var wakeDeviationMinutes: Int?
    /// Number of sessions started that day
    var sessionCount: Int

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
        productivityScore: Int = 0,
        sessionStartTime: Date? = nil,
        bedtimeDeviationMinutes: Int? = nil,
        wakeDeviationMinutes: Int? = nil,
        sessionCount: Int = 0
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
        self.sessionStartTime = sessionStartTime
        self.bedtimeDeviationMinutes = bedtimeDeviationMinutes
        self.wakeDeviationMinutes = wakeDeviationMinutes
        self.sessionCount = sessionCount
    }

    /// Bedtime accuracy as a percentage (100% = exactly on time)
    var bedtimeAccuracy: Int? {
        guard let deviation = bedtimeDeviationMinutes else { return nil }
        let absDeviation = abs(deviation)
        // 0 min off = 100%, 60+ min off = 0%
        return max(0, 100 - Int((Double(absDeviation) / 60.0) * 100))
    }

    /// Wake time accuracy as a percentage (100% = exactly on time)
    var wakeAccuracy: Int? {
        guard let deviation = wakeDeviationMinutes else { return nil }
        let absDeviation = abs(deviation)
        return max(0, 100 - Int((Double(absDeviation) / 60.0) * 100))
    }
}
