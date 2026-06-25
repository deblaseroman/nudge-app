//
//  SentNotificationFlag.swift
//  Nudge
//
//  Local audit log for the smart notification system. One row per
//  notification we've scheduled, so we can detect "already sent" and avoid
//  duplicate notifications across recalculations.
//

import Foundation
import SwiftData

@Model
final class SentNotificationFlag {
    /// Stable identifier — matches the UNNotificationRequest identifier so
    /// pending cancellations and log lookups stay in sync.
    var notificationID: String

    /// When the notification was scheduled.
    var scheduledAt: Date

    /// When the notification is supposed to fire.
    var fireDate: Date

    /// "event" or "task" — coarse category for filtering / debugging.
    var kind: String

    init(
        notificationID: String,
        scheduledAt: Date = Date(),
        fireDate: Date,
        kind: String
    ) {
        self.notificationID = notificationID
        self.scheduledAt = scheduledAt
        self.fireDate = fireDate
        self.kind = kind
    }
}
