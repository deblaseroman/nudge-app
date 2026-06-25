//
//  NotificationEvent.swift
//  Nudge
//
//  Tracks individual notification deliveries and interactions for A/B testing.
//  Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class NotificationEvent {
    var id: UUID
    var sentDate: Date
    var notificationType: String
    var variantID: String
    var messageText: String
    var tone: String
    var wasTapped: Bool
    var tappedDate: Date?
    var wasDismissed: Bool
    var engagementLevelAtSend: String

    init(
        id: UUID = UUID(),
        sentDate: Date = Date(),
        notificationType: String,
        variantID: String,
        messageText: String,
        tone: String,
        wasTapped: Bool = false,
        tappedDate: Date? = nil,
        wasDismissed: Bool = false,
        engagementLevelAtSend: String = "moderate"
    ) {
        self.id = id
        self.sentDate = sentDate
        self.notificationType = notificationType
        self.variantID = variantID
        self.messageText = messageText
        self.tone = tone
        self.wasTapped = wasTapped
        self.tappedDate = tappedDate
        self.wasDismissed = wasDismissed
        self.engagementLevelAtSend = engagementLevelAtSend
    }
}

// MARK: - Notification Categories

enum SmartNotificationType: String, CaseIterable {
    case reminder
    case streak
    case reEngagement
    case milestone
    case urgency
}

enum NotificationTone: String, CaseIterable {
    case friendly
    case playful
    case urgent
    case reward
    case curiosity
}
