//
//  NudgeNotificationCategories.swift
//  Nudge
//
//  UNNotificationCategory + action definitions. Every notification the
//  arbiter emits uses one of these category IDs so the user can act from
//  the lock screen / banner without opening the app.
//

import Foundation
import UserNotifications

enum NudgeNotificationCategoryID: String {
    case eventBlock = "category.event"
    case idle       = "category.idle"
    case getAhead   = "category.getAhead"
    case breakDown  = "category.breakDown"
    /// Morning prompt — no action buttons on purpose: the whole
    /// interaction is "tap → land in Home chat → type your answer".
    /// A future banner-reply (UNTextInputNotificationAction) would
    /// attach here.
    case morningPrompt = "category.morning"
}

enum NudgeNotificationActionID: String {
    case startSession = "action.startSession"
    case snooze30     = "action.snooze30"
    case breakItDown  = "action.breakItDown"
    // Idle "Checking in" notification — yes/no answer to the question
    // "Have you gotten started on anything today?"
    case idleYesGood  = "action.idleYesGood"
    case idleNotYet   = "action.idleNotYet"
}

/// Keys for fields stuffed into a UNNotificationRequest's userInfo. The
/// system delegate uses them to deep-link into the right task / behavior.
enum NudgeNotificationUserInfoKey {
    // `nonisolated` so the `nonisolated` UN delegate methods in
    // `NudgeNotificationService` can read these string keys without hopping
    // through MainActor — Swift 6 otherwise infers static lets as MainActor.
    nonisolated static let taskID = "taskID"
    nonisolated static let kind   = "kind"
}

@MainActor
enum NudgeNotificationCategories {
    /// Registers every category + its action buttons with the system.
    /// Call this once at app launch.
    static func registerAll() {
        let startSession = UNNotificationAction(
            identifier: NudgeNotificationActionID.startSession.rawValue,
            title: "Start session",
            options: [.foreground]
        )
        let snooze30 = UNNotificationAction(
            identifier: NudgeNotificationActionID.snooze30.rawValue,
            title: "Snooze 30 min",
            options: []
        )
        let breakItDown = UNNotificationAction(
            identifier: NudgeNotificationActionID.breakItDown.rawValue,
            title: "Break it down",
            options: [.foreground]
        )
        let idleYesGood = UNNotificationAction(
            identifier: NudgeNotificationActionID.idleYesGood.rawValue,
            title: "Yes, I'm good",
            options: []
        )
        let idleNotYet = UNNotificationAction(
            identifier: NudgeNotificationActionID.idleNotYet.rawValue,
            title: "Not yet",
            options: [.foreground]
        )

        let eventBlock = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.eventBlock.rawValue,
            actions: [startSession],
            intentIdentifiers: [],
            options: []
        )
        // Idle is now a "Checking in" yes/no question — the old start/
        // snooze/break-down trio was assumptive ("you've done nothing").
        // Yes/no is less confrontational and shifts the work to the user.
        let idle = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.idle.rawValue,
            actions: [idleYesGood, idleNotYet],
            intentIdentifiers: [],
            options: []
        )
        let getAhead = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.getAhead.rawValue,
            actions: [startSession, snooze30, breakItDown],
            intentIdentifiers: [],
            options: []
        )
        let breakDown = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.breakDown.rawValue,
            actions: [breakItDown, snooze30],
            intentIdentifiers: [],
            options: []
        )
        let morningPrompt = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.morningPrompt.rawValue,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            eventBlock, idle, getAhead, breakDown, morningPrompt
        ])
    }
}
