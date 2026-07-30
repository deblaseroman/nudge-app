//
//  NudgeNotificationService.swift
//  Nudge
//
//  Notification permissions + delegate. Owns the OS authorization state and
//  the foreground-presentation / response-handling delegate. Every scheduled
//  notification is built by `NudgeArbiter`; this file is the inbound seam
//  for what the user does with them (tap, dismiss, action buttons).
//

import Foundation
import SwiftData
import UserNotifications

extension Notification.Name {
    /// Posted from the UN delegate when a notification tap should drop the
    /// user on a specific tab. `userInfo["tab"]` carries the tab's raw value
    /// (matches a `case` in `AppTab`). ContentView observes this and updates
    /// its `deepLinkTab` state, which MainTabView reads.
    static let nudgeNotificationOpenTab = Notification.Name("nudge.notification.openTab")

    /// Posted when the user taps "Not yet" on the idle nudge. `userInfo`
    /// carries `taskID: String` (UUID string) of the highest-priority open
    /// task. TasksTabView observes this and shows a confirmation sheet
    /// offering that task as a starting point. If the user dismisses the
    /// sheet they can pick a different task — the goal is to break the
    /// decision paralysis the idle nudge itself was suffering from.
    static let nudgeIdleNotYetTapped = Notification.Name("nudge.notification.idleNotYet")
}

@MainActor
final class NudgeNotificationService: NSObject {

    static let shared = NudgeNotificationService()

    /// App-group keys for the durable "idle Not-yet → show confirmation
    /// sheet" intent. Written when the user taps "Not yet"; consumed by
    /// TasksTabView when it appears/becomes active (survives cold launch).
    static let pendingIdleTaskIDKey = "nudge.pendingIdleTaskID"
    static let pendingIdleTaskDateKey = "nudge.pendingIdleTaskDate"

    /// App-group keys for "the user tapped a nudge BODY and landed on the
    /// Tasks tab" — the same durable pattern as the idle keys above (a
    /// transient post dies on cold launch), consumed by the Tasks tab's
    /// message box via `TappedNudgeContext.read()`. NOT one-shot: the box
    /// is passive display, so the context stays readable for its freshness
    /// window (`NudgeConfig.messageBoxTapContextMinutes`) and expires by
    /// age. Written only on body taps that route to Tasks — action buttons
    /// carry their own flows (Start starts a session, idle "Not yet" has
    /// its sheet), and morning-prompt taps land in Home chat.
    static let tappedNudgeKindKey = "nudge.tappedNudgeKind"
    static let tappedNudgeTaskIDKey = "nudge.tappedNudgeTaskID"
    static let tappedNudgeDateKey = "nudge.tappedNudgeDate"

    enum AuthorizationState {
        case notDetermined
        case denied
        case authorized
    }

    private let center = UNUserNotificationCenter.current()

    override private init() {
        super.init()
    }

    /// Called at app launch from NudgeApp.didFinishLaunchingWithOptions.
    func configure() async {
        // Nothing to schedule yet. The new notification system will populate
        // this once it's built.
    }

    func authorizationState() async -> AuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> AuthorizationState {
        let current = await authorizationState()
        guard current == .notDetermined else { return current }

        do {
            // `.providesAppNotificationSettings` advertises that we expose
            // our own per-category settings UI, so iOS adds a "Settings"
            // link inside our notification settings page that deep-links
            // back into the app's Settings tab.
            _ = try await center.requestAuthorization(
                options: [.alert, .badge, .sound, .providesAppNotificationSettings]
            )
        } catch {
            return .denied
        }
        return await authorizationState()
    }

    /// No-op while the notification system is being rebuilt. Kept so callers
    /// (e.g. ContentView, SessionCoordinator) compile without changes.
    func scheduleAllNotifications(for profile: UserProfile, modelContext: ModelContext) async {
        // Intentionally empty.
    }

