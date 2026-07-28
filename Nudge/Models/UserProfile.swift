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
    /// Gates the arbiter's morning prompt (formerly the fixed
    /// NotificationScheduler morning kickoff — same toggle, new machinery).
    var morningCheckInNotificationsEnabled: Bool
    var taskDueSoonNotificationsEnabled: Bool
    var deadlinePrepNotificationsEnabled: Bool
    var sessionStarterNotificationsEnabled: Bool

    /// Gates the arbiter's floater check-in (`buildFloaterCheckInCandidates`).
    /// Split out of `taskDueSoonNotificationsEnabled` in Jul 2026, alongside
    /// `NudgeOutcomeKind.floater` — that toggle gated two unrelated features,
    /// so opting out of mid-day check-ins also killed deadline-driven
    /// get-ahead nudges, the more valuable half.
    ///
    /// PROPERTY-LEVEL DEFAULT, unlike every field above it (they're assigned
    /// in `init` only). This project has no `VersionedSchema` / migration
    /// plan, so SwiftData's lightweight migration is what has to open an
    /// existing store — and a new non-optional attribute with no default
    /// makes that FAIL AT LAUNCH on any device that already has a profile
    /// row. Not a build error. Keep the default here, not just in `init`.
    var floaterCheckInNotificationsEnabled: Bool = true

    // MARK: - Quiet hours
    //
    // "When do I not want to be interrupted?" — deliberately SEPARATE from
    // the sleep schedule. `insideAwakeWindow` used to derive quiet hours
    // from `bedtime`/`wakeTime` directly, which conflated two different
    // things: a student with an 11pm bedtime who studies until 12:30 got
    // nothing after 10pm, the exact hours they were working.
    //
    // PROPERTY-LEVEL DEFAULTS, for the same reason as
    // `floaterCheckInNotificationsEnabled` above — no VersionedSchema here,
    // so a defaultless non-optional attribute fails at LAUNCH on an
    // existing store, not at build.

    /// When true (the default, and where every pre-existing store lands),
    /// quiet hours are derived from the sleep schedule exactly as before:
    /// `bedtime − preBedtimeQuietMinutes` → `wakeTime + postWakeQuietMinutes`.
    /// Behavior is unchanged for anyone who never touches the setting.
    var quietHoursFollowSleepSchedule: Bool = true

    /// Clock time quiet hours BEGIN. Only hour/minute are read; the date
    /// component is meaningless. Consumed only when
    /// `quietHoursFollowSleepSchedule` is false — and if either this or
    /// `quietHoursEndTime` is nil, the resolver falls back to the derived
    /// window rather than guessing.
    var quietHoursStartTime: Date? = nil

    /// Clock time quiet hours END. Same reading rules as
    /// `quietHoursStartTime`. May be numerically LESS than the start (the
    /// normal case — the window wraps midnight); the resolver handles that
    /// explicitly instead of collapsing.
    var quietHoursEndTime: Date? = nil

    // MARK: - Deprecated notification fields
    //
    // The fields below are kept on the model purely so SwiftData can read
    // existing stores without a migration plan — they map to no notification
    // source today. Do NOT add UI for them; do NOT consume them. If a future
    // notification kind needs a toggle, prefer adding a new field over
    // resurrecting one of these (the names are misleading at this point).

    /// Gated the retired bedtime-planning notification (removed Jul 2026).
    var eveningCheckInNotificationsEnabled: Bool
    var windDownNotificationsEnabled: Bool
    var habitReminderNotificationsEnabled: Bool
    var monthlyCheckInNotificationsEnabled: Bool
    var smartNotificationsEnabled: Bool
    var maxSmartNotificationsPerDay: Int
    /// SUPERSEDED by `quietHoursStartTime` / `quietHoursEndTime` above, and
    /// never read by anything at any point — these were written in `init`
    /// and consumed nowhere. Not reused for the Jul 2026 quiet-hours work
    /// for two reasons: `Int` hours can't express `bedtime − 60m` off a
    /// 23:30 bedtime, and every existing store already holds the init
    /// defaults (22 / 8), so consuming them would have silently CHANGED the
    /// window for every current user instead of preserving it.
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
        floaterCheckInNotificationsEnabled: Bool = true,
        quietHoursFollowSleepSchedule: Bool = true,
        quietHoursStartTime: Date? = nil,
        quietHoursEndTime: Date? = nil,
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
        self.floaterCheckInNotificationsEnabled = floaterCheckInNotificationsEnabled
        self.quietHoursFollowSleepSchedule = quietHoursFollowSleepSchedule
        self.quietHoursStartTime = quietHoursStartTime
        self.quietHoursEndTime = quietHoursEndTime
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
