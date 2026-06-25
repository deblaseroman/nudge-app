//
//  UserProfile.swift
//  Nudge
//
//  User profile and settings. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID
    var name: String
    var email: String
    var bedtime: Date
    var wakeTime: Date?
    var morningCheckInTime: Date
    var eveningCheckInTime: Date
    var dailyPhoneLimit: Int        // minutes — notification only in v1, blocking in v2
    var watchedApps: [String]       // stored now, enforced in v2
    var widgetStyle: String         // "task" | "stats" | "combined" | "companion"
    var personalityMode: Float      // 0.0 = gentle, 1.0 = blunt
    var coachingStyle: String
    var calendarSource: String
    var calendarImportURL: String?
    var connectedAppleCalendarID: String?
    var connectedAppleCalendarTitle: String?
    var isPro: Bool
    var trialStartDate: Date?
    var dailyMessageCount: Int
    var dailyMessageResetDate: Date?
    var onboardingComplete: Bool
    var widgetAdded: Bool
    var notificationsEnabled: Bool
    var morningCheckInNotificationsEnabled: Bool
    var taskDueSoonNotificationsEnabled: Bool
    var eveningCheckInNotificationsEnabled: Bool
    var deadlinePrepNotificationsEnabled: Bool
    var sessionStarterNotificationsEnabled: Bool

    // MARK: - Deprecated notification fields
    //
    // The fields below are kept on the model purely so SwiftData can read
    // existing stores without a migration plan — they map to no notification
    // source today. Do NOT add UI for them; do NOT consume them. If a future
    // notification kind needs a toggle, prefer adding a new field over
    // resurrecting one of these (the names are misleading at this point).
    var windDownNotificationsEnabled: Bool
    var habitReminderNotificationsEnabled: Bool
    var monthlyCheckInNotificationsEnabled: Bool
    var smartNotificationsEnabled: Bool
    var maxSmartNotificationsPerDay: Int
    var quietHoursStart: Int
    var quietHoursEnd: Int
    var streakNotificationsEnabled: Bool
    var reEngagementNotificationsEnabled: Bool
    var milestoneNotificationsEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        email: String = "",
        bedtime: Date = Calendar.current.date(from: DateComponents(hour: 23, minute: 0)) ?? Date(),
        wakeTime: Date? = nil,
        morningCheckInTime: Date = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date(),
        eveningCheckInTime: Date = Calendar.current.date(from: DateComponents(hour: 21, minute: 30)) ?? Date(),
        dailyPhoneLimit: Int = 120,
        watchedApps: [String] = [],
        widgetStyle: String = "task",
        personalityMode: Float = 0.5,
        coachingStyle: String = "assistant",
        calendarSource: String = "",
        calendarImportURL: String? = nil,
        connectedAppleCalendarID: String? = nil,
        connectedAppleCalendarTitle: String? = nil,
        isPro: Bool = false,
        trialStartDate: Date? = nil,
        dailyMessageCount: Int = 0,
        dailyMessageResetDate: Date? = nil,
        onboardingComplete: Bool = false,
        widgetAdded: Bool = false,
        notificationsEnabled: Bool = true,
        morningCheckInNotificationsEnabled: Bool = true,
        taskDueSoonNotificationsEnabled: Bool = true,
        eveningCheckInNotificationsEnabled: Bool = true,
        windDownNotificationsEnabled: Bool = true,
        habitReminderNotificationsEnabled: Bool = true,
        monthlyCheckInNotificationsEnabled: Bool = true,
        deadlinePrepNotificationsEnabled: Bool = true,
        sessionStarterNotificationsEnabled: Bool = true,
        smartNotificationsEnabled: Bool = true,
        maxSmartNotificationsPerDay: Int = 3,
        quietHoursStart: Int = 22,
        quietHoursEnd: Int = 8,
        streakNotificationsEnabled: Bool = true,
        reEngagementNotificationsEnabled: Bool = true,
        milestoneNotificationsEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.bedtime = bedtime
        self.wakeTime = wakeTime
        self.morningCheckInTime = morningCheckInTime
        self.eveningCheckInTime = eveningCheckInTime
        self.dailyPhoneLimit = dailyPhoneLimit
        self.watchedApps = watchedApps
        self.widgetStyle = widgetStyle
        self.personalityMode = personalityMode
        self.coachingStyle = coachingStyle
        self.calendarSource = calendarSource
        self.calendarImportURL = calendarImportURL
        self.connectedAppleCalendarID = connectedAppleCalendarID
        self.connectedAppleCalendarTitle = connectedAppleCalendarTitle
        self.isPro = isPro
        self.trialStartDate = trialStartDate
        self.dailyMessageCount = dailyMessageCount
        self.dailyMessageResetDate = dailyMessageResetDate
        self.onboardingComplete = onboardingComplete
        self.widgetAdded = widgetAdded
        self.notificationsEnabled = notificationsEnabled
        self.morningCheckInNotificationsEnabled = morningCheckInNotificationsEnabled
        self.taskDueSoonNotificationsEnabled = taskDueSoonNotificationsEnabled
        self.eveningCheckInNotificationsEnabled = eveningCheckInNotificationsEnabled
        self.windDownNotificationsEnabled = windDownNotificationsEnabled
        self.habitReminderNotificationsEnabled = habitReminderNotificationsEnabled
        self.monthlyCheckInNotificationsEnabled = monthlyCheckInNotificationsEnabled
        self.deadlinePrepNotificationsEnabled = deadlinePrepNotificationsEnabled
        self.sessionStarterNotificationsEnabled = sessionStarterNotificationsEnabled
        self.smartNotificationsEnabled = smartNotificationsEnabled
        self.maxSmartNotificationsPerDay = maxSmartNotificationsPerDay
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.streakNotificationsEnabled = streakNotificationsEnabled
        self.reEngagementNotificationsEnabled = reEngagementNotificationsEnabled
        self.milestoneNotificationsEnabled = milestoneNotificationsEnabled
    }

    /// Whether the user is currently in their 14-day trial period
    var isInTrial: Bool {
        guard let start = trialStartDate else { return false }
        return Date().timeIntervalSince(start) < 14 * 24 * 60 * 60
    }
}