    /// Temporary debug helper. Sends a single notification 5 seconds later so
    /// you can verify the permission grant works on device.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test"
        content.body = "Notifications are enabled — new system not yet built."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "nudge.test.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NudgeNotificationService: UNUserNotificationCenterDelegate {
    // These delegate methods are @MainActor-isolated (inherited from the
    // @MainActor class — note: NO `nonisolated`). The system delivers the
    // callbacks and Swift guarantees the bodies run on the main actor. This
    // replaces the old `nonisolated ... async` + manual `MainActor.run`
    // pattern, which ran the body on the cooperative thread pool and then
    // hopped — leaving a window where UI-driving work (tab switch, sheet
    // presentation, SwiftData save → @Query invalidation) could be committed
    // off the main thread, tripping UIKit's
    // `_performBlockAfterCATransactionCommitSynchronizes` main-thread assert.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        let taskIDString = request.content.userInfo[NudgeNotificationUserInfoKey.taskID] as? String
        handleResponse(
            actionID: response.actionIdentifier,
            notificationID: request.identifier,
            taskID: taskIDString.flatMap(UUID.init(uuidString:)),
            requestContent: request.content
        )
    }

    @MainActor
    private func handleResponse(
        actionID: String,
        notificationID: String,
        taskID: UUID?,
        requestContent: UNNotificationContent
    ) {
        let context = ModelContext(SharedModelContainer.container)

        // Resolve outcome row up-front so every branch can update it.
        //
        // A notification ID can now match MORE than one row: `cancelAll`
        // retains pending rows whose fire time has already passed (they're
        // awaiting classification), so a rebuilt candidate that reuses its
        // ID — break-it-down keys on task ID alone, with no day stamp —
        // can insert a second row alongside the delivered one. Take the
        // newest still-pending row, falling back to the newest row at all.
        var outcomeDescriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> { $0.notificationID == notificationID },
            sortBy: [SortDescriptor(\.scheduledFor, order: .reverse)]
        )
        outcomeDescriptor.fetchLimit = 10
        let matches = (try? context.fetch(outcomeDescriptor)) ?? []
        let outcome = matches.first(where: { $0.resultRaw == "pending" }) ?? matches.first

        switch actionID {
        case UNNotificationDismissActionIdentifier:
            outcome?.result = .dismissed
            outcome?.actedAt = Date()

        case NudgeNotificationActionID.startSession.rawValue:
            outcome?.result = .tappedStart
            outcome?.actedAt = Date()
            startSession(for: taskID, context: context)
            // Defer the UI-driving post to a clean main runloop tick. Posting
            // synchronously from inside the UN delegate's MainActor.run runs
            // observers (deepLinkTab mutation, withAnimation tab switch) on
            // the same dispatch pass as the foregrounding handoff, which
            // triggered a "Call must be made on main thread" assertion.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .nudgeNotificationOpenTab,
                    object: nil,
                    userInfo: ["tab": "tasks"]
                )
            }

        case NudgeNotificationActionID.snooze30.rawValue:
            outcome?.result = .tappedSnooze
            outcome?.actedAt = Date()
            rescheduleSnoozed(requestContent: requestContent, originalID: notificationID)

        case NudgeNotificationActionID.idleYesGood.rawValue:
            // User said they're already on it. Leave them alone for the
            // rest of today — write a per-day marker the arbiter checks
            // before re-scheduling. Record as snooze (best existing match).
            outcome?.result = .tappedSnooze
            outcome?.actedAt = Date()
            let key = NudgeArbiter.idleDismissedKey(for: Date())
            SharedModelContainer.appGroupDefaults.set(true, forKey: key)

        case NudgeNotificationActionID.idleNotYet.rawValue:
            // User hasn't started yet. Pick the top task for them so they
            // don't have to choose, drop them on the Tasks tab, and let
            // TasksTabView surface a confirmation sheet.
            //
            // `.tappedOpen`, not `.tappedStart` (Aug 2026): "Not yet" is a
            // deliberate reply that OPENS a proposal sheet — by their own
            // statement the user hasn't started anything. If they start
            // from the sheet, the session lands after this row is resolved
            // and is not re-attributed; under-crediting is the safe
            // direction while outcomes are observation-only.
            outcome?.result = .tappedOpen
            outcome?.actedAt = Date()
            let topTask = pickTopOpenTask(context: context)
            // Capture as a sendable value — must not access the SwiftData
            // model from inside the deferred closures (different runloop
            // tick, potentially stale faulted reference).
            let topTaskIDString = topTask?.id.uuidString

            // DURABLE pending state. The transient .nudgeIdleNotYetTapped
            // post is only caught if TasksTabView is already mounted and
            // subscribed — which it is NOT on a COLD LAUNCH from the
            // notification tap (the whole view tree is still building, so the
            // post fires before the subscriber exists and the sheet never
            // shows). Persisting the proposed task to the app group makes the
            // intent survive the launch: TasksTabView reads it whenever it
            // appears / becomes active, independent of timing or launch path.
            if let topTaskIDString {
                let defaults = SharedModelContainer.appGroupDefaults
                defaults.set(topTaskIDString, forKey: Self.pendingIdleTaskIDKey)
                defaults.set(Date(), forKey: Self.pendingIdleTaskDateKey)
            }
            // Two-step async hop: the tab-open post fires first on the next
            // main runloop tick so SwiftUI can commit deepLinkTab → MainTabView
            // selectedTab → TasksTabView mounts → .onReceive subscription
            // becomes live. THEN the idleNotYet post fires on the tick after,
            // by which time TasksTabView is in the hierarchy and its
            // subscription will actually catch the notification. Posting both
            // synchronously inside MainActor.run was both crashing during
            // the foregrounding handoff AND missing the sheet observer
            // because TasksTabView wasn't mounted yet.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .nudgeNotificationOpenTab,
                    object: nil,
                    userInfo: ["tab": "tasks"]
                )
                if let topTaskIDString {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: .nudgeIdleNotYetTapped,
                            object: nil,
                            userInfo: ["taskID": topTaskIDString]
                        )
                    }
                }
            }

        case NudgeNotificationActionID.markUnhelpful.rawValue:
            recordFeedback(.markedUnhelpful, on: outcome)

        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification body itself (not a button).
            // `.tappedOpen`, not `.tappedStart` (Aug 2026): a body tap
            // means "show me", not "I'm starting" — recording it as
            // tappedStart made the two indistinguishable in the data,
            // which the fatigue gate must be able to tell apart before it
            // ever arms. `.tappedStart` now comes only from the explicit
            // Start action above.
            outcome?.result = .tappedOpen
            outcome?.actedAt = Date()
            // The morning prompt asks a question the user answers by TYPING —
            // its landing surface is the Home chat, where the reply flows
            // through normal brain-dump capture. Every other notification's
            // home remains the Tasks tab.
            let kindRaw = requestContent.userInfo[NudgeNotificationUserInfoKey.kind] as? String
            let tab = (kindRaw == NudgeOutcomeKind.morningPrompt.rawValue) ? "home" : "tasks"
            // Durable context for the Tasks tab's message box: which nudge
            // the user arrived from, so the box can explain it in more room
            // than a banner has. Same survives-cold-launch reasoning as the
            // idle "Not yet" keys above.
            if tab == "tasks", let kindRaw {
                let defaults = SharedModelContainer.appGroupDefaults
                defaults.set(kindRaw, forKey: Self.tappedNudgeKindKey)
                if let taskID {
                    defaults.set(taskID.uuidString, forKey: Self.tappedNudgeTaskIDKey)
                } else {
                    defaults.removeObject(forKey: Self.tappedNudgeTaskIDKey)
                }
                defaults.set(Date(), forKey: Self.tappedNudgeDateKey)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .nudgeNotificationOpenTab,
                    object: nil,
                    userInfo: ["tab": tab]
                )
            }

        default:
            // Unknown action — log no result so the row stays pending and
            // can be re-evaluated on the next pass.
            break
        }

        try? context.save()
    }

    /// Records an explicit 👎 on the nudge, and touches NOTHING else.
    ///
    /// Every other branch above writes `result` + `actedAt`. This one
    /// deliberately does not, in either direction:
    ///
    ///   • It leaves `result` alone, so a row the user already acted on
    ///     keeps its behavioural record alongside the rating.
    ///   • It leaves a `pending` row PENDING, so `NudgeOutcomeClassifier`
    ///     still sweeps it later and we end up with both readings on the
    ///     same row — the inferred one and the stated one. Stamping a
    ///     result here would take the row out of the sweep's predicate and
    ///     destroy the comparison the feedback exists to enable.
    ///
    /// The feedback action is non-`.foreground` (see
    /// `NudgeNotificationCategories`) so pressing it doesn't stamp
    /// `AppOpenLog` either. The two signals stay independent end to end.
    ///
    /// Nothing consumes `feedback` yet — this is collection only.
    @MainActor
    private func recordFeedback(_ value: NudgeOutcomeResult, on outcome: NudgeOutcome?) {
        guard let outcome else { return }
        outcome.feedback = value
        outcome.feedbackAt = Date()
    }

    /// Returns the highest-priority open task per `TaskSortComparator`.
    /// Used by the idle "Not yet" handler to pre-select a task so the user
    /// doesn't have to scan the full list to pick something.
    @MainActor
    private func pickTopOpenTask(context: ModelContext) -> NudgeTask? {
        let allTasks = (try? context.fetch(FetchDescriptor<NudgeTask>())) ?? []
        let open = allTasks.filter { !$0.isInformationalEvent && !$0.isComplete }
        // The comparator is plan-first: an ordered plan's NEXT item wins
        // when one exists, deadline buckets rank the rest.
        let comparator = TaskSortComparator()
        return open.min { comparator.compare($0, $1) }
    }

    @MainActor
    private func startSession(for taskID: UUID?, context: ModelContext) {
        guard let taskID else { return }
        guard !SessionCoordinator.shared.isSessionActive else { return }
        let taskDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.id == taskID }
        )
        guard let task = (try? context.fetch(taskDescriptor))?.first else { return }
        let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
        SessionCoordinator.shared.startSession(
            task: task,
            userName: profile?.name ?? ""
        )
    }

    /// Re-fires the same notification copy 30 minutes later. We can't
    /// rebuild the original `NudgeCandidate` here (no full arbiter context),
    /// so we just clone the delivered content and schedule a one-shot with
    /// a derived ID.
    @MainActor
    private func rescheduleSnoozed(requestContent: UNNotificationContent, originalID: String) {
        let copy = UNMutableNotificationContent()
        copy.title = requestContent.title
        copy.body = requestContent.body
        copy.sound = requestContent.sound
        copy.userInfo = requestContent.userInfo
        copy.categoryIdentifier = requestContent.categoryIdentifier
        copy.interruptionLevel = requestContent.interruptionLevel
        copy.relevanceScore = requestContent.relevanceScore

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30 * 60, repeats: false)
        let request = UNNotificationRequest(
            identifier: "\(originalID).snoozed",
            content: copy,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}
