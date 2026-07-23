//
//  NotificationScheduler.swift
//  Nudge
//
//  RETIRED as a scheduler (Jul 2026). This class used to own the two fixed
//  repeating daily notifications (morning kickoff + bedtime planning),
//  registered with `repeats: true` clock triggers outside the arbiter and
//  its gates. Both are gone:
//
//    • Bedtime planning — retired outright.
//    • Morning kickoff — reborn as the arbiter's morning prompt
//      (`NudgeArbiter.buildMorningPromptCandidates`), a per-day one-shot
//      that can be suppressed when the day is already committed. A
//      repeating clock trigger fires no matter what; per-day decisions
//      require the arbiter's declarative rebuild.
//
//  What remains here:
//    1. `lastFocusSessionStartedAtKey` — the shared UserDefaults key
//       SessionCoordinator writes and the arbiter reads for the
//       recent-activity cooldown. It predates the retirement and callers
//       reference it through this type.
//    2. `cancelRetiredDailyNotifications()` — one-time cleanup. The old
//       REPEATING requests outlive the code that scheduled them: on any
//       device that ever ran the old scheduler, `nudge.daily.*` requests
//       sit in the notification center re-firing every day, and the
//       arbiter's cancelAll only removes its own `nudge.arb.` IDs. Called
//       from the same sites that used to call `scheduleDailyNotifications`
//       (ContentView launch task + the 6 AM background task) so cleanup
//       reaches devices on every path. Keep the raw ID strings even
//       though nothing schedules them anymore — they must match what old
//       builds registered.
//
//  Do not add scheduling back here — extend the arbiter's candidate
//  builders instead.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {

    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()

    /// Shared UserDefaults key (App Group) used by SessionCoordinator to
    /// record when the most recent focus session started. NudgeArbiter
    /// reads it to gate discretionary nudges via the recent-activity
    /// cooldown.
    static let lastFocusSessionStartedAtKey = "nudge.lastFocusSessionStartedAt"

    private init() {}

    /// Removes the retired fixed daily notifications registered by builds
    /// prior to Jul 2026. Safe to call repeatedly — removing a nonexistent
    /// identifier is a no-op.
    func cancelRetiredDailyNotifications() {
        center.removePendingNotificationRequests(withIdentifiers: [
            "nudge.daily.bedtimePlanning",
            "nudge.daily.morningKickoff",
        ])
    }
}
