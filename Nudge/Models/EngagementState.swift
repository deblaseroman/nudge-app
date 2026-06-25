//
//  EngagementState.swift
//  Nudge
//
//  Tracks user engagement metrics for the smart notification system.
//  Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class EngagementState {
    var id: UUID

    // MARK: - Session Tracking

    var lastAppOpenDate: Date?
    var lastNotificationTappedDate: Date?
    var totalAppOpens: Int
    var appOpensToday: Int
    var appOpensResetDate: Date?

    // MARK: - Streak

    var currentStreak: Int
    var longestStreak: Int
    var lastActiveDate: Date?

    // MARK: - Inactivity Escalation

    var consecutiveInactiveDays: Int
    var lastEscalationLevel: Int
    var lastEscalationDate: Date?

    // MARK: - Notification Interaction

    var notificationsSentToday: Int
    var notificationsSentResetDate: Date?
    var notificationsTappedTotal: Int
    var notificationsIgnoredTotal: Int

    // MARK: - Usage Pattern

    var preferredHours: [Int]
    var averageSessionsPerDay: Double

    // MARK: - Engagement Score

    var engagementScore: Double

    init(
        id: UUID = UUID(),
        lastAppOpenDate: Date? = nil,
        lastNotificationTappedDate: Date? = nil,
        totalAppOpens: Int = 0,
        appOpensToday: Int = 0,
        appOpensResetDate: Date? = nil,
        currentStreak: Int = 0,
        longestStreak: Int = 0,
        lastActiveDate: Date? = nil,
        consecutiveInactiveDays: Int = 0,
        lastEscalationLevel: Int = 0,
        lastEscalationDate: Date? = nil,
        notificationsSentToday: Int = 0,
        notificationsSentResetDate: Date? = nil,
        notificationsTappedTotal: Int = 0,
        notificationsIgnoredTotal: Int = 0,
        preferredHours: [Int] = [],
        averageSessionsPerDay: Double = 0,
        engagementScore: Double = 50
    ) {
        self.id = id
        self.lastAppOpenDate = lastAppOpenDate
        self.lastNotificationTappedDate = lastNotificationTappedDate
        self.totalAppOpens = totalAppOpens
        self.appOpensToday = appOpensToday
        self.appOpensResetDate = appOpensResetDate
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastActiveDate = lastActiveDate
        self.consecutiveInactiveDays = consecutiveInactiveDays
        self.lastEscalationLevel = lastEscalationLevel
        self.lastEscalationDate = lastEscalationDate
        self.notificationsSentToday = notificationsSentToday
        self.notificationsSentResetDate = notificationsSentResetDate
        self.notificationsTappedTotal = notificationsTappedTotal
        self.notificationsIgnoredTotal = notificationsIgnoredTotal
        self.preferredHours = preferredHours
        self.averageSessionsPerDay = averageSessionsPerDay
        self.engagementScore = engagementScore
    }

    // MARK: - Computed

    var engagementLevel: EngagementLevel {
        if engagementScore >= 70 { return .high }
        if engagementScore >= 40 { return .moderate }
        return .low
    }

    var daysSinceLastOpen: Int {
        guard let last = lastAppOpenDate else { return Int.max }
        return Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? Int.max
    }

    var notificationTapRate: Double {
        let total = notificationsTappedTotal + notificationsIgnoredTotal
        guard total > 0 else { return 0 }
        return Double(notificationsTappedTotal) / Double(total)
    }
}

enum EngagementLevel: String, Codable {
    case high
    case moderate
    case low
}
