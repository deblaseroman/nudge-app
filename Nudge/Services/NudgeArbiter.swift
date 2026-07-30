//
//  NudgeArbiter.swift
//  Nudge
//
//  Single decision engine. Nothing else in the app may emit a nudge —
//  every notification candidate goes through `reevaluate(reason:…)`,
//  passes the gates, gets scored, and AT MOST ONE survives.
//
//  ── ON-DEVICE-VS-BACKEND SEAM ──────────────────────────────────────────
//  `NudgeArbitering` is the protocol future implementations (e.g. a server
//  computing arbitration with cross-device context and pushing via APNs)
//  must satisfy. All feature code talks to the protocol, not the class.
//  When that day comes, swap the `shared` to a remote-driven impl without
//  touching feature callers.
//  ───────────────────────────────────────────────────────────────────────
//

import Foundation
import SwiftData
import UserNotifications

// MARK: - Triggers

enum NudgeArbiterReason {
    case appLaunch
    case sceneActive
    case sessionStarted
    case sessionEnded
    case taskCompleted
    case taskCreatedOrEdited
    case backgroundTask
}

// MARK: - Protocol seam (future backend swap)

@MainActor
protocol NudgeArbitering {
    func reevaluate(
        reason: NudgeArbiterReason,
        profile: UserProfile,
        modelContext: ModelContext
    )
}

// MARK: - Candidate

/// Visual urgency tier. iOS doesn't let us colorize the banner itself, so we
/// signal urgency through (a) an emoji prefix on the title that reads as a
/// red/yellow/neutral indicator, (b) interruptionLevel, and (c) relevanceScore.
enum NudgeUrgencyTier {
    case normal     // standard appearance, no emoji
    case warning    // ⚠️ prefix, .timeSensitive, relevance 0.75
    case critical   // 🔴 prefix, .timeSensitive, relevance 1.0, ALL CAPS title

    var titlePrefix: String {
        switch self {
        case .normal:   return ""
        case .warning:  return "⚠️ "
        case .critical: return "🔴 "
        }
    }

    var relevanceScore: Double {
        switch self {
        case .normal:   return 0.5
        case .warning:  return 0.75
        case .critical: return 1.0
        }
    }

    var interruption: UNNotificationInterruptionLevel {
        switch self {
        case .normal:   return .active
        case .warning, .critical: return .timeSensitive
        }
    }

    func styledTitle(_ raw: String) -> String {
        switch self {
        case .normal:   return raw
        case .warning:  return "\(titlePrefix)\(raw)"
        case .critical: return "\(titlePrefix)\(raw.uppercased())"
        }
    }
}

struct NudgeCandidate {
    let id: String
    let kind: NudgeOutcomeKind
    let fireDate: Date
    let title: String
    let body: String
    let categoryID: NudgeNotificationCategoryID
    let interruption: UNNotificationInterruptionLevel
    let taskID: UUID?
    /// Visual urgency tier — overrides `interruption` when scheduling.
    let tier: NudgeUrgencyTier

    /// Eisenhower inputs. `urgency` is the logistic slack curve from
    /// `EisenhowerScorer.urgency`; `importance` is the weighted-signals sum
    /// from `EisenhowerScorer.importance`. Both 0...1.
    let urgency: Double
    let importance: Double
    /// Receptivity is a vestige from the prior `urgency × importance ×
    /// receptivity` formula. Step 5 leaves the field in place for source
    /// compatibility but it no longer participates in scoring — quadrant
    /// routing handles "when to even consider firing" now. Removed entirely
    /// in step 6 with the rest of the LLM-vibes pipeline.
    let receptivity: Double

    /// Event blocks bypass the daily nudge budget — they're factual time
    /// reminders, not motivational nudges.
    let countsAgainstBudget: Bool

    /// What `DurationModel.estimate(for:)` thought the task would take when
    /// this nudge was scheduled. Stored on the NudgeOutcome so we can
    /// compare predicted vs actual minutes once the user finishes. Nil for
    /// event blocks (no task duration to estimate).
    let estimatedMinutes: Int?

    /// The task this nudge's COPY names, when that isn't the same thing as
    /// the task it's *about*.
    ///
    /// Only the morning prompt uses it. That candidate keeps `taskID == nil`
    /// on purpose — `taskID` feeds the fatigue system, and pointing it at
    /// the user's highest-stakes task would make an ignored morning prompt
    /// count against exactly the wrong item the day `fatigueGateEnabled`
    /// flips (see the comment in `buildMorningPromptCandidates`). This field
    /// is inert by construction: nothing reads it but the morning prompt's
    /// own named-task history, so it can carry the attribution `taskID`
    /// must not.
    ///
    /// A `var` with a default purely so the synthesised memberwise init
    /// keeps working at the five call sites that don't set it.
    var namedTaskID: UUID? = nil

    /// Within-slot ranking. `pow(urgency, 1.1) * pow(importance, 0.9)` —
    /// urgency exponent slightly higher to favor time-pressure breaking ties.
    var score: Double {
        EisenhowerScorer.score(urgency: urgency, importance: importance)
    }

    /// Which Eisenhower quadrant this candidate landed in. Currently DEBUG
    /// diagnostic only; step 6 will use it to gate candidate eligibility
    /// instead of relying on the `kind` field for that.
    var quadrant: EisenhowerQuadrant {
        EisenhowerScorer.quadrant(urgency: urgency, importance: importance)
    }
}

// MARK: - Concrete arbiter

@MainActor
final class NudgeArbiter: NudgeArbitering {

    static let shared: NudgeArbitering = NudgeArbiter()
    private init() {}

    private let center = UNUserNotificationCenter.current()
    /// ID prefix for everything the arbiter schedules. Anything else with
    /// this prefix is fair game to cancel during recalc.
    private let prefix = "nudge.arb."
    /// App Group key backing the in-memory `scheduledIDs` set. Persisted so
    /// a fresh app launch still knows which notifications it owns.
    private let scheduledIDsKey = "nudge.arb.scheduledIDs"
    /// App Group key for the per-event-block "we already scheduled this
    /// today" map. Prevents duplicate fires when `cancelAll` wipes a pending
    /// event reminder that has already been delivered — without this marker
    /// the next reevaluate would re-add it with the same ID and refire.
    private let eventReminderHistoryKey = "nudge.arb.eventReminderHistory"
    private let appGroupID = "group.com.deblaser.nudge"

    /// Last time `reevaluate` actually ran (not counting debounced returns).
    /// Used to skip purely time-triggered reevals (app launch, scene-active,
    /// BG task) that happen within a tight window — the user backgrounding
    /// and foregrounding 20 times in an hour should not trigger 20 SwiftData
    /// fetches + candidate builds + gate runs.
    private var lastReevaluatedAt: Date?
    private let debounceWindow: TimeInterval = 60

    /// Synchronous in-memory record of every notification ID we've handed to
    /// the system. We use THIS for cancellation rather than the async
    /// `pendingNotificationRequests()` round-trip — that round-trip was
    /// racing against `schedule()` and killing brand-new notifications
    /// before they ever fired.
    private var scheduledIDs: Set<String> {
        get {
            let arr = SharedModelContainer.appGroupDefaults
                .stringArray(forKey: scheduledIDsKey) ?? []
            return Set(arr)
        }
        set {
            SharedModelContainer.appGroupDefaults
                .set(Array(newValue), forKey: scheduledIDsKey)
        }
    }

    /// App Group key for "which task did the morning prompt name on which
    /// day". Backs `morningPromptMaxConsecutiveDays`.
    private let morningPromptHistoryKey = "nudge.arb.morningPromptHistory"

    /// Day stamp (`yyyyMMdd`, the same format candidate IDs embed) → the
    /// UUID string of the task the morning prompt named for that day.
    ///
    /// Written in `schedule()` rather than in the builder, mirroring
    /// `eventReminderHistory`: the builder runs many times a day and its
    /// output can still be dropped downstream, so "what we actually handed
    /// to the OS" is the only honest thing to record. Re-scheduling the same
    /// day's prompt overwrites the same key with the same value, so repeated
    /// reevaluates are idempotent.
    ///
    /// Pruned alongside `eventReminderHistory` in `cancelAll`. Stamp keys
    /// sort lexicographically in date order, which is what makes the prune a
    /// string comparison.
    private var morningPromptHistory: [String: String] {
        get {
            SharedModelContainer.appGroupDefaults
                .dictionary(forKey: morningPromptHistoryKey)?
                .compactMapValues { $0 as? String } ?? [:]
        }
        set {
            SharedModelContainer.appGroupDefaults
                .set(newValue, forKey: morningPromptHistoryKey)
        }
    }

    /// Per-event-block "we already scheduled this once today" map. Keyed by
    /// the candidate's notification ID (which embeds the day stamp + event
    /// UUID, so entries naturally segregate by day). The value is the
    /// epoch time we last scheduled it — purely used to short-circuit
    /// rescheduling on the next reevaluate so we don't double-fire after
    /// the OS has already delivered the reminder.
    private var eventReminderHistory: [String: TimeInterval] {
        get {
            SharedModelContainer.appGroupDefaults
                .dictionary(forKey: eventReminderHistoryKey)?
                .compactMapValues { $0 as? TimeInterval } ?? [:]
        }
        set {
            SharedModelContainer.appGroupDefaults
                .set(newValue, forKey: eventReminderHistoryKey)
        }
    }

    // MARK: - Entry point

    func reevaluate(
        reason: NudgeArbiterReason,
        profile: UserProfile,
        modelContext: ModelContext
    ) {
        // Debounce purely time-triggered reevals — skip if we ran within
        // the debounce window. Data-driven reasons (task created/edited,
        // task completed, session start/end) always re-run so the user
        // sees up-to-date scheduling.
        let isTimeTriggered = (reason == .appLaunch
            || reason == .sceneActive
            || reason == .backgroundTask)
        if isTimeTriggered,
           let last = lastReevaluatedAt,
           Date().timeIntervalSince(last) < debounceWindow {
            #if DEBUG
            print("[NudgeArbiter] Debounced \(reason) — last ran \(Int(Date().timeIntervalSince(last)))s ago.")
            #endif
            return
        }
        lastReevaluatedAt = Date()

        #if DEBUG
        print("[NudgeArbiter] Reevaluate triggered: \(reason). notificationsEnabled=\(profile.notificationsEnabled)")
        #endif
        cancelAll(modelContext: modelContext)

        guard profile.notificationsEnabled else {
            #if DEBUG
            print("[NudgeArbiter] Skipped — notifications disabled in profile.")
            #endif
            return
        }

        // 1. Build candidate set
        var candidates: [NudgeCandidate] = []
        candidates.append(contentsOf: buildEventBlockCandidates(profile: profile, modelContext: modelContext))
        candidates.append(contentsOf: buildMorningPromptCandidates(profile: profile, modelContext: modelContext))
        candidates.append(contentsOf: buildIdleCandidates(profile: profile, modelContext: modelContext))
        candidates.append(contentsOf: buildGetAheadCandidates(profile: profile, modelContext: modelContext))
        candidates.append(contentsOf: buildFloaterCheckInCandidates(profile: profile, modelContext: modelContext))
        #if DEBUG
        print("[NudgeArbiter] Built \(candidates.count) raw candidates (events + morning + idle + getAhead + floater).")
        #endif

        // 2. Run gates
        let now = Date()
        let gateContext = GateContext(profile: profile, modelContext: modelContext, now: now)
        let eligible = candidates.filter { passesGates($0, context: gateContext) }
        #if DEBUG
        print("[NudgeArbiter] \(eligible.count) candidates passed the gates.")
        debugStakesImpact(all: candidates, eligible: eligible, context: gateContext)
        debugQuietHoursImpact(all: candidates, context: gateContext)
        debugMorningPromptImpact(all: candidates, profile: profile, context: gateContext)
        debugRecentActivityImpact(all: candidates, context: gateContext)
        debugActiveSessionImpact(all: candidates, context: gateContext)
        #endif

        // 3. Pick winners — exactly one discretionary nudge per fire-time
        //    window; event-block reminders can stack alongside since they
        //    bypass the budget.
        let scheduled = pickWinners(from: eligible, context: gateContext)
        #if DEBUG
        print("[NudgeArbiter] Scheduling \(scheduled.count) winner(s).")
        for w in scheduled {
            // Quadrant printout is currently diagnostic only — step 6 will
            // gate eligibility on quadrant instead of nudge `kind`.
            let q: String
            switch w.quadrant {
            case .startNow:     q = "startNow"
            case .quickWin:     q = "quickWin"
            case .getAhead:     q = "getAhead"
            case .lowPriority:  q = "lowPriority"
            }
            let u = String(format: "%.2f", w.urgency)
            let i = String(format: "%.2f", w.importance)
            let s = String(format: "%.3f", w.score)
            print("  • \(w.kind.rawValue) [u=\(u) i=\(i) score=\(s) → \(q)] @ \(w.fireDate) — \(w.title): \(w.body.prefix(60))")
        }
        debugFloaterImpact(
            all: candidates,
            eligible: eligible,
            scheduled: scheduled,
            profile: profile,
            context: gateContext
        )
        #endif

        // 4. Schedule
        for cand in scheduled {
            schedule(cand, modelContext: modelContext)
        }
    }

    // MARK: - Cancel

