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
    var bedtime: Date
    var wakeTime: Date?
    var dailyPhoneLimit: Int        // minutes — notification only in v1, blocking in v2
    var watchedApps: [String]       // stored now, enforced in v2
    var widgetStyle: String         // "task" | "stats" | "combined" | "companion"
    var personalityMode: Float      // 0.0 = gentle, 1.0 = blunt
    var isPro: Bool
    var trialStartDate: Date?
    var dailyMessageCount: Int
    var dailyMessageResetDate: Date?
    var onboardingComplete: Bool
    var widgetAdded: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        bedtime: Date = Calendar.current.date(from: DateComponents(hour: 23, minute: 0)) ?? Date(),
        wakeTime: Date? = nil,
        dailyPhoneLimit: Int = 120,
        watchedApps: [String] = [],
        widgetStyle: String = "task",
        personalityMode: Float = 0.5,
        isPro: Bool = false,
        trialStartDate: Date? = nil,
        dailyMessageCount: Int = 0,
        dailyMessageResetDate: Date? = nil,
        onboardingComplete: Bool = false,
        widgetAdded: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bedtime = bedtime
        self.wakeTime = wakeTime
        self.dailyPhoneLimit = dailyPhoneLimit
        self.watchedApps = watchedApps
        self.widgetStyle = widgetStyle
        self.personalityMode = personalityMode
        self.isPro = isPro
        self.trialStartDate = trialStartDate
        self.dailyMessageCount = dailyMessageCount
        self.dailyMessageResetDate = dailyMessageResetDate
        self.onboardingComplete = onboardingComplete
        self.widgetAdded = widgetAdded
    }

    /// Whether the user is currently in their 14-day trial period
    var isInTrial: Bool {
        guard let start = trialStartDate else { return false }
        return Date().timeIntervalSince(start) < 14 * 24 * 60 * 60
    }
}
