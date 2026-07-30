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
    /// Event heads-up — NO action buttons at all. It's an FYI before a
    /// class, the one budget-exempt kind that fires whether or not the user
    /// wants a decision from them, so there's no interaction for a button to
    /// invite. Tap-to-open and swipe-to-dismiss (both category-level, not
    /// actions) are the whole interaction surface.
    case eventBlock = "category.event"
    case idle       = "category.idle"
    case getAhead   = "category.getAhead"
    case breakDown  = "category.breakDown"
    /// Morning prompt — no *task* action buttons on purpose: the whole
    /// interaction is "tap → land in Home chat → type your answer". It does
    /// carry 👎, which doesn't compete with that (it never opens the app)
    /// and gives the user somewhere to say "stop asking me this" other than
    /// by going silent.
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
    // Idle "Checking in" notification — yes/no answer to the question
    // "Have you gotten started on anything today?"
    case idleYesGood  = "action.idleYesGood"
    case idleNotYet   = "action.idleNotYet"
    // Explicit negative feedback on the nudge itself, orthogonal to every
    // action above. Behaviour can't tell "this was useless" apart from
    // "this worked and I didn't need the app" — both are silence. This says
    // which. Recorded into `NudgeOutcome.feedback`, a separate column from
    // `result`; nothing consumes it yet.
    //
    // There is deliberately NO 👍 counterpart. `DESIGN.md` names the
    // explicit-opinion channel as 👎 *and conversational questions in chat*;
    // a thumbs-up that changes nothing is a request for unpaid labour.
    // Removed Jul 2026 along with the break-it-down action.
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

        // The feedback action is deliberately NOT `.foreground`. A foreground
        // action would launch the app, `ContentView` would stamp
        // `AppOpenLog`, and the classifier would then read that app open as
        // engagement with the very nudge being rated — turning an `.ignored`
        // into an `.engaged` as a side effect of the user telling us it was
        // useless. The whole point is two INDEPENDENT signals, so pressing
        // one must not move the other.
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
        // feedback always goes LAST — it must never displace Start or
        // Snooze.
        //
        // 👎 goes on every category that has actions at all: "I ignored
        // this" and "I reject this" are the same silence today, and only an
        // explicit press separates them.
        //
        // There is no 👍 anywhere (removed Jul 2026). Nothing read it, and
        // `DESIGN.md` puts the positive half of the opinion channel in chat
        // rather than on a banner button.
        //
        // The event heads-up has NO actions. It is the one budget-exempt
        // kind that fires whether or not the user wants a decision from
        // them — an FYI before a class — so every button on it was inviting
        // an interaction the notification has no use for. Start session was
        // the worst of them: the "task" here is a calendar event the user is
        // about to physically attend, not something to sit down and work on.
        // `dismissible` stays, so `.dismissed` outcome rows still get
        // written and tap-to-open still routes to the Tasks tab.
        let eventBlock = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.eventBlock.rawValue,
            actions: [],
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
        // Used to sit at the 4-action ceiling; dropping Break it down leaves
        // it a slot under.
        let getAhead = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.getAhead.rawValue,
            actions: [startSession, snooze30, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        // The break-it-down KIND is paused pending removal (`CLAUDE.md` work
        // order item 4) and can't fire while `fatigueGateEnabled` is off, so
        // this category is currently unreachable. Its own action is gone —
        // shipping a button for a paused feature is worse than shipping
        // nothing — which leaves it with the two that still mean something.
        let breakDown = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.breakDown.rawValue,
            actions: [snooze30, markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        let morningPrompt = UNNotificationCategory(
            identifier: NudgeNotificationCategoryID.morningPrompt.rawValue,
            actions: [markUnhelpful],
            intentIdentifiers: [],
            options: dismissible
        )
        // The floater check-in used to borrow `getAhead`'s category. It's
        // the same *shape* of ask — "start this task" — so it keeps Start
        // and Snooze. (It never carried Break it down either; that action
        // has since been removed everywhere, so the two categories are now
        // identical in their action list and differ only in identity.)
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
