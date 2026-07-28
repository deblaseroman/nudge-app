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
    /// Morning prompt — no *task* action buttons on purpose: the whole
    /// interaction is "tap → land in Home chat → type your answer". It does
    /// carry the two feedback actions, which don't compete with that (they
    /// never open the app) and give the user somewhere to say "stop asking
    /// me this" other than by going silent.
    /// A future banner-reply (UNTextInputNotificationAction) would
    /// attach here.
    case morningPrompt = "category.morning"
    /// Mid-day check-in on an undated task. Split out of `getAhead` along
    /// with `NudgeOutcomeKind.floater` — same reason: two different nudges
    /// sharing one identity made their data unreadable.
    case floater = "category.floater"
}

enum NudgeNotificationActionID: String {
    case startSession = "action.startSession"
    case snooze30     = "action.snooze30"
    case breakItDown  = "action.breakItDown"
    // Idle "Checking in" notification — yes/no answer to the question
    // "Have you gotten started on anything today?"
    case idleYesGood  = "action.idleYesGood"
    case idleNotYet   = "action.idleNotYet"
    // Explicit feedback on the nudge itself, orthogonal to every action
    // above. Behaviour can't tell "this was useless" apart from "this
    // worked and I didn't need the app" — both are silence. These say
    // which. Recorded into `NudgeOutcome.feedback`, a separate column
    // from `result`; nothing consumes them yet.
    case markHelpful   = "action.markHelpful"
    case markUnhelpful = "action.markUnhelpful"
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

        // Feedback actions are deliberately NOT `.foreground`. A foreground
        // action would launch the app, `ContentView` would stamp
        // `AppOpenLog`, and the classifier would then read that app open as
        // engagement with the very nudge being rated — turning an `.ignored`
        // into an `.engaged` as a side effect of the user telling us it was
        // useless. The whole point is two INDEPENDENT signals, so pressing
        // one must not move the other.
        let markHelpful = UNNotificationAction(
            identifier: NudgeNotificationActionID.markHelpful.rawValue,
            title: "👍 This helped",
            options: []
        )
        let markUnhelpful = UNNotificationAction(
            identifier: NudgeNotificationActionID.markUnhelpful.rawValue,
            title: "👎 Not useful",
            options: []
        )

        // `.customDismissAction` on EVERY category. Without it iOS never
        // delivers `UNNotificationDismissActionIdentifier`, so the
        // delegate's `.dismissed` branch — which has existed all along —
        // was dead code and `NudgeOutcome.dismissed` was unreachable.
        // An explicit swipe-away is a much stronger negative signal than
        // "the app wasn't opened", and it's the only one the user makes
        // deliberately, so it's worth capturing distinctly rather than
        // letting the classifier fold it into `.ignored`.
        //
        // Recording only: nothing reads `.dismissed` while
        // `NudgeConfig.fatigueGateEnabled` is off.
        let dismissible: UNNotificationCategoryOptions = [.customDismissAction]

        // ── Where feedback goes, and why ─────────────────────────────────
        // iOS renders at most FOUR actions in the expanded (long-press /
        // pull-down) interface and silently drops the rest; none are visible
        // on an un-expanded banner. Order is the order given here, so
        // feedback always goes LAST — it must never displace Start, Snooze,
        // or Break it down.
        //
        // 👎 goes on every category: "I ignored this" and "I reject this"
        // are the same silence today, and only an explicit press separates
        // them.
        //
        // 👍 goes only where the app cannot otherwise see success —
        // `.eventBlock`, whose success case (read it, go to class) leaves no
        // trace at all, and `.morningPrompt`, which has no action buttons to
        // express it with. Everywhere else a successful nudge already shows
        // up as a tap, a session, or a completion, and a third button buys
        // less than it costs in banner real estate.
        let eventBlock = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.eventBlock.rawValue,
            actions: [startSession, markHelpful, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        // Idle is now a "Checking in" yes/no question — the old start/
        // snooze/break-down trio was assumptive ("you've done nothing").
        // Yes/no is less confrontational and shifts the work to the user.
        let idle = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.idle.rawValue,
            actions: [idleYesGood, idleNotYet, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        // The only category at the 4-action ceiling. Nothing is dropped —
        // Start / Snooze / Break it down keep their slots and their order —
        // but this one has no room left for a future action.
        let getAhead = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.getAhead.rawValue,
            actions: [startSession, snooze30, breakItDown, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        let breakDown = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.breakDown.rawValue,
            actions: [breakItDown, snooze30, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        let morningPrompt = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.morningPrompt.rawValue,
            actions: [markHelpful, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        // The floater check-in used to borrow `getAhead`'s category. It's
        // the same *shape* of ask — "start this task" — so it keeps Start
        // and Snooze, but NOT Break it down: that action belongs to the
        // fatigue escape hatch for a task that's proving too big, and a
        // low-stakes undated floater is not that. Dropping it also leaves
        // this category one slot under the 4-action ceiling, where
        // `getAhead` has none.
        let floater = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.floater.rawValue,
            actions: [startSession, snooze30, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            eventBlock, idle, getAhead, breakDown, morningPrompt, floater
        ])
    }
}