    /// Synchronous cancel. Uses the in-memory tracked-IDs set (backed by
    /// shared UserDefaults so app-restarts still know what they own) instead
    /// of the async `pendingNotificationRequests()` round-trip, which was
    /// racing against the immediately-following `schedule()` calls and
    /// deleting brand-new notifications before they could fire.
    private func cancelAll(modelContext: ModelContext) {
        let ids = scheduledIDs
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(ids))
            scheduledIDs = []
        }

        // Prune event-reminder markers older than 2 days. The map otherwise
        // grows forever as events come and go.
        let cutoff = Date().addingTimeInterval(-2 * 24 * 60 * 60).timeIntervalSinceReferenceDate
        let pruned = eventReminderHistory.filter { $0.value > cutoff }
        if pruned.count != eventReminderHistory.count {
            eventReminderHistory = pruned
        }

        // Same treatment for the morning prompt's named-task history. Kept
        // for a week rather than 2 days: the rule reads the days immediately
        // before the FIRE day, and that fire day can be tomorrow, so the
        // window has to outlast the lookback by a comfortable margin.
        let historyCutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            .map { stamp($0) } ?? ""
        let prunedMorning = morningPromptHistory.filter { $0.key >= historyCutoff }
        if prunedMorning.count != morningPromptHistory.count {
            morningPromptHistory = prunedMorning
        }

        // Pending NudgeOutcome rows split into two populations, and only
        // ONE of them is garbage. This used to delete both, which is why
        // `.ignored` had no writer and the fatigue gate could never trip:
        // the evidence was destroyed on the very next reevaluate, minutes
        // after the notification went out.
        //
        //   • fireDate in the FUTURE — the request we removed above was
        //     still pending with the OS, so it never reached the user. The
        //     row is an artifact of this rebuild and is deleted here; the
        //     rebuild below re-inserts a row for whatever it schedules.
        //     This is what keeps the declarative rebuild honest — the set
        //     of future pending rows always mirrors the set of scheduled
        //     notifications, exactly as before.
        //
        //   • fireDate in the PAST — the OS already DELIVERED this
        //     notification and the user simply hasn't answered it. This row
        //     is the only record that the nudge happened, so it survives
        //     until `NudgeOutcomeClassifier` resolves it into
        //     acted / engaged / ignored once the grace period elapses.
        //     (A tap resolves it sooner, via the delegate.)
        let now = Date()
        let futurePendingDescriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> {
                $0.resultRaw == "pending" && $0.scheduledFor > now
            }
        )
        if let futurePending = try? modelContext.fetch(futurePendingDescriptor),
           !futurePending.isEmpty {
            for row in futurePending { modelContext.delete(row) }
            try? modelContext.save()
        }

        // Prune outcomes older than the 14-day fatigue window. Without
        // this, every resolved row persisted forever, so the database grew
        // monotonically and `taskFatigueCount` reloaded ever-larger result
        // sets into the shared SwiftData identity map on every reevaluate.
        // This was a confirmed contributor to the rapid-cycling memory
        // jetsam.
        //
        // Cleanup rule (chosen to keep fatigue tracking correct):
        //   - Cutoff: 14 days ago (same window the fatigue fetch uses).
        //   - Delete: ANY outcome with `scheduledFor` older than the
        //     cutoff, pending included. Pending is no longer excluded
        //     because past-due pending rows now SURVIVE the block above —
        //     without this they'd be the one population with no ceiling.
        //     In practice the classifier resolves them within 90 minutes;
        //     this is the backstop for rows that somehow never got swept.
        //   - Keep: ALL outcomes within the last 14 days, so the per-task
        //     fatigue counter sees complete recent history.
        //
        // Uses `delete(model:where:)` so rows are removed by predicate
        // without first loading them into the context.
        let staleCutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        try? modelContext.delete(
            model: NudgeOutcome.self,
            where: #Predicate<NudgeOutcome> { $0.scheduledFor < staleCutoff }
        )
        try? modelContext.save()

        #if DEBUG
        print("[NudgeArbiter] cancelAll removed \(ids.count) pending notification(s).")
        #endif
    }

    // MARK: - Candidate builders

    /// Event-block reminders: one notification per block of events spaced
    /// within `eventBlockGapHours` of each other, fired
    /// `eventReminderLeadMinutes` before the FIRST event of the block.
    ///
    /// Budget-exempt, so — like the morning prompt — `passesGates` skips the
    /// shared quiet-hours/busy gates for these and the per-kind toggle has to
    /// be checked here. `eventReminderNotificationsEnabled` was added Jul
    /// 2026; this was the last builder with no switch of its own, so the only
    /// way to stop event heads-ups was the master `notificationsEnabled`.
    private func buildEventBlockCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.eventReminderNotificationsEnabled else {
            #if DEBUG
            print("[NudgeArbiter] event: SKIP — eventReminderNotificationsEnabled is off.")
            #endif
            return []
        }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let horizonEnd = calendar.date(byAdding: .day, value: 14, to: todayStart) ?? .distantFuture

        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.isInformationalEvent }
        )
        let allEvents = (try? modelContext.fetch(descriptor)) ?? []

        // Group by day, then cluster within each day.
        let eventsByDay = Dictionary(grouping: allEvents) { event -> Date in
            calendar.startOfDay(for: event.specificTime ?? event.dueDate ?? .distantFuture)
        }

        var candidates: [NudgeCandidate] = []
        for (day, events) in eventsByDay where day >= todayStart && day < horizonEnd {
            let dayEvents = events
                .compactMap { event -> (NudgeTask, Date)? in
                    guard let t = event.specificTime else { return nil }
                    return (event, t)
                }
                .sorted { $0.1 < $1.1 }

            let blocks = NudgeArbiter.clusterEvents(dayEvents)

            for block in blocks {
                guard let firstStart = block.first?.1 else { continue }
                let leadFireDate = firstStart.addingTimeInterval(
                    -Double(NudgeConfig.eventReminderLeadMinutes) * 60
                )

                // Compute fire date. If the normal lead-time has passed but
                // the event itself is still > 5 min away, fire ASAP — without
                // this fallback, calendar imports that happen inside the
                // lead window result in NO reminder at all (cancelAll wipes
                // any pre-existing reminder, then the past-fire-date guard
                // here drops the new candidate).
                let now = Date()
                let fireDate: Date
                if leadFireDate > now {
                    fireDate = leadFireDate
                } else if firstStart.timeIntervalSince(now) > 5 * 60 {
                    fireDate = now.addingTimeInterval(60)
                } else {
                    continue
                }

                let firstEvent = block.first?.0
                let firstID = firstEvent?.id.uuidString ?? UUID().uuidString
                let candidateID = "\(prefix)event.\(stamp(day)).\(firstID)"

                // Skip only if this block's reminder was already DELIVERED
                // (stored fire time in the past) — re-adding it would
                // duplicate-fire via the ASAP fallback above. A marker with
                // a future fire time means cancelAll wiped a still-PENDING
                // request at the start of this reevaluate; that candidate
                // must be rebuilt, or the reminder never fires at all.
                if let markedFire = eventReminderHistory[candidateID],
                   Date(timeIntervalSinceReferenceDate: markedFire) <= now {
                    continue
                }

                let body = NudgeArbiter.eventBlockBody(block: block)
                let tier = tier(for: firstEvent, fireDate: fireDate)
                candidates.append(NudgeCandidate(
                    id: candidateID,
                    kind: .eventBlock,
                    fireDate: fireDate,
                    title: "Heads up",
                    body: body,
                    categoryID: .eventBlock,
                    interruption: tier.interruption,
                    taskID: firstEvent?.id,
                    tier: tier,
                    urgency: 1.0,
                    importance: 1.0,
                    receptivity: 1.0,
                    countsAgainstBudget: false,
                    estimatedMinutes: nil
                ))
            }
        }
        return candidates
    }

    /// Clusters today's events into blocks. Public-ish (internal static)
    /// so it can be unit-tested.
    static func clusterEvents(_ sorted: [(NudgeTask, Date)]) -> [[(NudgeTask, Date)]] {
        guard !sorted.isEmpty else { return [] }
        var blocks: [[(NudgeTask, Date)]] = [[sorted[0]]]
        let gap = NudgeConfig.eventBlockGapHours * 60 * 60
        for i in 1..<sorted.count {
            let prevStart = blocks[blocks.count - 1].last!.1
            let currStart = sorted[i].1
            if currStart.timeIntervalSince(prevStart) < gap {
                blocks[blocks.count - 1].append(sorted[i])
            } else {
                blocks.append([sorted[i]])
            }
        }
        return blocks
    }

    private static func eventBlockBody(block: [(NudgeTask, Date)]) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        guard let first = block.first else { return "" }
        let firstTime = fmt.string(from: first.1)
        let noun = eventNoun(for: first.0)

        switch block.count {
        case 1:
            return "\(noun) in 1 hour (\(firstTime))."
        case 2:
            let second = block[1]
            let secondTime = fmt.string(from: second.1)
            return "\(noun) in 1 hour (\(firstTime)). You've also got \(second.0.title) at \(secondTime) — your morning's booked."
        default:
            let after = block.count - 1
            return "\(noun) in 1 hour (\(firstTime)). You've got \(after) more back-to-back after that — wrap anything else first."
        }
    }

    /// Picks the noun for an event-block notification based on the first
    /// event's category. Without this the body always said "Class" — wrong
    /// when the event was a work shift or appointment.
    private static func eventNoun(for task: NudgeTask) -> String {
        switch task.taskCategory {
        case .school: return "Class"
        case .work:   return "Work shift"
        case .exam:   return "Exam"
        case .health: return "Appointment"
        case .personal, .errand, .other, .none:
            return "Event"
        }
    }

    /// Morning prompt — the day-opening statement of the biggest thing on
    /// the user's list. Tapping it lands in the Home chat, where anything
    /// they type flows through the normal brain-dump capture.
    ///
    /// ── IT USED TO ASK A QUESTION ─────────────────────────────────────
    /// Until Jul 2026 the body was "What do you want to get done today?
    /// Tell me and I'll set it up." — an open question that costs attention
    /// and returns nothing the app can use, in the best delivery slot it
    /// has (budget-exempt, highest morning capacity). It now names the
    /// user's highest-stakes open task instead, so the slot carries the
    /// day's most consequential item. **If no open task qualifies it does
    /// not fire at all**: a contentless morning notification is worse than
    /// silence.
    ///
    /// Replaces the fixed `NotificationScheduler` morning kickoff so the
    /// decision runs through the arbiter's declarative rebuild instead of a
    /// repeating clock trigger that fires no matter what the day looks like.
    ///
    /// Budget-exempt like event blocks — it's the daily anchor, not a
    /// discretionary nudge. That also means `passesGates` skips the shared
    /// quiet-hours/busy gates for it (they're keyed on
    /// `countsAgainstBudget`), so this builder does its own checks:
    ///   1. Per-kind toggle (`morningCheckInNotificationsEnabled` — the
    ///      same Settings switch that gated the old kickoff).
    ///   2. Day-fullness: skip when the fire day's awake window is already
    ///      ≥ `morningPromptBusyDayThreshold` committed to events — a
    ///      packed day doesn't need an open-ended planning ask on top.
    ///   3. Fire-moment: skip when the fire time itself lands inside a
    ///      busy window (early class overlapping wake+30).
    ///
    /// Fire time is the end of the post-wake quiet period, today if still
    /// ahead, else tomorrow — so after delivery the next reevaluate rolls
    /// to tomorrow's stamp-dated ID and never re-fires today's. Suppression
    /// is evaluated against the FIRE day, not "today": an evening
    /// reevaluate assesses tomorrow with whatever events are known now,
    /// and the 6 AM background task re-runs it with the morning's data.
    private func buildMorningPromptCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.morningCheckInNotificationsEnabled else {
            #if DEBUG
            print("[NudgeArbiter] morning: SKIP — morningCheckInNotificationsEnabled is off.")
            #endif
            return []
        }
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        var todayComps = calendar.dateComponents([.year, .month, .day], from: Date())
        todayComps.hour = wakeComps.hour
        todayComps.minute = wakeComps.minute
        guard let todaysWake = calendar.date(from: todayComps) else { return [] }

        var fireDate = todaysWake.addingTimeInterval(Double(NudgeConfig.postWakeQuietMinutes) * 60)
        if fireDate <= Date() {
            fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }

        if let load = BusyWindowResolver.shared.dayLoad(
            on: fireDate,
            wake: wake,
            bedtime: profile.bedtime,
            modelContext: modelContext
        ), load.busyFraction >= NudgeConfig.morningPromptBusyDayThreshold {
            #if DEBUG
            print("[NudgeArbiter] morning: SKIP — fire day is \(Int(load.busyFraction * 100))% committed (threshold \(Int(NudgeConfig.morningPromptBusyDayThreshold * 100))%).")
            #endif
            return []
        }

        if BusyWindowResolver.shared.isBusy(at: fireDate, modelContext: modelContext) {
            #if DEBUG
            print("[NudgeArbiter] morning: SKIP — fire time \(fireDate) lands inside a busy window.")
            #endif
            return []
        }

        // The content gate, and the only one that can silence this nudge on
        // a completely free day: with nothing open there is nothing to name.
        guard let named = morningPromptRanking(
            fireDate: fireDate,
            modelContext: modelContext
        ).first else {
            #if DEBUG
            print("[NudgeArbiter] morning: SKIP — no open task to name.")
            #endif
            return []
        }

        #if DEBUG
        print("[NudgeArbiter] morning: OK — will schedule morning prompt at \(fireDate) "
            + "naming '\(named.task.title)' "
            + "(stakes=\(named.stakes?.rawValue ?? "unclassified"), "
            + "urgency=\(String(format: "%.2f", named.urgency))).")
        #endif
        return [NudgeCandidate(
            id: "\(prefix)morning.\(stamp(calendar.startOfDay(for: fireDate)))",
            kind: .morningPrompt,
            fireDate: fireDate,
            title: "Good morning",
            body: NudgeArbiter.morningPromptBody(for: named.task, fireDate: fireDate),
            categoryID: .morningPrompt,
            interruption: .active,
            // ── taskID STAYS NIL, deliberately ───────────────────────────
            // The plan for this change asked whether setting it is free
            // because of the classifier. In `performedAction` it IS: the
            // `row.kind == .morningPrompt` branch returns before the
            // `guard let taskID`, so a non-nil taskID would not change one
            // classification.
            //
            // It is NOT free for the remaining `taskID` consumer, which
            // sits inside the fatigue system that `CLAUDE.md` work order
            // items 2 and 3 are deliberately keeping unarmed:
            // `passesGates`' per-task fatigue check exempts kinds by
            // `successIsObservableInApp`, and `.morningPrompt` passes that
            // predicate — so the named task would start accumulating
            // fatigue from a nudge that is not a push to work on it, and
            // the user's HIGHEST-STAKES task would be the first one the
            // gate silences.
            //
            // Inert while `fatigueGateEnabled` is off, which is exactly
            // what makes setting taskID a landmine rather than a bug: it
            // would change behaviour on the day that flag flips, for the
            // one task least able to afford it. Attribution for this nudge
            // comes from `debugMorningPromptImpact` instead.
            taskID: nil,
            tier: .normal,
            urgency: 1.0,
            importance: 1.0,
            receptivity: 1.0,
            countsAgainstBudget: false,
            estimatedMinutes: nil,
            namedTaskID: named.task.id
        )]
    }

    /// One ranked row of the morning prompt's selection: the task, the
    /// stakes it was ranked on, and the deadline-proximity tie-break.
    private struct MorningPromptChoice {
        let task: NudgeTask
        let stakes: TaskStakes?
        let urgency: Double
    }

    /// Every open task the morning prompt could name, best first.
    ///
    /// **Primary key is `NudgeTask.stakes`, read DIRECTLY.** `CLAUDE.md`
    /// work order item 1 keeps stakes out of `EisenhowerScorer.importance`
    /// until the floater baseline exists; this reads the field without
    /// touching that call site, so scoring is bit-identical to before.
    ///
    /// **Ties break on deadline proximity**, via the existing logistic
    /// urgency curve rather than a second hand-rolled ranking — evaluated
    /// AT the fire date, matching `buildGetAheadCandidates`. A task with no
    /// deadline scores 0: undated is the least proximate thing there is.
    /// (Note this is NOT the floater's 0.6 undated fallback. That number
    /// exists to let an undated task compete against OTHER KINDS inside
    /// `pickWinners`; here the comparison is only ever within one stakes
    /// tier, where "no deadline" should lose to "deadline".)
    ///
    /// **A task that has been named on the last
    /// `morningPromptMaxConsecutiveDays` mornings running steps aside**, so
    /// the next one down gets the slot. Stakes is a stable property of a
    /// task, so without this the same item wins every morning until it's
    /// done — and a notification that never changes is one the user learns
    /// to swipe without reading.
    ///
    /// **The step-aside is capped at one stakes tier.** Rotation is only
    /// worth having between tasks that could plausibly both be "the biggest
    /// thing"; handing the slot from a high-stakes task to a `.low` one
    /// produces "Biggest thing on your list: Clean my desk" while something
    /// that actually matters sits open, which is the app contradicting its
    /// own ranking in the slot the user reads first. **A repeat is better
    /// than a false claim**, so past one tier the incumbent keeps the slot
    /// and the notification simply repeats.
    ///
    /// Split out of the builder the same way `floaterTargets` was, so
    /// `debugMorningPromptImpact` prints the REAL selection instead of a
    /// paraphrase that can drift from it. `includeRepeatNamed: true` asks
    /// for the pre-rule ranking, which is what makes the before/after dump
    /// a comparison rather than an assertion.
    private func morningPromptRanking(
        fireDate: Date,
        includeRepeatNamed: Bool = false,
        modelContext: ModelContext
    ) -> [MorningPromptChoice] {
        // Same eligibility as every other task-naming builder: open, and
        // not an informational calendar event. No day-scoping — "the day's
        // biggest task" is the biggest thing on the list as of that
        // morning, which for an undated high-stakes item is still it.
        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete && !$0.isInformationalEvent }
        )
        descriptor.fetchLimit = 50
        let open = (try? modelContext.fetch(descriptor)) ?? []
        guard !open.isEmpty else { return [] }

        // The ranking with no no-repeat rule applied at all. Its first entry
        // is the INCUMBENT — the task pure stakes says should be named.
        let unconstrained = rankPool(open, fireDate: fireDate, modelContext: modelContext)
        guard !includeRepeatNamed else { return unconstrained }
        guard let incumbent = unconstrained.first else { return [] }

        // ── The no-repeat rule ───────────────────────────────────────────
        // The incumbent steps aside only if it has held the slot for
        // `morningPromptMaxConsecutiveDays` mornings running AND there is
        // something close enough in stakes to hand it to.
        guard wasNamedOnRecentMornings(incumbent.task, before: fireDate) else {
            return unconstrained
        }
        let fresh = open.filter { !wasNamedOnRecentMornings($0, before: fireDate) }
        let alternatives = rankPool(fresh, fireDate: fireDate, modelContext: modelContext)

        // FALLBACK ONE: nothing left to name. One open task, named twice —
        // the rule stands down rather than letting the day's anchor go
        // silent on the user who has exactly one thing on their list, which
        // is the user who needs it most.
        guard let replacement = alternatives.first else { return unconstrained }

        // FALLBACK TWO: the replacement is more than one stakes tier below
        // the incumbent. Then it isn't a replacement, it's a contradiction —
        // "Biggest thing on your list: Clean my desk" while a high-stakes
        // task sits open is the app arguing with its own ranking in the one
        // slot the user reads first. A repeat is better than a false claim,
        // so the incumbent keeps the slot.
        //
        // One tier, measured on `morningStakesRank`, which is why `nil`
        // sitting between `.medium` and `.low` matters here and not just in
        // the sort: high↔medium and nil↔low can rotate, high↔nil cannot.
        let gap = NudgeArbiter.morningStakesRank(incumbent.stakes)
            - NudgeArbiter.morningStakesRank(replacement.stakes)
        guard gap <= 1 else { return unconstrained }

        return alternatives
    }

    /// Ranks a pool of open tasks the morning prompt could name, best first:
    /// top stakes tier only, ordered by deadline proximity, UUID last for
    /// determinism.
    ///
    /// Split out of `morningPromptRanking` so the no-repeat rule can rank
    /// two pools — everything, and everything-not-recently-named — with one
    /// implementation. Comparing the two is what makes the rule's decision
    /// checkable rather than assertable.
    private func rankPool(
        _ pool: [NudgeTask],
        fireDate: Date,
        modelContext: ModelContext
    ) -> [MorningPromptChoice] {
        // Only the top stakes tier can win, so the tie-break is computed for
        // that tier alone — `DurationModel.estimate` is a SwiftData lookup
        // and this builder previously did none.
        let ranked = pool.map { ($0, NudgeArbiter.morningStakesRank($0.stakes)) }
        guard let topRank = ranked.map(\.1).max() else { return [] }
        let contenders = ranked.filter { $0.1 == topRank }.map(\.0)

        return contenders
            .map { task -> MorningPromptChoice in
                MorningPromptChoice(
                    task: task,
                    stakes: task.stakes,
                    urgency: morningDeadlineUrgency(
                        for: task,
                        at: fireDate,
                        modelContext: modelContext
                    )
                )
            }
            // Final key is the UUID string — not a preference, just
            // determinism. Without it two equally-urgent tasks swap places
            // between runs on fetch order alone, and a notification that
            // names a different task each reevaluate is indistinguishable
            // from a bug.
            .sorted {
                $0.urgency != $1.urgency
                    ? $0.urgency > $1.urgency
                    : $0.task.id.uuidString < $1.task.id.uuidString
            }
    }

    /// Whether the morning prompt named `task` on EVERY one of the
    /// `morningPromptMaxConsecutiveDays` days immediately before
    /// `fireDate`'s day.
    ///
    /// Deliberately "every one of the last N", not "any of the last N": the
    /// rule is about an unbroken run of identical mornings. A task named
    /// Monday and Wednesday isn't the failure mode — the user saw something
    /// else on Tuesday.
    ///
    /// A missing day counts as a break, which is the forgiving reading and
    /// the right one: a day with no prompt (busy day, quiet hours, phone
    /// off) is not evidence the user saw this task, so it shouldn't count
    /// toward suppressing it.
    ///
    /// Deadline-horizon alternative, and why this instead: a horizon would
    /// not have solved the stated problem. Undated tasks have to stay
    /// nameable (they're the ones most likely to rot), and they have no
    /// deadline for a horizon to bite on — so the exact case that motivated
    /// the rule would have been the one it couldn't reach. A horizon also
    /// doesn't make anything *vary*: a task due in four days still wins four
    /// mornings running.
    private func wasNamedOnRecentMornings(_ task: NudgeTask, before fireDate: Date) -> Bool {
        let window = NudgeConfig.morningPromptMaxConsecutiveDays
        guard window > 0 else { return false }
        let history = morningPromptHistory
        guard !history.isEmpty else { return false }

        let calendar = Calendar.current
        let fireDay = calendar.startOfDay(for: fireDate)
        let taskID = task.id.uuidString

        for daysBack in 1...window {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: fireDay) else {
                return false
            }
            if history[stamp(day)] != taskID { return false }
        }
        return true
    }

    /// Deadline proximity for the morning prompt's tie-break. 0 for an
    /// undated task — see `morningPromptRanking`.
    private func morningDeadlineUrgency(
        for task: NudgeTask,
        at fireDate: Date,
        modelContext: ModelContext
    ) -> Double {
        guard let deadline = task.specificTime ?? task.dueDate else { return 0 }
        let estimatedMinutes = DurationModel.shared.estimate(for: task, modelContext: modelContext)
        return EisenhowerScorer.urgency(
            hoursUntilDue: deadline.timeIntervalSince(fireDate) / 3600,
            effortHoursRemaining: Double(estimatedMinutes) / 60.0
        )
    }

    /// Sort key for `TaskStakes` in the morning prompt's selection.
    ///
    /// `nil` deliberately sorts ABOVE `.low`. Nil means "never classified"
    /// — the absence of evidence — while `.low` is a positive statement
    /// that this one is minor, which is the strongest possible argument
    /// against handing it the day's best delivery slot. Ranking nil last
    /// would also be the common case rather than an edge case: stakes is
    /// only written by the capture/import path, so most existing tasks
    /// carry nil and the slot would go to whatever hobby item happened to
    /// get labelled.
    private static func morningStakesRank(_ stakes: TaskStakes?) -> Int {
        switch stakes {
        case .high:   return 3
        case .medium: return 2
        case .none:   return 1
        case .low:    return 0
        }
    }

    /// The morning prompt's body: a statement of what the day's biggest item
    /// is, and when it's due.
    ///
    /// `DESIGN.md` tone rules this is written against — it's the first thing
    /// the user reads each day, so all three bite at once:
    ///   • **State the fact, don't ask.** The old copy asked a question and
    ///     spent the slot on it.
    ///   • **Propose, never promise.** No "do this and you'll be fine".
    ///   • **Never imply failure.** Hence the deadline clause is dropped
    ///     entirely for anything already past due at the fire time — "due
    ///     yesterday at 5 PM" is factually correct and reads as an
    ///     accusation before the user is out of bed. The task still gets
    ///     named; it just doesn't get dated.
    private static func morningPromptBody(for task: NudgeTask, fireDate: Date) -> String {
        let base = "Biggest thing on your list: \"\(task.title)\""
        guard let phrase = morningDeadlinePhrase(for: task, fireDate: fireDate) else {
            return base + "."
        }
        return base + " — \(phrase)."
    }

    /// "due today at 5:00 PM" / "due tomorrow" / "due Thu at 9:00 AM" /
    /// "due Aug 14". Nil when the task has no deadline, or when the deadline
    /// has already passed by the time the notification fires.
    ///
    /// A clock time is only ever shown when the task carries a
    /// `specificTime`; a bare `dueDate` is a day, and rendering its midnight
    /// as "at 12:00 AM" would invent a precision the task doesn't have.
    private static func morningDeadlinePhrase(for task: NudgeTask, fireDate: Date) -> String? {
        guard let deadline = task.specificTime ?? task.dueDate else { return nil }

        let calendar = Calendar.current
        // "Already passed" is measured at the deadline's OWN granularity.
        // A bare `dueDate` is a DAY, and its `Date` is that day's midnight —
        // so an instant comparison calls anything due today "overdue" from
        // 00:01 onwards and silently drops the clause for the single most
        // common case there is. Only a `specificTime` gets compared as an
        // instant.
        let stillAhead = task.specificTime != nil
            ? deadline > fireDate
            : calendar.startOfDay(for: deadline) >= calendar.startOfDay(for: fireDate)
        guard stillAhead else { return nil }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        let clock = task.specificTime.map { " at \(timeFmt.string(from: $0))" } ?? ""

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: fireDate),
            to: calendar.startOfDay(for: deadline)
        ).day ?? 0

        switch days {
        case 0:  return "due today\(clock)"
        case 1:  return "due tomorrow\(clock)"
        case 2...6:
            let dayFmt = DateFormatter()
            dayFmt.dateFormat = "EEEE"
            dayFmt.locale = Locale(identifier: "en_US_POSIX")
            return "due \(dayFmt.string(from: deadline))\(clock)"
        default:
            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "MMM d"
            dateFmt.locale = Locale(identifier: "en_US_POSIX")
            return "due \(dateFmt.string(from: deadline))"
        }
    }

    /// Idle / paralysis nudge — fires at wake+idleThreshold and asks "Have
    /// you gotten started on anything today?" with yes/no buttons.
    ///
    /// Suppressed when EITHER of the following happened in the 3-hour
    /// window leading up to the fire time:
    ///   1. A focus session was started
    ///   2. A task was completed (CompletedTaskRecord row in window)
    ///
    /// Both measure something the user actually DID. A third check — "a
    /// calendar event falls in the window" — was removed (Jul 2026): an
    /// event's existence is not evidence of activity, and with any morning
    /// class inside wake→wake+3h it suppressed the check-in on every
    /// school day — exactly the days a student needs it. After the
    /// day-rollover below it was worse still: TOMORROW'S class suppressed
    /// tomorrow's nudge during today's reevaluate, which the two real
    /// activity signals can't do (sessions and completions only exist in
    /// the past). "Don't fire during or right before class" was never this
    /// check's to enforce — the busy-window gate in `passesGates` does
    /// that against the candidate's fire date.
    ///
    /// Also suppressed for the rest of today if the user already tapped
    /// "Yes, I'm good" on a prior idle nudge — see `idleDismissedToday`.
    private func buildIdleCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.sessionStarterNotificationsEnabled else {
            #if DEBUG
            print("[NudgeArbiter] idle: SKIP — sessionStarterNotificationsEnabled is off.")
            #endif
            return []
        }
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        var todayComps = calendar.dateComponents([.year, .month, .day], from: Date())
        todayComps.hour = wakeComps.hour
        todayComps.minute = wakeComps.minute
        guard let todaysWake = calendar.date(from: todayComps) else { return [] }

        var fireDate = todaysWake.addingTimeInterval(NudgeConfig.idleThresholdHours * 60 * 60)
        if fireDate <= Date() {
            fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }
        #if DEBUG
        print("[NudgeArbiter] idle: wake=\(wake) → fireDate=\(fireDate) (wake + \(NudgeConfig.idleThresholdHours)h).")
        #endif

        // Suppress if user already said "Yes, I'm good" earlier today.
        if idleDismissedToday(for: fireDate) {
            #if DEBUG
            print("[NudgeArbiter] idle: SKIP — user already tapped 'Yes, I'm good' today.")
            #endif
            return []
        }

        // Activity window check — if the user has clearly been active in
        // the 3 hours leading up to the fire time, don't ask the question
        // at all. Both checks measure things the user actually did.
        let windowStart = fireDate.addingTimeInterval(-NudgeConfig.idleThresholdHours * 60 * 60)
        let windowEnd = fireDate
        if hadSessionStarted(in: windowStart...windowEnd) {
            #if DEBUG
            print("[NudgeArbiter] idle: SKIP — a focus session started in the pre-fire window.")
            #endif
            return []
        }
        if hadTaskCompletion(in: windowStart...windowEnd, modelContext: modelContext) {
            #if DEBUG
            print("[NudgeArbiter] idle: SKIP — a task was completed in the pre-fire window.")
            #endif
            return []
        }
        #if DEBUG
        // Before/after seam for the removed event-window rule (work-order
        // item 5): replay the old check and say when the two rules would
        // have disagreed, without letting it decide anything.
        if hadCalendarEvent(in: windowStart...windowEnd, modelContext: modelContext) {
            print("[NudgeArbiter] idle: BEFORE/AFTER — old event-window rule would have SUPPRESSED this candidate; new rule builds it (busy-window gate still applies at the fire moment).")
        }
        #endif

        // Find the highest-priority unstarted task to attach to the
        // outcome row. The notification copy itself doesn't name the task
        // anymore (the question is task-agnostic), but the row still
        // points at one so the per-task fatigue accounting works.
        //
        // Predicate-scoped + fetchLimit-capped to avoid bloating the shared
        // ModelContext on repeated reevaluations.
        var unstartedDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate { !$0.isComplete && !$0.isInformationalEvent }
        )
        unstartedDescriptor.fetchLimit = 50
        let unstarted = (try? modelContext.fetch(unstartedDescriptor)) ?? []
        // Prefer the next item in the user's ordered plan (lowest
        // sequenceIndex) — the plan's next step IS the answer to "what should
        // I start?". Fall back to score when there's no plan.
        let planNext = unstarted
            .filter { $0.sequenceIndex != nil }
            .min(by: { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) })
        guard let target = planNext ?? unstarted.sorted(by: { TaskSortComparator().compare($0, $1) }).first else {
            #if DEBUG
            print("[NudgeArbiter] idle: SKIP — no incomplete non-event task to attach to (add a task first).")
            #endif
            return []
        }
        #if DEBUG
        print("[NudgeArbiter] idle: OK — will schedule idle nudge for '\(target.title)' at \(fireDate).")
        #endif

        let estimatedMinutes = DurationModel.shared.estimate(for: target, modelContext: modelContext)
        let isDeepWork = StartByPlanner.isDeepWork(
            category: target.taskCategory,
            effortMinutes: estimatedMinutes
        )
        let signals = NudgeIntelligence.shared.cachedIntelligence(for: target, modelContext: modelContext)

        // Idle nudge urgency is evaluated AT the fire date, not now —
        // otherwise the score swings as the user opens the app earlier in
        // the day. If the target has no deadline we fall back to a moderate
        // urgency so the idle nudge still ranks reasonably.
        let urgency: Double
        if let deadline = target.specificTime ?? target.dueDate {
            urgency = EisenhowerScorer.urgency(
                hoursUntilDue: deadline.timeIntervalSince(fireDate) / 3600,
                effortHoursRemaining: Double(estimatedMinutes) / 60.0
            )
        } else {
            urgency = 0.6
        }
        let importance = EisenhowerScorer.importance(
            category: target.taskCategory,
            isDeepWork: isDeepWork,
            statedUrgency: signals.statedUrgency,
            hasDependencies: target.dependsOnTaskId != nil
        )

        let idleTier = tier(for: target, fireDate: fireDate)
        return [NudgeCandidate(
            id: "\(prefix)idle.\(stamp(calendar.startOfDay(for: fireDate)))",
            kind: .idle,
            fireDate: fireDate,
            title: "Checking in",
            body: "Have you gotten started on anything today?",
            categoryID: .idle,
            interruption: idleTier.interruption,
            taskID: target.id,
            tier: idleTier,
            urgency: urgency,
            importance: importance,
            receptivity: 1.0,
            countsAgainstBudget: true,
            estimatedMinutes: estimatedMinutes
        )]
    }

    // MARK: - Idle pre-fire window checks

    private func hadSessionStarted(in window: ClosedRange<Date>) -> Bool {
        guard let lastStart = SharedModelContainer.appGroupDefaults
            .object(forKey: NotificationScheduler.lastFocusSessionStartedAtKey) as? Date
        else { return false }
        return window.contains(lastStart)
    }

    private func hadTaskCompletion(
        in window: ClosedRange<Date>,
        modelContext: ModelContext
    ) -> Bool {
        let lower = window.lowerBound
        let upper = window.upperBound
        let descriptor = FetchDescriptor<CompletedTaskRecord>(
            predicate: #Predicate<CompletedTaskRecord> {
                $0.completedAt >= lower && $0.completedAt <= upper
            }
        )
        let hits = (try? modelContext.fetch(descriptor)) ?? []
        return !hits.isEmpty
    }

    #if DEBUG
    /// DEBUG-only since Jul 2026: survives solely as the before/after seam
    /// for the removed idle event-window rule. Nothing may consult it for a
    /// real decision — an event's existence is not evidence of activity.
    private func hadCalendarEvent(
        in window: ClosedRange<Date>,
        modelContext: ModelContext
    ) -> Bool {
        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.isInformationalEvent }
        )
        let events = (try? modelContext.fetch(descriptor)) ?? []
        return events.contains { event in
            guard let start = event.specificTime else { return false }
            return window.contains(start)
        }
    }
    #endif

    /// True if the user already tapped "Yes, I'm good" on today's idle
    /// nudge — the marker lives in shared UserDefaults and is keyed by
    /// today's day stamp. Set by `NudgeNotificationService` when the
    /// action is handled.
    private func idleDismissedToday(for fireDate: Date) -> Bool {
        let key = Self.idleDismissedKey(for: fireDate)
        return SharedModelContainer.appGroupDefaults.bool(forKey: key)
    }

    /// Shared key generator used by both this builder and the delegate
    /// that writes the marker.
    static func idleDismissedKey(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return "nudge.arb.idleDismissedFor.\(fmt.string(from: date))"
    }

    /// Exposed so the delegate (which lives in `NudgeNotificationService`)
    /// can write the "user said they're good" marker without poking at
    /// our private UserDefaults suite directly.
    static let idleDismissAppGroupID = "group.com.deblaser.nudge"

    /// Get-ahead nudge — for each open task with a `recommendedStartBy` in
    /// the future, schedule a nudge at that time.
    private func buildGetAheadCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.taskDueSoonNotificationsEnabled else { return [] }
        var openDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate { !$0.isComplete && !$0.isInformationalEvent }
        )
        openDescriptor.fetchLimit = 50
        let open = (try? modelContext.fetch(openDescriptor)) ?? []
        let now = Date()
        var candidates: [NudgeCandidate] = []

        for task in open {
            // Effort, startBy, isDeepWork, and sessionsNeeded come from
            // deterministic Swift. NudgeIntelligence contributes only the
            // extracted `statedUrgency` signal.
            guard let plan = StartByPlanner.plan(for: task, modelContext: modelContext, now: now) else {
                continue
            }
            guard let due = task.dueDate else { continue }
            // The planner picks the DAY; `getAheadFireDate` picks the hour
            // within it. Using `plan.startBy` directly is what put these
            // nudges at 21:59–23:59 — see the note on
            // `NudgeConfig.getAheadAnchorHoursAfterWake`.
            guard let fireDate = getAheadFireDate(
                startBy: plan.startBy,
                due: due,
                profile: profile,
                now: now
            ) else {
                #if DEBUG
                print("[NudgeArbiter] getAhead: SKIP '\(task.title)' — no anchored slot left before due \(due) (startBy was \(plan.startBy)).")
                #endif
                continue
            }
            #if DEBUG
            print("[NudgeArbiter] getAhead: '\(task.title)' startBy=\(plan.startBy) → fire=\(fireDate) (deep=\(plan.isDeepWork), due=\(due)).")
            #endif

            let estimatedMinutes = DurationModel.shared.estimate(for: task, modelContext: modelContext)
            let signals = NudgeIntelligence.shared.cachedIntelligence(for: task, modelContext: modelContext)

            // Urgency is evaluated AT the fire date — i.e., "how urgent will
            // this be when we ask the user to start?" Picking `now` would
            // produce an artificially low score for tasks whose startBy is
            // tomorrow.
            //
            // FLOOR at `urgentThreshold`: `StartByPlanner` has already
            // decided this is the moment to fire. If the logistic curve
            // says "still 4 days of slack, urgency = 0.02," that's the
            // curve being literal about deadline math — but the ARCHITECTURE
            // says a startBy nudge IS the urgency signal. Without this
            // floor, an unimportant errand outscores a 3-day-out exam
            // get-ahead in `pickWinners`, which is the opposite of what
            // an ADHD planner should do.
            let rawUrgency = EisenhowerScorer.urgency(
                hoursUntilDue: due.timeIntervalSince(fireDate) / 3600,
                effortHoursRemaining: Double(estimatedMinutes) / 60.0
            )
            let urgency = max(NudgeConfig.urgentThreshold, rawUrgency)
            let importance = EisenhowerScorer.importance(
                category: task.taskCategory,
                isDeepWork: plan.isDeepWork,
                statedUrgency: signals.statedUrgency,
                hasDependencies: task.dependsOnTaskId != nil
            )

            let daysOut = Calendar.current.dateComponents([.day], from: now, to: due).day ?? 0
            let sessions = plan.sessionsNeeded
            let body: String
            if plan.isDeepWork && daysOut > 1 {
                body = "Your deadline is in \(daysOut) days. At one session a day that's maybe \(sessions) real shots at \"\(task.title)\". Start session 1 now?"
            } else {
                body = "\"\(task.title)\" needs a start. Just \(min(estimatedMinutes, 25)) min — that's it."
            }

            let getAheadTier = tier(for: task, fireDate: fireDate)
            candidates.append(NudgeCandidate(
                id: "\(prefix)getAhead.\(task.id.uuidString)",
                kind: .getAhead,
                fireDate: fireDate,
                title: "Time to get ahead",
                body: body,
                categoryID: .getAhead,
                interruption: getAheadTier.interruption,
                taskID: task.id,
                tier: getAheadTier,
                urgency: urgency,
                importance: importance,
                receptivity: 1.0,
                countsAgainstBudget: true,
                estimatedMinutes: estimatedMinutes
            ))
        }
        return candidates
    }

    /// Maps `StartByPlanner`'s startBy INSTANT onto a sane hour of the same
    /// DAY: wake + `getAheadAnchorHoursAfterWake` on the day the planner
    /// picked. The planner's day math is untouched — only where in the day
    /// the nudge lands.
    ///
    /// ── ROLLOVER ──────────────────────────────────────────────────────
    /// `buildMorningPromptCandidates`, `buildIdleCandidates` and
    /// `buildFloaterCheckInCandidates` all share one idiom: compute
    /// today's wake-anchored time, and `if fireDate <= now` add exactly
    /// one day. One day is always enough for them because their anchor day
    /// is *today* by definition.
    /// Get-ahead's anchor day is derived from the deadline instead, so this
    /// generalises the same idiom into a bounded walk forward — same
    /// behaviour, just able to step more than once.
    ///
    /// The walk stops at the due date. Rolling past it would schedule a
    /// "get ahead" nudge for something already overdue, which is a
    /// different notification with a different message; returning nil lets
    /// the caller skip the task rather than send the wrong nudge. In
    /// practice the loop runs at most twice: any day strictly after today
    /// has its anchor in the future.
    private func getAheadFireDate(
        startBy: Date,
        due: Date,
        profile: UserProfile,
        now: Date
    ) -> Date? {
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        let offset = NudgeConfig.getAheadAnchorHoursAfterWake * 60 * 60

        func anchor(on day: Date) -> Date? {
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = wakeComps.hour
            comps.minute = wakeComps.minute
            guard let dayWake = calendar.date(from: comps) else { return nil }
            return dayWake.addingTimeInterval(offset)
        }

        let lastDay = calendar.startOfDay(for: due)
        // `StartByPlanner` already clamps startBy to `now`, so this is
        // normally a no-op — but the walk's bound reads clearer when the
        // start can't be in the past regardless of what the planner did.
        var day = max(calendar.startOfDay(for: startBy), calendar.startOfDay(for: now))

        while day <= lastDay {
            // `< due` matters on the due date itself: a task due at 08:00
            // has no useful anchor at wake+2h, and firing after the
            // deadline would be actively wrong.
            if let candidate = anchor(on: day), candidate > now, candidate < due {
                return candidate
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// Mid-day check-in for OPEN UNDATED tasks. Get-ahead nudges require a
    /// `dueDate` (the planner derives `startBy` from it), so chat-captured
    /// tasks like "study for biology" never produce any get-ahead candidate.
    /// Without this builder the user gets ONE idle nudge in the morning and
    /// then silence until bedtime — exactly the symptom of "the app doesn't
    /// ask if I'm working on something important."
    ///
    /// Fires at wake + `floaterCheckInHoursAfterWake` for every undated open
    /// task; the daily budget + min-spacing in `pickWinners` collapses it to
    /// the top-scoring one.
    ///
    /// Emits `.floater`, NOT `.getAhead`. It used to emit `.getAhead` — same
    /// kind, same category as `buildGetAheadCandidates` — which meant the two
    /// features' rows were indistinguishable in `NudgeOutcome` and neither
    /// could be measured. Its toggle was split off the same way: this reads
    /// `floaterCheckInNotificationsEnabled`, where it used to share
    /// `taskDueSoonNotificationsEnabled` with get-ahead.
    ///
    /// ── ROLLOVER ──────────────────────────────────────────────────────
    /// Now the same idiom as `buildMorningPromptCandidates` and
    /// `buildIdleCandidates`: compute today's wake-anchored time, and
    /// `if fireDate <= now` add one day.
    /// This builder used to be the odd one out — it gave up with
    /// `guard fireDate > Date() else { return [] }`, which is why `.floater`
    /// has never appeared in an outcome dump. `cancelAll` runs FIRST on
    /// every reevaluate, so any reevaluate past the anchor deleted the
    /// morning's scheduled check-in and then rebuilt nothing in its place.
    /// For a user who mostly opens the app in the afternoon or evening the
    /// nudge was unreachable, not merely rare.
    ///
    /// One day is always enough here, same as for morning and idle: the
    /// anchor day is *today* by definition (unlike get-ahead, whose anchor
    /// derives from a deadline and so needs the bounded walk in
    /// `getAheadFireDate`).
    ///
    /// Rolling is safe against double-firing without a delivered-marker like
    /// `eventReminderHistory`. The candidate ID embeds the FIRE day's stamp,
    /// so once today's anchor passes the rebuild carries tomorrow's ID —
    /// it can never re-add the ID the OS already delivered today.
    private func buildFloaterCheckInCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.floaterCheckInNotificationsEnabled else {
            #if DEBUG
            print("[NudgeArbiter] floater: SKIP — floaterCheckInNotificationsEnabled is off.")
            #endif
            return []
        }
        let calendar = Calendar.current
        guard var fireDate = floaterAnchor(on: Date(), profile: profile) else { return [] }
        if fireDate <= Date() {
            fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }

        let targeting = floaterTargets(
            fireDate: fireDate,
            excludePlacedOnFireDay: true,
            modelContext: modelContext
        )
        let candidateTasks = targeting.targets
        guard !candidateTasks.isEmpty else {
            #if DEBUG
            if targeting.placedOut.isEmpty {
                print("[NudgeArbiter] floater: SKIP — no open undated task to check in about.")
            } else {
                print("[NudgeArbiter] floater: SKIP — every open undated task is already "
                    + "placed on the fire day's timeline (\(targeting.placedOut.count)).")
            }
            #endif
            return []
        }
        #if DEBUG
        print("[NudgeArbiter] floater: fireDate=\(fireDate) "
            + "(wake + \(NudgeConfig.floaterCheckInHoursAfterWake)h) — "
            + "\(candidateTasks.count) target(s), "
            + "\(targeting.placedOut.count) excluded as already placed.")
        #endif

        var candidates: [NudgeCandidate] = []
        for task in candidateTasks {
            let estimatedMinutes = DurationModel.shared.estimate(for: task, modelContext: modelContext)
            let isDeepWork = StartByPlanner.isDeepWork(
                category: task.taskCategory,
                effortMinutes: estimatedMinutes
            )
            let signals = NudgeIntelligence.shared.cachedIntelligence(for: task, modelContext: modelContext)
            let importance = EisenhowerScorer.importance(
                category: task.taskCategory,
                isDeepWork: isDeepWork,
                statedUrgency: signals.statedUrgency,
                hasDependencies: task.dependsOnTaskId != nil
            )

            let cTier = tier(for: task, fireDate: fireDate)
            let body = "'\(task.title)' is still open. Just \(min(estimatedMinutes, 25)) min — start there?"
            candidates.append(NudgeCandidate(
                id: "\(prefix)floater.\(stamp(calendar.startOfDay(for: fireDate))).\(task.id.uuidString)",
                kind: .floater,
                fireDate: fireDate,
                title: "Are you working on something?",
                body: body,
                categoryID: .floater,
                interruption: cTier.interruption,
                taskID: task.id,
                tier: cTier,
                // Undated tasks don't have a logistic-curve urgency; use the
                // same 0.6 fallback `buildIdleCandidates` uses for floaters.
                urgency: 0.6,
                importance: importance,
                receptivity: 1.0,
                countsAgainstBudget: true,
                estimatedMinutes: estimatedMinutes
            ))
        }
        return candidates
    }

    /// The floater check-in's fire-time anchor on `day`: that day's wake
    /// clock time + `floaterCheckInHoursAfterWake`. Only the hour/minute of
    /// the profile's wake time are read, so any day can be anchored.
    private func floaterAnchor(on day: Date, profile: UserProfile) -> Date? {
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = wakeComps.hour
        comps.minute = wakeComps.minute
        guard let dayWake = calendar.date(from: comps) else { return nil }
        return dayWake.addingTimeInterval(
            NudgeConfig.floaterCheckInHoursAfterWake * 60 * 60
        )
    }

    /// Which open undated tasks the floater check-in should target for a
    /// nudge firing at `fireDate`, plus the ones it deliberately dropped.
    ///
    /// Split out of `buildFloaterCheckInCandidates` so the DEBUG before/after
    /// dump can ask for the OLD targeting (`excludePlacedOnFireDay: false`)
    /// against the exact code the builder runs, rather than a paraphrase of
    /// it that can drift.
    ///
    /// ── WHY PLACED TASKS ARE EXCLUDED ─────────────────────────────────
    /// The fetch is `!isComplete && !isInformationalEvent && dueDate == nil`
    /// and used to stop there — it never looked at `plannedStartDate`. But
    /// `planMyDay()` places open non-event tasks including undated ones, and
    /// so does manual placement, so the check-in would announce that a task
    /// "is still open" at 14:00 when the user has it on the timeline for
    /// 16:00. A task on the timeline is not floating.
    ///
    /// Scoped to the FIRE DAY, not `plannedStartDate != nil`. A placement is
    /// a slot on one specific day (`PlacementRollover` clears them once that
    /// day has passed), so the only question that matters is whether the task
    /// is on the timeline for the day the nudge will actually fire — a
    /// blanket nil-check would also exclude tasks placed on a DIFFERENT day
    /// than the one being evaluated.
    ///
    /// Exclusion runs BEFORE the plan-next collapse on purpose: picking the
    /// lowest `sequenceIndex` first and filtering after would return nothing
    /// whenever the plan's next item happens to be placed, even with other
    /// unplaced plan floaters available.
    private func floaterTargets(
        fireDate: Date,
        excludePlacedOnFireDay: Bool,
        modelContext: ModelContext
    ) -> (targets: [NudgeTask], placedOut: [NudgeTask]) {
        var floaterDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                !task.isComplete && !task.isInformationalEvent && task.dueDate == nil
            }
        )
        floaterDescriptor.fetchLimit = 50
        let floaters = (try? modelContext.fetch(floaterDescriptor)) ?? []

        let calendar = Calendar.current
        var eligible = floaters
        var placedOut: [NudgeTask] = []
        if excludePlacedOnFireDay {
            placedOut = floaters.filter { task in
                guard let placed = task.plannedStartDate else { return false }
                return calendar.isDate(placed, inSameDayAs: fireDate)
            }
            let placedIDs = Set(placedOut.map(\.id))
            eligible = floaters.filter { !placedIDs.contains($0.id) }
        }

        // If the user has an ordered plan, the check-in should point at the
        // plan's NEXT item (lowest sequenceIndex) rather than an arbitrary
        // undated task. Otherwise fall back to all floaters.
        let planFloaters = eligible.filter { $0.sequenceIndex != nil }
        if let planNext = planFloaters.min(by: { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }) {
            return (targets: [planNext], placedOut: placedOut)
        }
        return (targets: eligible, placedOut: placedOut)
    }

    // MARK: - Gates

    private struct GateContext {
        let profile: UserProfile
        let modelContext: ModelContext
        let now: Date
    }

    private func passesGates(_ candidate: NudgeCandidate, context: GateContext) -> Bool {
        // Active session — suppresses a nudge only if the nudge would ARRIVE
        // during the session, and never touches budget-exempt candidates.
        if candidate.countsAgainstBudget && firesDuringActiveSession(candidate.fireDate) {
            return false
        }

        // Cooldown — a recent session start suppresses discretionary
        // candidates that would land while it's still running. Event blocks
        // are factual reminders and pass anyway.
        if candidate.countsAgainstBudget && firesInsideActivityCooldown(candidate.fireDate) {
            return false
        }

        // Quiet hours — the user's own "don't interrupt me" window, which is
        // NOT the same thing as their sleep schedule (it only defaults to it).
        if candidate.countsAgainstBudget && !passesQuietHours(
            fireDate: candidate.fireDate,
            profile: context.profile
        ) { return false }

        // Event-conflict gate — no discretionary nudges during class,
        // appointments, or the post-event tail buffer / cramped commute
        // between back-to-back events. Event-block reminders themselves
        // bypass (they fire BEFORE the event, not during).
        if candidate.countsAgainstBudget,
           BusyWindowResolver.shared.isBusy(at: candidate.fireDate, modelContext: context.modelContext) {
            return false
        }

        // Per-task fatigue — if this task has been nudged perTaskMaxNudges
        // times without action, suppress further pushes for it. (The
        // break-it-down offer used to be the escape hatch that survived
        // this gate; the kind was removed Jul 2026, so past the threshold
        // the arbiter now simply backs off the task.)
        //
        // GATED OFF (`NudgeConfig.fatigueGateEnabled`). The outcome
        // classifier now writes real `.ignored` rows, which this predicate
        // already matches — so without the flag, landing the classifier
        // would have immediately changed which notifications fire. The
        // recorded classifications get observed first.
        //
        // One exemption: `!kind.successIsObservableInApp` (today:
        // `.eventBlock`) — a CORRECTNESS exemption. Those kinds' success
        // case produces no app open, so the classifier logs `.ignored` for
        // a reminder that worked exactly as intended. Counting that as
        // fatigue would silence event reminders for the user who reads
        // every one of them and shows up on time. See
        // `successIsObservableInApp`.
        if NudgeConfig.fatigueGateEnabled,
           candidate.kind.successIsObservableInApp,
           let taskID = candidate.taskID,
           taskFatigueCount(taskID: taskID, context: context) >= NudgeConfig.perTaskMaxNudges {
            return false
        }

        return true
    }

    /// Whether `fireDate` lands inside the currently-running focus session.
    ///
    /// ── THE THIRD INSTANCE OF ONE BUG ─────────────────────────────────
    /// This gate used to be `if SessionCoordinator.shared.isSessionActive
    /// { return false }` — an unconditional bail that dropped EVERY
    /// candidate in the reevaluate. Two things were wrong with it, and they
    /// are independent:
    ///
    ///   1. **It read the clock, not the candidate.** A session at 14:00
    ///      killed a nudge scheduled for next Tuesday. Same mistake as
    ///      `hadRecentActivity`, fixed one line below this one; the session
    ///      even has a known end time, so there was nothing to approximate.
    ///   2. **It ignored `countsAgainstBudget`.** Every other gate in
    ///      `passesGates` exempts factual/anchor nudges through that flag;
    ///      this one didn't, so a focus session at 14:00 also swallowed the
    ///      15:00 pre-class heads-up. That is precisely backwards — a
    ///      factual reminder is what someone heads-down in a session most
    ///      needs, and it's the one nudge that can't be rebuilt in time if
    ///      it's dropped near its own fire moment.
    ///
    /// Both are now handled at the call site: the `countsAgainstBudget`
    /// check exempts event blocks (and the morning prompt, which is
    /// budget-exempt for the same "this is an anchor, not a nudge" reason),
    /// and this function answers the per-candidate question.
    ///
    /// `sessionEnd` is the session's own end instant, so no config constant
    /// is involved — unlike the cooldown below, the window here is exactly
    /// as long as the session is. A stale `sessionEnd` left over from a
    /// finished session is always in the past and therefore inert, and
    /// `startSession` now sets it BEFORE it triggers its reevaluate so this
    /// gate never reads a session's end as `.distantPast` while its
    /// `isSessionActive` is already true.
    private func firesDuringActiveSession(_ fireDate: Date) -> Bool {
        guard SessionCoordinator.shared.isSessionActive else { return false }
        return fireDate < SessionCoordinator.shared.sessionEnd
    }

    /// Whether `fireDate` lands inside the cooldown that follows the most
    /// recent focus-session start.
    ///
    /// ── THE RULE, AND WHY THIS ONE ────────────────────────────────────
    /// The cooldown means "don't nudge someone who just started working."
    /// It is therefore a property of the MOMENT THE NUDGE ARRIVES, not of
    /// the moment the arbiter happens to run — so the window it defines is
    /// `[lastStart, lastStart + recentActivityCooldownMinutes)` and a
    /// candidate is blocked exactly when its fire date falls inside it.
    ///
    /// That is the whole rule. It needs no separate "firing soon"
    /// threshold: the window is bounded by construction, so anything
    /// scheduled past its end passes, and in practice only candidates
    /// within the next `recentActivityCooldownMinutes` can ever be caught.
    ///
    /// ── WHAT IT REPLACED ──────────────────────────────────────────────
    /// This used to be `hadRecentActivity(now:)` — it asked whether a
    /// session had started within the cooldown of NOW, and if so dropped
    /// EVERY budget-counting candidate in that reevaluate, including ones
    /// scheduled for tomorrow that the session has no bearing on. Not fatal
    /// (the next reevaluate rebuilt them) but it produced intermittent gate
    /// blocks unrelated to any candidate's own timing, and it was landing
    /// on the floater check-in — whose anchor is wake+6h — while
    /// `ROADMAP.md` §1 waits on floater baseline rows. Listed as a known
    /// bug in `CLAUDE.md` until Jul 2026.
    ///
    /// ── WHAT IT STILL CAN'T DO ────────────────────────────────────────
    /// The app group holds only the MOST RECENT session start, so this can
    /// only ever reason about one window. A session started this morning is
    /// invisible once a second one starts. That's accepted, not overlooked:
    /// building a session log for this gate is explicitly out of scope, and
    /// the failure direction is permissive (a nudge that should have been
    /// suppressed gets through), which is the safe one while nothing
    /// consumes outcome data.
    private func firesInsideActivityCooldown(_ fireDate: Date) -> Bool {
        guard let lastStart = SharedModelContainer.appGroupDefaults
            .object(forKey: NotificationScheduler.lastFocusSessionStartedAtKey) as? Date else {
            return false
        }
        guard let cooldownEnds = Calendar.current.date(
            byAdding: .minute,
            value: NudgeConfig.recentActivityCooldownMinutes,
            to: lastStart
        ) else { return false }
        // Half-open on purpose: a candidate firing exactly as the cooldown
        // expires is outside it, matching the old form's `lastStart > cutoff`
        // strict comparison at the other end of the same window.
        return fireDate >= lastStart && fireDate < cooldownEnds
    }

    // MARK: - Quiet hours

    /// The quiet window as CLOCK MINUTES-OF-DAY (0...1439), not as absolute
    /// dates on a particular day.
    ///
    /// Minutes-of-day rather than `Date`s is the whole fix. The previous
    /// implementation pinned wake and bedtime onto the fire date's calendar
    /// day and asked `fire >= wake+30 && fire <= bed−60`. That silently
    /// assumes the awake window doesn't cross midnight — so a bedtime at or
    /// past 00:00 put `bed−60` an hour into the PREVIOUS day, made the
    /// window empty, and the gate failed CLOSED: every discretionary
    /// candidate suppressed, all day, with no diagnostic.
    /// `BusyWindowResolver.dayLoad` hits the same degeneracy and returns nil
    /// so callers fail OPEN; this gate had no such guard.
    ///
    /// A wrapping interval has no such blind spot: `start > end` is the
    /// NORMAL case (quiet 22:00 → 07:30), not an error, and quiet hours that
    /// sit inside one day (a 13:00–14:00 nap) are just the other branch.
    private struct QuietWindow {
        /// Clock minute quiet BEGINS.
        let startMinute: Int
        /// Clock minute quiet ENDS.
        let endMinute: Int
        /// `"sleep"` or `"custom"` — DEBUG labelling only.
        let source: String

        /// Whether `date`'s clock time falls inside quiet hours.
        ///
        /// Both comparisons are STRICT, so a fire time landing exactly on a
        /// boundary minute is treated as awake. That's deliberate: the old
        /// gate's `fire >= quietUntil && fire <= quietFrom` passed both
        /// boundaries, and this preserves it minute-for-minute so the
        /// default-configuration before/after is a true no-op.
        func contains(_ date: Date) -> Bool {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            if startMinute > endMinute {
                // Wraps midnight — the normal overnight case.
                return minute > startMinute || minute < endMinute
            }
            return minute > startMinute && minute < endMinute
        }

        var description: String {
            func hhmm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
            return "\(hhmm(startMinute))→\(hhmm(endMinute)) (\(source)"
                + (startMinute > endMinute ? ", wraps midnight)" : ")")
        }
    }

    private static func minuteOfDay(_ date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Wraps a possibly out-of-range minute count back into 0...1439, so
    /// `bedtime − 60m` off a 00:30 bedtime lands on 23:30 instead of −30.
    private static func wrapMinute(_ minute: Int) -> Int {
        ((minute % 1440) + 1440) % 1440
    }

    /// The quiet window the sleep schedule implies. Also what Settings seeds
    /// the custom times from, so flipping the toggle alone changes nothing.
    static func sleepDerivedQuietHours(for profile: UserProfile) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let startMinute = wrapMinute(minuteOfDay(profile.bedtime) - NudgeConfig.preBedtimeQuietMinutes)
        let endMinute = wrapMinute(minuteOfDay(wake) + NudgeConfig.postWakeQuietMinutes)
        let today = calendar.startOfDay(for: Date())
        return (
            start: calendar.date(byAdding: .minute, value: startMinute, to: today) ?? today,
            end: calendar.date(byAdding: .minute, value: endMinute, to: today) ?? today
        )
    }

    /// Resolves the profile's quiet window, or nil when it can't be
    /// expressed — which the caller must treat as FAIL OPEN.
    ///
    /// The only nil case is a zero-length window (`start == end`), which is
    /// genuinely ambiguous: it reads equally as "never quiet" and "always
    /// quiet". Silencing every discretionary nudge on an ambiguous setting
    /// is the failure mode this whole change exists to remove, so it
    /// resolves the other way.
    private func quietWindow(for profile: UserProfile) -> QuietWindow? {
        let startMinute: Int
        let endMinute: Int
        let source: String

        // Custom needs BOTH ends. A half-configured window falls back to the
        // derived one rather than pairing a user value with a guess.
        if !profile.quietHoursFollowSleepSchedule,
           let customStart = profile.quietHoursStartTime,
           let customEnd = profile.quietHoursEndTime {
            startMinute = Self.minuteOfDay(customStart)
            endMinute = Self.minuteOfDay(customEnd)
            source = "custom"
        } else {
            let derived = Self.sleepDerivedQuietHours(for: profile)
            startMinute = Self.minuteOfDay(derived.start)
            endMinute = Self.minuteOfDay(derived.end)
            source = "sleep"
        }

        guard startMinute != endMinute else { return nil }
        return QuietWindow(startMinute: startMinute, endMinute: endMinute, source: source)
    }

    /// Whether `fireDate` is clear of quiet hours. Fails OPEN — an
    /// unresolvable window permits the nudge.
    private func passesQuietHours(fireDate: Date, profile: UserProfile) -> Bool {
        guard let window = quietWindow(for: profile) else {
            #if DEBUG
            print("[NudgeArbiter] quiet hours: UNRESOLVABLE (zero-length window) — failing OPEN.")
            #endif
            return true
        }
        return !window.contains(fireDate)
    }

    private func taskFatigueCount(taskID: UUID, context: GateContext) -> Int {
        // Scoped to the fatigue window — without the date bound, this
        // returns more rows over time forever, and is called once per
        // gate-evaluated candidate per reevaluate.
        let fatigueCutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        // Rows whose kind can't distinguish success from silence are
        // excluded at the predicate level, not filtered afterwards — the
        // fetchLimit below is what keeps this cheap, and post-filtering a
        // limited fetch would undercount. See `successIsObservableInApp`.
        let blindKinds = NudgeOutcomeKind.fatigueBlindRawValues
        var descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> {
                $0.taskID == taskID
                    && $0.scheduledFor >= fatigueCutoff
                    && !blindKinds.contains($0.kindRaw)
                    && ($0.resultRaw == "ignored" || $0.resultRaw == "dismissed")
            }
        )
        descriptor.fetchLimit = NudgeConfig.perTaskMaxNudges + 1
        return (try? context.modelContext.fetch(descriptor))?.count ?? 0
    }

    // MARK: - DEBUG: stakes impact

    #if DEBUG
    /// Kinds whose builder hardcodes `importance` instead of deriving it
    /// from `EisenhowerScorer.importance`. Both pin 1.0: event blocks are
    /// factual time reminders and the morning prompt is the day's anchor,
    /// and both are budget-exempt, so neither competes on score. Stakes can
    /// never move them — no call path would pass it — which is why the
    /// dump labels them `pinned` rather than comparing.
    private static let importancePinnedKinds: Set<NudgeOutcomeKind> = [.eventBlock, .morningPrompt]

    /// Prints every candidate's importance / score / quadrant computed BOTH
    /// with and without the `TaskStakes` term, then the winner set each
    /// would produce. Read-only — it recomputes into locals and schedules
    /// nothing.
    ///
    /// Exists because `EisenhowerScorer.importance` does not yet receive
    /// `stakes` from any production call site. This is what the weights in
    /// `NudgeConfig.stakesImportanceBonus` get validated against before
    /// they're wired in: the interesting output is not the numbers but
    /// WHICH nudge wins, since get-ahead candidates now share one fire time
    /// and min-spacing collapses same-day candidates to a single winner.
    ///
    /// The `built` column re-derives the CURRENT importance from the same
    /// inputs the builder used and should equal the candidate's own value.
    /// A mismatch means this recomputation has drifted from the builder and
    /// the comparison can't be trusted — which is why it's printed rather
    /// than assumed.
    private func debugStakesImpact(
        all: [NudgeCandidate],
        eligible: [NudgeCandidate],
        context: GateContext
    ) {
        let scored = all.map { cand in
            (cand: cand, inputs: stakesInputs(for: cand, modelContext: context.modelContext))
        }
        guard scored.contains(where: { $0.inputs != nil }) else {
            print("[StakesImpact] No candidate has an associated task — nothing to compare.")
            return
        }

        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        func q(_ quadrant: EisenhowerQuadrant) -> String {
            switch quadrant {
            case .startNow:    return "startNow"
            case .quickWin:    return "quickWin"
            case .getAhead:    return "getAhead"
            case .lowPriority: return "lowPri"
            }
        }

        print("[StakesImpact] cap=\(f(NudgeConfig.stakesSignalCombinedCap)) "
            + "high=\(f(NudgeConfig.stakesImportanceBonus[.high] ?? 0)) "
            + "med=\(f(NudgeConfig.stakesImportanceBonus[.medium] ?? 0)) "
            + "low=\(f(NudgeConfig.stakesImportanceBonus[.low] ?? 0))")
        print("  \(padc("KIND", 13))\(padc("STAKES", 8))\(padc("GATE", 6))"
            + "\(padc("built", 7))\(padc("imp→", 7))\(padc("imp+", 7))"
            + "\(padc("score→", 8))\(padc("score+", 8))\(padc("quad→", 9))\(padc("quad+", 9))TASK")

        var adjustedByID: [String: Double] = [:]
        /// Eligible, budget-competing candidates and the stakes term each
        /// would receive — the raw material for the contest test below.
        /// Budget-exempt candidates are excluded because they don't compete
        /// on score at all, and gate-blocked ones because they're already
        /// out before scoring matters.
        var contenders: [(fireDate: Date, term: Double, title: String, kind: String)] = []
        for entry in scored {
            let cand = entry.cand
            guard let inputs = entry.inputs else { continue }
            let gated = eligible.contains { $0.id == cand.id }

            // Kinds whose builder PINS importance never call
            // `EisenhowerScorer.importance`, so recomputing it from category
            // disagrees by construction — that is not drift, and flagging it
            // as such on every run trains the reader to ignore the column.
            // They also can't be moved by stakes: nothing would pass it.
            if Self.importancePinnedKinds.contains(cand.kind) {
                print("  " + padc(cand.kind.rawValue, 13)
                    + padc(inputs.stakes?.rawValue ?? "—", 8)
                    + padc(gated ? "pass" : "BLOCK", 6)
                    + padc("pinned", 7)
                    + padc(f(cand.importance), 7)
                    + padc("—", 7)
                    + padc(f(cand.score), 8)
                    + padc("—", 8)
                    + padc(q(cand.quadrant), 9)
                    + padc("—", 9)
                    + inputs.title)
                continue
            }

            let without = EisenhowerScorer.importance(
                category: inputs.category,
                isDeepWork: inputs.isDeepWork,
                statedUrgency: inputs.statedUrgency,
                hasDependencies: inputs.hasDependencies
            )
            let with = EisenhowerScorer.importance(
                category: inputs.category,
                isDeepWork: inputs.isDeepWork,
                statedUrgency: inputs.statedUrgency,
                hasDependencies: inputs.hasDependencies,
                stakes: inputs.stakes
            )
            adjustedByID[cand.id] = with

            let scoreWithout = EisenhowerScorer.score(urgency: cand.urgency, importance: without)
            let scoreWith    = EisenhowerScorer.score(urgency: cand.urgency, importance: with)
            let quadWithout  = EisenhowerScorer.quadrant(urgency: cand.urgency, importance: without)
            let quadWith     = EisenhowerScorer.quadrant(urgency: cand.urgency, importance: with)

            let builtMatches = abs(cand.importance - without) < 0.0005
            let stakesTerm = inputs.stakes.flatMap { NudgeConfig.stakesImportanceBonus[$0] } ?? 0.0
            if gated && cand.countsAgainstBudget {
                contenders.append((cand.fireDate, stakesTerm, inputs.title, cand.kind.rawValue))
            }

            print("  " + padc(cand.kind.rawValue, 13)
                + padc(inputs.stakes?.rawValue ?? "—", 8)
                + padc(gated ? "pass" : "BLOCK", 6)
                + padc(builtMatches ? "ok" : "DRIFT", 7)
                + padc(f(without), 7)
                + padc(f(with), 7)
                + padc(f(scoreWithout), 8)
                + padc(f(scoreWith), 8)
                + padc(q(quadWithout), 9)
                + padc(q(quadWith), 9)
                + inputs.title)
            if !builtMatches {
                print("       ↳ DRIFT: candidate was built with importance "
                    + "\(f(cand.importance)), this recomputation says \(f(without)).")
            }
        }

        // ── Which nudges actually flip ───────────────────────────────────
        // The only question that matters: same gates, same spacing, same
        // budget — does a different notification get sent?
        let adjustedEligible = eligible.map { cand -> NudgeCandidate in
            guard let newImportance = adjustedByID[cand.id] else { return cand }
            return NudgeCandidate(
                id: cand.id, kind: cand.kind, fireDate: cand.fireDate,
                title: cand.title, body: cand.body, categoryID: cand.categoryID,
                interruption: cand.interruption, taskID: cand.taskID, tier: cand.tier,
                urgency: cand.urgency, importance: newImportance,
                receptivity: cand.receptivity,
                countsAgainstBudget: cand.countsAgainstBudget,
                estimatedMinutes: cand.estimatedMinutes
            )
        }
        let winnersNow  = pickWinners(from: eligible, context: context)
        let winnersWith = pickWinners(from: adjustedEligible, context: context)

        let idsNow  = Set(winnersNow.map(\.id))
        let idsWith = Set(winnersWith.map(\.id))
        print("  → winners now  (\(winnersNow.count)): "
            + winnersNow.map { "\($0.kind.rawValue)/\($0.title)" }.joined(separator: " | "))
        print("  → winners with (\(winnersWith.count)): "
            + winnersWith.map { "\($0.kind.rawValue)/\($0.title)" }.joined(separator: " | "))
        if idsNow == idsWith {
            // "NO FLIP" is ambiguous on its own: it can mean the weights
            // are too weak to matter, OR that nothing in today's data could
            // have moved regardless. Those call for opposite responses, so
            // say which one this is.
            //
            // A non-zero stakes term is NOT enough to make a run
            // informative, which is what this used to claim. Stakes only
            // ever changes an outcome by REORDERING two candidates that
            // contest the same slot — and `pickWinners` only ever compares
            // candidates within `minNudgeSpacingMinutes` of each other. Four
            // `.low` floaters at one fire time all shift by the same amount:
            // their relative order is arithmetically fixed no matter what
            // the weights are, so "the winner didn't change" was guaranteed
            // before the data was read. Claiming that as evidence the
            // weights are too small would be reading a tautology as a
            // measurement.
            //
            // So evidence requires a genuine contest: two eligible,
            // budget-competing candidates within the spacing window of each
            // other carrying DIFFERENT terms. ("Different" implies at least
            // one is non-zero, so that condition is subsumed.)
            let sorted = contenders.sorted { $0.fireDate < $1.fireDate }
            var contests: [(String, String)] = []
            for i in sorted.indices {
                for j in sorted.index(after: i)..<sorted.endIndex {
                    let gap = sorted[j].fireDate.timeIntervalSince(sorted[i].fireDate)
                    // Sorted by fire date, so once one pair is out of range
                    // every later one is too.
                    guard gap < Double(NudgeConfig.minNudgeSpacingMinutes) * 60 else { break }
                    guard abs(sorted[i].term - sorted[j].term) > 0.0005 else { continue }
                    contests.append((
                        "\(sorted[i].kind)/\(sorted[i].title) (\(f(sorted[i].term)))",
                        "\(sorted[j].kind)/\(sorted[j].title) (\(f(sorted[j].term)))"
                    ))
                }
            }

            if contests.isEmpty {
                let nonZero = contenders.filter { $0.term != 0 }.count
                let detail: String
                if nonZero == 0 {
                    detail = "no eligible budget-competing candidate carries a non-zero "
                        + "stakes term — every one is medium/unclassified (bonus 0.0), "
                        + "gate-blocked, or budget-exempt"
                } else {
                    detail = "\(nonZero) eligible candidate(s) carry a non-zero stakes term, "
                        + "but no two candidates within \(NudgeConfig.minNudgeSpacingMinutes)m "
                        + "of each other carry DIFFERENT terms. Every group that competes "
                        + "shifts by the same amount, so its internal order can't change at "
                        + "any weight"
                }
                print("  → NO FLIP — but VACUOUSLY: \(detail). This run exercised nothing — "
                    + "it is not evidence the weights are too small.")
            } else {
                print("  → NO FLIP — and this one IS evidence: \(contests.count) real "
                    + "contest(s) — candidates within \(NudgeConfig.minNudgeSpacingMinutes)m "
                    + "of each other with different stakes terms — and the winner still "
                    + "didn't change.")
                for (a, b) in contests.prefix(5) {
                    print("       ↳ contested: \(a)  vs  \(b)")
                }
            }
        } else {
            for lost in winnersNow where !idsWith.contains(lost.id) {
                print("  → FLIP OUT: \(lost.kind.rawValue) '\(lost.title)' no longer wins.")
            }
            for gained in winnersWith where !idsNow.contains(gained.id) {
                print("  → FLIP IN:  \(gained.kind.rawValue) '\(gained.title)' wins instead.")
            }
        }
    }

    /// The exact importance inputs a builder used for this candidate.
    ///
    /// `isDeepWork` is reconstructed the way the builders compute it:
    /// idle / get-ahead / floater all derive it from
    /// `StartByPlanner.isDeepWork` over the same `DurationModel` estimate
    /// the candidate already carries. Getting this wrong would silently
    /// change the "without" baseline and make the whole comparison lie.
    private func stakesInputs(
        for candidate: NudgeCandidate,
        modelContext: ModelContext
    ) -> (title: String, category: TaskCategory?, isDeepWork: Bool,
          statedUrgency: StatedUrgency, hasDependencies: Bool, stakes: TaskStakes?)? {
        guard let taskID = candidate.taskID else { return nil }
        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.id == taskID }
        )
        descriptor.fetchLimit = 1
        guard let task = (try? modelContext.fetch(descriptor))?.first else { return nil }

        let isDeepWork = StartByPlanner.isDeepWork(
            category: task.taskCategory,
            effortMinutes: candidate.estimatedMinutes
                ?? DurationModel.shared.estimate(for: task, modelContext: modelContext)
        )
        let signals = NudgeIntelligence.shared.cachedIntelligence(for: task, modelContext: modelContext)
        return (
            title: task.title,
            category: task.taskCategory,
            isDeepWork: isDeepWork,
            statedUrgency: signals.statedUrgency,
            hasDependencies: task.dependsOnTaskId != nil,
            stakes: task.stakes
        )
    }

    // MARK: - DEBUG: quiet-hours decoupling impact

    /// The gate EXACTLY as it stood before quiet hours were decoupled from
    /// the sleep schedule. Copied verbatim, not re-expressed — the point of
    /// the comparison is to catch a difference I didn't intend, and a
    /// "tidied" baseline can't do that.
    ///
    /// Note what it does on a past-midnight bedtime: `bedOnDay` lands at
    /// e.g. 00:30 on the FIRE day, so `quietFrom` is 23:30 the day BEFORE,
    /// `quietUntil` is that morning, and `fire >= quietUntil && fire <=
    /// quietFrom` is unsatisfiable. Every discretionary candidate, blocked,
    /// every day. That's the failure this reproduces on purpose.
    private func legacyInsideAwakeWindow(fireDate: Date, profile: UserProfile) -> Bool {
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let bedtime = profile.bedtime

        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        let bedComps  = calendar.dateComponents([.hour, .minute], from: bedtime)
        var dayComps  = calendar.dateComponents([.year, .month, .day], from: fireDate)

        dayComps.hour = wakeComps.hour
        dayComps.minute = wakeComps.minute
        guard let wakeOnDay = calendar.date(from: dayComps) else { return true }
        let quietUntil = wakeOnDay.addingTimeInterval(Double(NudgeConfig.postWakeQuietMinutes) * 60)

        dayComps.hour = bedComps.hour
        dayComps.minute = bedComps.minute
        guard let bedOnDay = calendar.date(from: dayComps) else { return true }
        let quietFrom = bedOnDay.addingTimeInterval(-Double(NudgeConfig.preBedtimeQuietMinutes) * 60)

        return fireDate >= quietUntil && fireDate <= quietFrom
    }

    /// Before/after for the quiet-hours decoupling, per the "any change that
    /// alters what the arbiter does gets a DEBUG comparison on real data"
    /// rule. Read-only: it re-derives into locals and schedules nothing.
    ///
    /// OLD is `legacyInsideAwakeWindow` above. NEW is `passesQuietHours`.
    /// Only budget-counting candidates are compared, because that's the only
    /// population the gate has ever been applied to — event blocks and the
    /// morning prompt are `countsAgainstBudget: false` and skip it entirely,
    /// so listing them as "unchanged" would pad the diff with rows that
    /// could never differ.
    ///
    /// On a default profile (`quietHoursFollowSleepSchedule == true`, an
    /// evening bedtime) this MUST print no differences — that is the
    /// "nothing changes for existing users" claim, checked rather than
    /// asserted. A diff here on a default profile is a bug in this change.
    private func debugQuietHoursImpact(all: [NudgeCandidate], context: GateContext) {
        let profile = context.profile
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE h:mm a"

        let derived = Self.sleepDerivedQuietHours(for: profile)
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        print("[QuietHours] mode=\(profile.quietHoursFollowSleepSchedule ? "sleep schedule" : "custom")"
            + "  wake=\(fmt.string(from: wake)) bedtime=\(fmt.string(from: profile.bedtime))")
        print("  OLD rule: awake window = wake+\(NudgeConfig.postWakeQuietMinutes)m → "
            + "bed−\(NudgeConfig.preBedtimeQuietMinutes)m, pinned to the fire date's own day.")
        if let window = quietWindow(for: profile) {
            print("  NEW rule: quiet = \(window.description); everything else passes.")
        } else {
            print("  NEW rule: quiet window UNRESOLVABLE (zero-length) — gate fails OPEN.")
        }
        print("  derived-from-sleep window would be \(fmt.string(from: derived.start))"
            + " → \(fmt.string(from: derived.end)) (what Settings seeds custom times with).")

        // Does the OLD rule degenerate on this profile? Answered structurally
        // rather than inferred from the per-candidate rows, since on a
        // degenerate window EVERY row blocks and the cause isn't obvious.
        let bedMinute = Self.wrapMinute(
            Self.minuteOfDay(profile.bedtime) - NudgeConfig.preBedtimeQuietMinutes
        )
        let wakeMinute = Self.wrapMinute(
            Self.minuteOfDay(wake) + NudgeConfig.postWakeQuietMinutes
        )
        if bedMinute <= wakeMinute {
            print("  ⚠︎ OLD rule DEGENERATE on this profile: bed−\(NudgeConfig.preBedtimeQuietMinutes)m "
                + "(\(bedMinute / 60):\(String(format: "%02d", bedMinute % 60))) is not after "
                + "wake+\(NudgeConfig.postWakeQuietMinutes)m "
                + "(\(wakeMinute / 60):\(String(format: "%02d", wakeMinute % 60))). "
                + "The awake window is empty and the old gate blocks EVERY discretionary "
                + "candidate all day. The new rule treats this as a midnight-wrapping quiet "
                + "window instead.")
        }

        let discretionary = all.filter(\.countsAgainstBudget)
        guard !discretionary.isEmpty else {
            print("  → no budget-counting candidates this run — nothing to compare.")
            return
        }

        print("  \(padc("KIND", 13))\(padc("FIRE", 16))\(padc("OLD", 7))\(padc("NEW", 7))TITLE")
        var flippedOpen = 0
        var flippedClosed = 0
        for cand in discretionary.sorted(by: { $0.fireDate < $1.fireDate }) {
            let old = legacyInsideAwakeWindow(fireDate: cand.fireDate, profile: profile)
            let new = passesQuietHours(fireDate: cand.fireDate, profile: profile)
            if old != new { new ? (flippedOpen += 1) : (flippedClosed += 1) }
            print("  " + padc(cand.kind.rawValue, 13)
                + padc(fmt.string(from: cand.fireDate), 16)
                + padc(old ? "pass" : "BLOCK", 7)
                + padc(new ? "pass" : "BLOCK", 7)
                + (old == new ? "" : "⇄ ") + cand.title)
        }

        if flippedOpen == 0 && flippedClosed == 0 {
            print("  → NO CHANGE across \(discretionary.count) candidate(s). Expected whenever "
                + "the profile still follows its sleep schedule AND that schedule doesn't "
                + "cross midnight — the new rule reduces to the old one there, boundaries "
                + "included.")
        } else {
            print("  → \(flippedOpen) candidate(s) NEWLY PASS, \(flippedClosed) newly BLOCKED "
                + "(of \(discretionary.count)). Note this is the gate verdict only — a newly "
                + "passing candidate still has to survive the busy-window gate, min-spacing, "
                + "and the daily budget of \(NudgeConfig.dailyNudgeBudget) before it reaches "
                + "the user.")
        }
    }

    // MARK: - DEBUG: active-session gate impact

    /// Before/after for narrowing the active-session gate, per work-order
    /// item 5.
    ///
    /// BEFORE is the old rule, which had exactly one verdict for the whole
    /// run: session active ⇒ every candidate dropped, budget-exempt or not.
    /// AFTER is the real gate, per candidate. The rows that matter are the
    /// event blocks — they were being suppressed by a gate every other rule
    /// in `passesGates` exempts them from.
    private func debugActiveSessionImpact(all: [NudgeCandidate], context: GateContext) {
        guard SessionCoordinator.shared.isSessionActive else {
            print("[ActiveSession] no session running — gate inert this run, "
                + "BEFORE and AFTER both pass everything.")
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let ends = SessionCoordinator.shared.sessionEnd

        print("[ActiveSession] session running until \(fmt.string(from: ends))")
        if ends <= context.now {
            print("  ⚠️  sessionEnd is NOT in the future while isSessionActive is true — "
                + "the gate will suppress nothing. Expected only in the 3s teardown "
                + "window inside finishSession; anywhere else this is the ordering bug "
                + "startSession was fixed for.")
        }
        guard !all.isEmpty else {
            print("  no candidates this run.")
            return
        }
        print("  BEFORE: session active → old rule BLOCKED ALL \(all.count) candidate(s), "
            + "event blocks included.")
        var freed = 0
        for cand in all.sorted(by: { $0.fireDate < $1.fireDate }) {
            let blocked = cand.countsAgainstBudget && firesDuringActiveSession(cand.fireDate)
            if !blocked { freed += 1 }
            let why = blocked
                ? "BLOCK"
                : (cand.countsAgainstBudget ? "PASS" : "PASS*")
            print("      " + padc(why, 7)
                + padc(fmt.string(from: cand.fireDate), 18)
                + padc(cand.kind.rawValue, 14)
                + cand.title)
        }
        print("  AFTER : \(freed) of \(all.count) candidate(s) freed. "
            + "PASS* = budget-exempt, never sees this gate at all.")
    }

    // MARK: - DEBUG: activity-cooldown gate impact

    /// Before/after gate verdicts for moving the activity cooldown off `now`
    /// and onto the candidate's fire date, per work-order item 5.
    ///
    /// BEFORE is the old rule reproduced exactly — "did a session start
    /// within `recentActivityCooldownMinutes` of NOW", which was a single
    /// verdict applied to every budget-counting candidate regardless of when
    /// it fires. AFTER is the real gate, called per candidate. Read-only.
    ///
    /// On a run with no recent session start both columns are all-PASS and
    /// the dump says so in one line rather than printing a table of
    /// identical rows — that is the common case and it should be cheap to
    /// skim past.
    private func debugRecentActivityImpact(all: [NudgeCandidate], context: GateContext) {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let lastStart = SharedModelContainer.appGroupDefaults
            .object(forKey: NotificationScheduler.lastFocusSessionStartedAtKey) as? Date
        guard let lastStart else {
            print("[ActivityCooldown] no focus session has ever been started — "
                + "gate is inert this run, BEFORE and AFTER both pass everything.")
            return
        }
        let cooldown = NudgeConfig.recentActivityCooldownMinutes
        let cooldownEnds = Calendar.current.date(byAdding: .minute, value: cooldown, to: lastStart)
            ?? lastStart
        // The old rule, reproduced: one verdict for the whole run.
        let blockedEverythingBefore = lastStart > (Calendar.current.date(
            byAdding: .minute, value: -cooldown, to: context.now
        ) ?? .distantPast)

        print("[ActivityCooldown] lastSessionStart=\(fmt.string(from: lastStart)) "
            + "cooldown=\(cooldown)m → window ends \(fmt.string(from: cooldownEnds))")

        let discretionary = all.filter(\.countsAgainstBudget)
        guard !discretionary.isEmpty else {
            print("  no budget-counting candidates this run — nothing for either rule to judge.")
            return
        }
        guard blockedEverythingBefore else {
            print("  BEFORE: last start is older than \(cooldown)m — old rule blocked nothing.")
            let nowBlocked = discretionary.filter { firesInsideActivityCooldown($0.fireDate) }
            print("  AFTER : \(nowBlocked.count) blocked. "
                + (nowBlocked.isEmpty
                    ? "Identical verdicts this run."
                    : "NOTE — these fire inside a window the old rule had already exited."))
            return
        }

        print("  BEFORE: session started \(Int(context.now.timeIntervalSince(lastStart) / 60))m ago "
            + "→ old rule BLOCKED ALL \(discretionary.count) budget-counting candidate(s), "
            + "whatever their fire date.")
        var freed = 0
        for cand in discretionary.sorted(by: { $0.fireDate < $1.fireDate }) {
            let blocked = firesInsideActivityCooldown(cand.fireDate)
            if !blocked { freed += 1 }
            print("      " + padc(blocked ? "BLOCK" : "PASS", 7)
                + padc(fmt.string(from: cand.fireDate), 18)
                + padc(cand.kind.rawValue, 14)
                + cand.title)
        }
        print("  AFTER : \(freed) of \(discretionary.count) candidate(s) freed — "
            + "they fire after the cooldown ends and the session has no bearing on them.")
    }

    // MARK: - DEBUG: morning prompt targeting impact

    /// Before/after for "the morning prompt names the day's biggest task".
    ///
    /// This change is a payload change, not a scheduling change — the
    /// builder's gating (toggle, day-fullness, fire-moment busy) is
    /// untouched, so the fire time is identical to before. The ONE way it
    /// can alter what the arbiter does is the new content gate: with no open
    /// task there is now no candidate at all, where the old open question
    /// fired regardless. That case prints as `SKIP` below and is the line to
    /// look for.
    ///
    /// Read-only: re-derives into locals, schedules nothing. Calls the real
    /// `morningPromptRanking` so the printed order cannot drift from the
    /// order the builder used.
    private func debugMorningPromptImpact(
        all: [NudgeCandidate],
        profile: UserProfile,
        context: GateContext
    ) {
        guard profile.morningCheckInNotificationsEnabled else {
            print("[MorningPrompt] toggle off — nothing to compare.")
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let built = all.first { $0.kind == .morningPrompt }
        // Reconstruct the fire date the builder would have used, so the
        // ranking below is evaluated at the same instant even on a run where
        // the builder bailed out at one of its gates.
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        var comps = calendar.dateComponents([.year, .month, .day], from: context.now)
        comps.hour = wakeComps.hour
        comps.minute = wakeComps.minute
        guard var fireDate = calendar.date(from: comps) else {
            print("[MorningPrompt] could not resolve the fire date.")
            return
        }
        fireDate = fireDate.addingTimeInterval(Double(NudgeConfig.postWakeQuietMinutes) * 60)
        if fireDate <= context.now {
            fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
        }

        let ranking = morningPromptRanking(fireDate: fireDate, modelContext: context.modelContext)
        let unfiltered = morningPromptRanking(
            fireDate: fireDate,
            includeRepeatNamed: true,
            modelContext: context.modelContext
        )

        print("[MorningPrompt] fire=\(fmt.string(from: fireDate))  (gating unchanged: toggle, day-fullness, fire-moment busy)")
        print("  BEFORE: \"What do you want to get done today? Tell me and I'll set it up.\"  ← fired with nothing open too")
        if let built {
            print("  AFTER : \"\(built.body)\"")
        } else if ranking.isEmpty {
            print("  AFTER : SKIP — nothing open to name. THIS is the behaviour change: "
                + "the old copy would have fired here.")
        } else {
            print("  AFTER : no candidate this run — a builder gate (day-fullness or "
                + "fire-moment busy) stopped it before targeting, same as it would have before.")
        }

        // ── The no-repeat rule, shown as a comparison ────────────────────
        // `morningPromptMaxConsecutiveDays` is the reason today's pick can
        // differ from the pure stakes ranking. Print the last week of named
        // tasks so "why THAT one" is answerable from the log alone.
        let history = morningPromptHistory
        let window = NudgeConfig.morningPromptMaxConsecutiveDays
        if let incumbent = unfiltered.first {
            let actuallyNamed = ranking.first
            let heldTooLong = wasNamedOnRecentMornings(incumbent.task, before: fireDate)
            if actuallyNamed?.task.id != incumbent.task.id {
                print("  no-repeat rule BIT: \"\(incumbent.task.title)\" has been named "
                    + "\(window) morning(s) running → stepped aside for "
                    + "\"\(actuallyNamed?.task.title ?? "nothing")\".")
            } else if heldTooLong {
                // The rule wanted to fire and something stopped it. WHICH
                // one matters: a tier veto is the design working, an empty
                // pool is the user having one task, and they read
                // identically in the output unless named.
                let fresh = (try? context.modelContext.fetch(
                    FetchDescriptor<NudgeTask>(
                        predicate: #Predicate<NudgeTask> { !$0.isComplete && !$0.isInformationalEvent }
                    )
                ))?.filter { !wasNamedOnRecentMornings($0, before: fireDate) } ?? []
                let best = rankPool(fresh, fireDate: fireDate, modelContext: context.modelContext).first
                if let best {
                    let gap = NudgeArbiter.morningStakesRank(incumbent.stakes)
                        - NudgeArbiter.morningStakesRank(best.stakes)
                    print("  no-repeat rule HELD (tier veto): \"\(incumbent.task.title)\" "
                        + "(\(incumbent.stakes?.rawValue ?? "unclassified")) has held the slot "
                        + "\(window) morning(s), but the best alternative "
                        + "\"\(best.task.title)\" (\(best.stakes?.rawValue ?? "unclassified")) "
                        + "is \(gap) tier(s) below it. Repeating rather than naming something "
                        + "the ranking disagrees with.")
                } else {
                    print("  no-repeat rule HELD (nothing else open): "
                        + "\"\(incumbent.task.title)\" is the only thing to name.")
                }
            } else if !history.isEmpty {
                print("  no-repeat rule idle: \"\(incumbent.task.title)\" has not yet been "
                    + "named \(window) mornings running.")
            }
        }
        if !history.isEmpty {
            let recent = history.sorted { $0.key > $1.key }.prefix(7)
            let titles = (try? context.modelContext.fetch(FetchDescriptor<NudgeTask>()))
                .map { Dictionary(uniqueKeysWithValues: $0.map { ($0.id.uuidString, $0.title) }) }
                ?? [:]
            print("  named-task history (most recent first): "
                + recent.map { "\($0.key)=\(titles[$0.value] ?? "deleted task")" }
                    .joined(separator: "  "))
        }

        guard !ranking.isEmpty else { return }
        print("  ranked \(ranking.count) contender(s) in the top stakes tier "
            + "(stakes ▸ deadline proximity ▸ id):")
        let shown = ranking.prefix(8)
        for choice in shown {
            let due = (choice.task.specificTime ?? choice.task.dueDate)
                .map { fmt.string(from: $0) } ?? "undated"
            print("      " + padc(choice.stakes?.rawValue ?? "unclassified", 14)
                + padc(String(format: "%.2f", choice.urgency), 6)
                + padc(due, 18)
                + choice.task.title)
        }
        if ranking.count > shown.count {
            print("      … \(ranking.count - shown.count) more contender(s) not printed.")
        }
    }

    // MARK: - DEBUG: floater rollover impact

    /// Before/after for the floater check-in fix, per the "any change that
    /// alters what the arbiter does gets a DEBUG comparison on real data"
    /// rule. Read-only: it re-derives into locals and schedules nothing.
    ///
    /// BEFORE is the pre-fix builder: today's anchor only, `guard fireDate >
    /// Date() else { return [] }`, and no placed-task exclusion. AFTER is
    /// what actually got built this run. Both call the SAME `floaterTargets`
    /// so the two columns can't drift apart in their targeting.
    ///
    /// The count is the least interesting line. The useful output is the
    /// verdict at the bottom: a candidate that exists but is gate-blocked or
    /// spacing-evicted still produces no `.floater` outcome row, and "the
    /// rollover worked" vs "the rollover worked and it will still never
    /// fire here" are the two findings worth telling apart.
    private func debugFloaterImpact(
        all: [NudgeCandidate],
        eligible: [NudgeCandidate],
        scheduled: [NudgeCandidate],
        profile: UserProfile,
        context: GateContext
    ) {
        guard profile.floaterCheckInNotificationsEnabled else {
            print("[FloaterImpact] toggle off — nothing to compare.")
            return
        }
        let calendar = Calendar.current
        let now = context.now
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        guard let todayAnchor = floaterAnchor(on: now, profile: profile) else {
            print("[FloaterImpact] could not resolve today's anchor.")
            return
        }
        let rolled = todayAnchor <= now
        let fireDate = rolled
            ? (calendar.date(byAdding: .day, value: 1, to: todayAnchor) ?? todayAnchor)
            : todayAnchor

        // BEFORE: old anchor rule + old targeting (no placement exclusion).
        let beforeCount = rolled
            ? 0
            : floaterTargets(
                fireDate: todayAnchor,
                excludePlacedOnFireDay: false,
                modelContext: context.modelContext
            ).targets.count

        // AFTER: whatever this run actually built.
        let afterCandidates = all.filter { $0.kind == .floater }
        let placedOut = floaterTargets(
            fireDate: fireDate,
            excludePlacedOnFireDay: true,
            modelContext: context.modelContext
        ).placedOut

        print("[FloaterImpact] anchor=wake+\(NudgeConfig.floaterCheckInHoursAfterWake)h "
            + "today=\(fmt.string(from: todayAnchor)) "
            + (rolled
                ? "— PASSED \(Int(now.timeIntervalSince(todayAnchor) / 60))m ago, rolled to \(fmt.string(from: fireDate))"
                : "— still ahead, no roll needed"))
        print("  BEFORE (no rollover, no placement filter): \(beforeCount) candidate(s)"
            + (rolled ? "  ← the bug: builder returned [] and cancelAll had already wiped the morning's copy" : ""))
        print("  AFTER  (rollover + placement filter)     : \(afterCandidates.count) candidate(s) @ \(fmt.string(from: fireDate))")
        if !placedOut.isEmpty {
            print("      excluded \(placedOut.count) already placed on the fire day: "
                + placedOut.map(\.title).joined(separator: ", "))
        }
        for cand in afterCandidates.sorted(by: { $0.score > $1.score }) {
            print("      • \(String(format: "%.3f", cand.score))  \(cand.body.prefix(50))")
        }

        // ── Would it actually reach the user? ────────────────────────────
        guard let best = afterCandidates.max(by: { $0.score < $1.score }) else {
            print("  → VERDICT: no floater candidate this run "
                + (rolled ? "(rollover fired, but targeting produced nothing)." : "."))
            return
        }
        if scheduled.contains(where: { $0.id == best.id }) {
            print("  → VERDICT: SCHEDULED — a `.floater` outcome row will exist for \(fmt.string(from: fireDate)).")
            return
        }
        if !eligible.contains(where: { $0.id == best.id }) {
            print("  → VERDICT: BLOCKED AT THE GATE — \(floaterGateBlockReason(best, context: context))")
            return
        }
        // Eligible but not scheduled ⇒ pickWinners dropped it. Only two
        // ways that happens: min-spacing against an already-chosen winner
        // (event-block reminders are seeded first, so they're the usual
        // culprit) or the daily budget.
        let sameDay = scheduled.filter {
            calendar.isDate($0.fireDate, inSameDayAs: best.fireDate)
        }
        let blocker = sameDay.first {
            abs($0.fireDate.timeIntervalSince(best.fireDate))
                < Double(NudgeConfig.minNudgeSpacingMinutes) * 60
        }
        if let blocker {
            let gap = Int(abs(blocker.fireDate.timeIntervalSince(best.fireDate)) / 60)
            print("  → VERDICT: EVICTED BY MIN-SPACING — \(blocker.kind.rawValue) "
                + "'\(blocker.title)' fires at \(fmt.string(from: blocker.fireDate)), "
                + "\(gap)m away (needs \(NudgeConfig.minNudgeSpacingMinutes)m).")
        } else {
            print("  → VERDICT: NOT PICKED — \(sameDay.count) nudge(s) already chosen for that "
                + "day against a budget of \(NudgeConfig.dailyNudgeBudget).")
        }
    }

    /// Names the FIRST gate in `passesGates` that rejects `candidate`. The
    /// order here mirrors that function; it re-derives rather than shares
    /// code because `passesGates` returns a bare Bool and making it report
    /// reasons would put debug plumbing in the production path.
    private func floaterGateBlockReason(
        _ candidate: NudgeCandidate,
        context: GateContext
    ) -> String {
        if firesDuringActiveSession(candidate.fireDate) {
            return "a focus session is running until "
                + "\(SessionCoordinator.shared.sessionEnd) and this nudge would arrive "
                + "inside it. (Since Jul 2026 an active session only blocks candidates "
                + "that land during it, and never blocks budget-exempt kinds.)"
        }
        if firesInsideActivityCooldown(candidate.fireDate) {
            return "the fire time lands inside the "
                + "\(NudgeConfig.recentActivityCooldownMinutes)m cooldown that follows the "
                + "last focus-session start — i.e. this nudge would arrive while the user "
                + "is plausibly still working. (Read against the FIRE DATE since Jul 2026; "
                + "it used to read `now` and drop every budget-counting candidate in the "
                + "reevaluate, tomorrow's included.)"
        }
        if !passesQuietHours(fireDate: candidate.fireDate, profile: context.profile) {
            let window = quietWindow(for: context.profile)
            return "fire time falls inside quiet hours "
                + (window.map { $0.description } ?? "(unresolvable — should have failed open)") + "."
        }
        if BusyWindowResolver.shared.isBusy(at: candidate.fireDate, modelContext: context.modelContext) {
            return "fire time lands inside a busy window. Note this includes merged "
                + "windows: two events with a gap ≤ \(NudgeConfig.interEventGapToleranceMinutes)m "
                + "become one, so neither has to cover the fire time itself."
        }
        if NudgeConfig.fatigueGateEnabled, let taskID = candidate.taskID,
           taskFatigueCount(taskID: taskID, context: context) >= NudgeConfig.perTaskMaxNudges {
            return "per-task fatigue — nudged ≥ \(NudgeConfig.perTaskMaxNudges) times without action."
        }
        return "no gate reproduced the rejection — this reason-walk has drifted from `passesGates`."
    }

    private func padc(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? String(text.prefix(width - 1)) + " "
            : text + String(repeating: " ", count: width - text.count)
    }
    #endif

    // MARK: - Winners

    /// Picks all event-block reminders (they're factual + budget-exempt)
    /// plus the top-scoring discretionary candidate per fire-day, capped
    /// by the daily budget, and spaced by the min-spacing window.
    private func pickWinners(
        from candidates: [NudgeCandidate],
        context: GateContext
    ) -> [NudgeCandidate] {
        var winners: [NudgeCandidate] = []
        let calendar = Calendar.current

        // 1. Event-block reminders — pass straight through.
        let eventBlocks = candidates.filter { !$0.countsAgainstBudget }
        winners.append(contentsOf: eventBlocks)

        // 2. Discretionary — group by day, sort by score descending, then
        //    apply daily budget + min-spacing.
        let discretionary = candidates.filter { $0.countsAgainstBudget }
        let byDay = Dictionary(grouping: discretionary) { calendar.startOfDay(for: $0.fireDate) }

        for (_, dayCandidates) in byDay {
            let sorted = dayCandidates.sorted { $0.score > $1.score }
            var chosen: [NudgeCandidate] = []
            for cand in sorted {
                guard chosen.count < NudgeConfig.dailyNudgeBudget else { break }
                // Min spacing — must be far enough from every already-chosen
                // notification (event blocks included).
                let combined = chosen + winners
                let tooClose = combined.contains { other in
                    abs(other.fireDate.timeIntervalSince(cand.fireDate)) <
                        Double(NudgeConfig.minNudgeSpacingMinutes) * 60
                }
                if !tooClose { chosen.append(cand) }
            }
            winners.append(contentsOf: chosen)
        }

        return winners
    }

    // MARK: - Urgency Tier

    /// Decides the visual urgency tier for a task + fire-time pair.
    ///
    /// - `.critical` if the task is overdue, due within 12h, or names an
    ///   exam/midterm/final/quiz/deadline due within ~48h.
    /// - `.warning` if due within 72h, or deep-work task within 48h, or
    ///   exam/midterm-keyword task within a week.
    /// - `.normal` otherwise.
    ///
    /// Pass `nil` for events with no associated task — falls back to title
    /// keyword scan against a generic "" string (returns .normal).
    private func tier(for task: NudgeTask?, fireDate: Date) -> NudgeUrgencyTier {
        guard let task else { return .normal }
        let now = Date()
        let title = task.title.lowercased()
        let bigKeywords: Set<String> = [
            "exam", "midterm", "final", "quiz", "test",
            "deadline", "presentation", "interview", "due"
        ]
        let hasBigKeyword = bigKeywords.contains { title.contains($0) }

        let referenceDeadline = task.specificTime ?? task.dueDate
        guard let deadline = referenceDeadline else {
            // Floater with no date — never escalates.
            return .normal
        }

        let secondsToDeadline = deadline.timeIntervalSince(now)
        let hoursToDeadline = secondsToDeadline / 3600

        if secondsToDeadline < 0 { return .critical }            // overdue
        if hoursToDeadline <= 12 { return .critical }
        if hasBigKeyword && hoursToDeadline <= 48 { return .critical }
        if hoursToDeadline <= 72 { return .warning }
        if hasBigKeyword && hoursToDeadline <= 168 { return .warning } // 1 week
        return .normal
    }

    // MARK: - Scheduling

    private func schedule(_ candidate: NudgeCandidate, modelContext: ModelContext) {
        let content = UNMutableNotificationContent()
        // Apply the tier's emoji + casing to the title so a "critical" nudge
        // reads at a glance as more urgent than a "normal" one — iOS won't
        // let us change banner color, but the title prefix is the closest
        // legitimate substitute.
        content.title = candidate.tier.styledTitle(candidate.title)
        content.body = candidate.body
        content.sound = .default
        content.categoryIdentifier = candidate.categoryID.rawValue
        // The tier overrides the candidate's `interruption` so warning/
        // critical tiers always break through Focus modes.
        content.interruptionLevel = candidate.tier.interruption
        content.relevanceScore = candidate.tier.relevanceScore
        var userInfo: [String: Any] = [
            NudgeNotificationUserInfoKey.kind: candidate.kind.rawValue
        ]
        if let taskID = candidate.taskID {
            userInfo[NudgeNotificationUserInfoKey.taskID] = taskID.uuidString
        }
        content.userInfo = userInfo

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: candidate.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: candidate.id,
            content: content,
            trigger: trigger
        )
        center.add(request)
        // Persist that we own this ID so cancelAll can remove it on the next
        // reevaluate without racing against the system center.
        var ids = scheduledIDs
        ids.insert(candidate.id)
        scheduledIDs = ids

        // Mark event-block reminders so we don't re-schedule them after
        // delivery (cancelAll would otherwise wipe the pending request,
        // and the next reevaluate would re-add a duplicate that re-fires).
        if candidate.kind == .eventBlock {
            var history = eventReminderHistory
            history[candidate.id] = candidate.fireDate.timeIntervalSinceReferenceDate
            eventReminderHistory = history
        }

        // Record which task the morning prompt named for its fire day, so
        // `morningPromptMaxConsecutiveDays` can make it step aside. Keyed on
        // the FIRE day, not today: an evening reevaluate schedules
        // tomorrow's prompt, and tomorrow is the morning the user will see
        // it on. Re-scheduling the same day writes the same pair again.
        if candidate.kind == .morningPrompt, let namedTaskID = candidate.namedTaskID {
            var history = morningPromptHistory
            history[stamp(Calendar.current.startOfDay(for: candidate.fireDate))]
                = namedTaskID.uuidString
            morningPromptHistory = history
        }

        // Log the outcome row as "pending" so future evaluations can see
        // fatigue and so we can mark it tapped/ignored later. `estimatedMinutes`
        // is captured here so that on completion we can compare predicted
        // vs actual and tune the DurationModel.
        let outcome = NudgeOutcome(
            kind: candidate.kind,
            notificationID: candidate.id,
            taskID: candidate.taskID,
            scheduledFor: candidate.fireDate,
            estimatedMinutes: candidate.estimatedMinutes
        )
        modelContext.insert(outcome)
        try? modelContext.save()
    }

    private func stamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
}
