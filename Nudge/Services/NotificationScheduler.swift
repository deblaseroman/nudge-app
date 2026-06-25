//
//  NotificationScheduler.swift
//  Nudge
//
//  Owns the TWO simple repeating notifications (bedtime planning + morning
//  kickoff) and the shared UserDefaults key that tracks the most recent
//  focus-session start.
//
//  Every OTHER notification decision (event-block reminders, idle nudges,
//  get-ahead nudges, break-it-down offers, urgency-tier styling) goes
//  through NudgeArbiter. Do not add new schedulers here — extend the
//  arbiter's candidate builders instead.
//

import Foundation
import SwiftData
import UserNotifications

/// One per logical repeating notification type. Both fire at a fixed clock
/// time relative to the user's wake/bedtime. Add a case → add a switch
/// branch in `makeDescriptor` → done. Anything more dynamic belongs in
/// `NudgeArbiter`.
enum NudgeNotificationKind: String, CaseIterable {
    case bedtimePlanning
    case morningKickoff
}

@MainActor
final class NotificationScheduler {

    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let prefix = "nudge.daily."

    /// Shared UserDefaults key (App Group) used by SessionCoordinator to
    /// record when the most recent focus session started. NudgeArbiter
    /// reads it to gate discretionary nudges via the recent-activity
    /// cooldown.
    static let lastFocusSessionStartedAtKey = "nudge.lastFocusSessionStartedAt"

    private init() {}

    // MARK: - Public API

    /// Cancels any prior repeating notifications this class owns and
    /// re-registers them based on the current profile. Safe to call
    /// repeatedly — the system dedupes by identifier.
    func scheduleDailyNotifications(for profile: UserProfile) {
        cancelAll()

        guard profile.notificationsEnabled else { return }

        for kind in NudgeNotificationKind.allCases {
            // Per-kind toggle gates whether this notification participates.
            // The master `notificationsEnabled` above suppresses ALL kinds;
            // the per-kind toggle suppresses only its own.
            guard isEnabled(kind, profile: profile) else { continue }
            guard let descriptor = makeDescriptor(for: kind, profile: profile) else { continue }
            add(descriptor)
        }
    }

    private func isEnabled(_ kind: NudgeNotificationKind, profile: UserProfile) -> Bool {
        switch kind {
        case .morningKickoff:   return profile.morningCheckInNotificationsEnabled
        case .bedtimePlanning:  return profile.eveningCheckInNotificationsEnabled
        }
    }

    // MARK: - Cancel

    private func cancelAll() {
        let ids = NudgeNotificationKind.allCases.map(identifier(for:))
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Descriptors

    private struct Descriptor {
        let identifier: String
        let title: String
        let body: String
        let hour: Int
        let minute: Int
    }

    private func makeDescriptor(for kind: NudgeNotificationKind, profile: UserProfile) -> Descriptor? {
        let calendar = Calendar.current

        switch kind {
        case .bedtimePlanning:
            // 30 min before bedtime
            guard let target = calendar.date(byAdding: .minute, value: -30, to: profile.bedtime) else { return nil }
            let comps = calendar.dateComponents([.hour, .minute], from: target)
            return Descriptor(
                identifier: identifier(for: kind),
                title: "Plan tomorrow",
                body: "Do you have your tasks listed for tomorrow?",
                hour: comps.hour ?? 22,
                minute: comps.minute ?? 30
            )

        case .morningKickoff:
            // 30 min after wake time (or morningCheckInTime as fallback)
            let wake = profile.wakeTime ?? profile.morningCheckInTime
            guard let target = calendar.date(byAdding: .minute, value: 30, to: wake) else { return nil }
            let comps = calendar.dateComponents([.hour, .minute], from: target)
            return Descriptor(
                identifier: identifier(for: kind),
                title: "Good morning",
                body: "Build momentum for your day, start a session.",
                hour: comps.hour ?? 8,
                minute: comps.minute ?? 30
            )
        }
    }

    private func identifier(for kind: NudgeNotificationKind) -> String {
        "\(prefix)\(kind.rawValue)"
    }

    private func add(_ descriptor: Descriptor) {
        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.body = descriptor.body
        content.sound = .default

        var components = DateComponents()
        components.hour = descriptor.hour
        components.minute = descriptor.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: descriptor.identifier,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }
}
