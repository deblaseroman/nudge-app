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
        candidates.append(contentsOf: buildBreakItDownCandidates(profile: profile, modelContext: modelContext))
        #if DEBUG
        print("[NudgeArbiter] Built \(candidates.count) raw candidates (events + morning + idle + getAhead + floater + breakDown).")
        #endif

        // 2. Run gates
        let now = Date()
        let gateContext = GateContext(profile: profile, modelContext: modelContext, now: now)
        let eligible = candidates.filter { passesGates($0, context: gateContext) }
        #if DEBUG
        print("[NudgeArbiter] \(eligible.count) candidates passed the gates.")
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

        // Also drop any pending NudgeOutcome audit rows from previous runs
        // so per-task fatigue and stats don't inflate over time.
        let descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> { $0.resultRaw == "pending" }
        )
        if let pending = try? modelContext.fetch(descriptor), !pending.isEmpty {
            for row in pending { modelContext.delete(row) }
            try? modelContext.save()
        }

        // Prune ACTED-UPON outcomes older than the 14-day fatigue window.
        // Without this, every `.tappedStart` / `.tappedSnooze` /
        // `.tappedBreakDown` / `.ignored` / `.dismissed` row persisted
        // forever (only `.pending` was cleaned above), so the database
        // grew monotonically and `buildBreakItDownCandidates` /
        // `taskFatigueCount` reloaded ever-larger result sets into the
        // shared SwiftData identity map on every reevaluate. This was
        // a confirmed contributor to the rapid-cycling memory jetsam.
        //
        // Cleanup rule (chosen to keep fatigue tracking correct):
        //   - Cutoff: 14 days ago (same window the fatigue fetch uses).
        //   - Delete: any non-pending outcome with `scheduledFor` older
        //     than the cutoff.
        //   - Keep: ALL outcomes within the last 14 days (so the
        //     per-task ignored/dismissed counters in
        //     `buildBreakItDownCandidates` see complete recent history)
        //     AND all `pending` rows regardless of age (those are
        //     managed by the block above).
        //
        // Uses `delete(model:where:)` so rows are removed by predicate
        // without first loading them into the context.
        let staleCutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        try? modelContext.delete(
            model: NudgeOutcome.self,
            where: #Predicate<NudgeOutcome> {
                $0.scheduledFor < staleCutoff && $0.resultRaw != "pending"
            }
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
    private func buildEventBlockCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
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

                // Skip if we already scheduled this event-block reminder
                // today. The marker means cancelAll wiped the pending
                // request (because it was already delivered) and we
                // shouldn't re-add a duplicate.
                if eventReminderHistory[candidateID] != nil { continue }

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

    /// Morning prompt — the day-opening capture ask ("what do you want to
    /// get done today?"). Tapping it lands in the Home chat, where the
    /// answer flows through the normal brain-dump capture. Replaces the
    /// fixed `NotificationScheduler` morning kickoff so the decision runs
    /// through the arbiter's declarative rebuild instead of a repeating
    /// clock trigger that fires no matter what the day looks like.
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

        #if DEBUG
        print("[NudgeArbiter] morning: OK — will schedule morning prompt at \(fireDate).")
        #endif
        return [NudgeCandidate(
            id: "\(prefix)morning.\(stamp(calendar.startOfDay(for: fireDate)))",
            kind: .morningPrompt,
            fireDate: fireDate,
            title: "Good morning",
            body: "What do you want to get done today? Tell me and I'll set it up.",
            categoryID: .morningPrompt,
            interruption: .active,
            taskID: nil,
            tier: .normal,
            urgency: 1.0,
            importance: 1.0,
            receptivity: 1.0,
            countsAgainstBudget: false,
            estimatedMinutes: nil
        )]
    }

    /// Idle / paralysis nudge — fires at wake+idleThreshold and asks "Have
    /// you gotten started on anything today?" with yes/no buttons.
    ///
    /// Suppressed when ANY of the following happened in the 3-hour window
    /// leading up to the fire time:
    ///   1. A focus session was started
    ///   2. A task was completed (CompletedTaskRecord row in window)
    ///   3. A calendar event happened (informational event with
    ///      specificTime in window)
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

        // Three-condition window check — if the user has clearly been
        // active in the 3 hours leading up to the fire time, don't ask
        // the question at all.
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
        if hadCalendarEvent(in: windowStart...windowEnd, modelContext: modelContext) {
            #if DEBUG
            print("[NudgeArbiter] idle: SKIP — a calendar event falls in the pre-fire window.")
            #endif
            return []
        }

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
            let fireDate = plan.startBy
            guard fireDate > now else { continue }
            guard let due = task.dueDate else { continue }

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

    /// Mid-day check-in for OPEN UNDATED tasks. Get-ahead nudges require a
    /// `dueDate` (the planner derives `startBy` from it), so chat-captured
    /// tasks like "study for biology" never produce any get-ahead candidate.
    /// Without this builder the user gets ONE idle nudge in the morning and
    /// then silence until bedtime — exactly the symptom of "the app doesn't
    /// ask if I'm working on something important."
    ///
    /// Fires at today's wake + 6 hours for every undated open task; the
    /// daily budget + min-spacing in `pickWinners` collapses it to the
    /// top-scoring one.
    private func buildFloaterCheckInCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.taskDueSoonNotificationsEnabled else { return [] }
        let calendar = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        var todayComps = calendar.dateComponents([.year, .month, .day], from: Date())
        todayComps.hour = wakeComps.hour
        todayComps.minute = wakeComps.minute
        guard let todaysWake = calendar.date(from: todayComps) else { return [] }
        let fireDate = todaysWake.addingTimeInterval(6 * 60 * 60)
        guard fireDate > Date() else { return [] }

        var floaterDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                !task.isComplete && !task.isInformationalEvent && task.dueDate == nil
            }
        )
        floaterDescriptor.fetchLimit = 50
        let floaters = (try? modelContext.fetch(floaterDescriptor)) ?? []

        // If the user has an ordered plan, the check-in should point at the
        // plan's NEXT item (lowest sequenceIndex) rather than an arbitrary
        // undated task. Otherwise fall back to all floaters.
        let planFloaters = floaters.filter { $0.sequenceIndex != nil }
        let candidateTasks: [NudgeTask]
        if let planNext = planFloaters.min(by: { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }) {
            candidateTasks = [planNext]
        } else {
            candidateTasks = floaters
        }

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
                kind: .getAhead,
                fireDate: fireDate,
                title: "Are you working on something?",
                body: body,
                categoryID: .getAhead,
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

    /// Break-it-down offer — only kicks in for a task that's been nudged
    /// `perTaskMaxNudges` times without action. Replaces further pushes for
    /// that task.
    private func buildBreakItDownCandidates(
        profile: UserProfile,
        modelContext: ModelContext
    ) -> [NudgeCandidate] {
        guard profile.deadlinePrepNotificationsEnabled else { return [] }
        // Scope to the fatigue window — fetching every NudgeOutcome ever
        // recorded grew the shared SwiftData identity map unboundedly on
        // every reevaluate (this path was a confirmed contributor to the
        // "Terminated due to memory issue" jetsam under rapid scene
        // cycling). The fatigue counter only needs recent ignored/
        // dismissed events per task; older history doesn't affect the
        // perTaskMaxNudges decision.
        let fatigueCutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        var descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> { $0.scheduledFor >= fatigueCutoff }
        )
        descriptor.fetchLimit = 500
        let outcomes = (try? modelContext.fetch(descriptor)) ?? []

        var ignoredCountByTask: [UUID: Int] = [:]
        for outcome in outcomes {
            guard let taskID = outcome.taskID else { continue }
            if outcome.result == .ignored || outcome.result == .dismissed {
                ignoredCountByTask[taskID, default: 0] += 1
            } else if outcome.result == .tappedStart {
                // Reset the count on success.
                ignoredCountByTask[taskID] = 0
            }
        }

        let candidates: [NudgeCandidate] = ignoredCountByTask
            .filter { $0.value >= NudgeConfig.perTaskMaxNudges }
            .compactMap { (taskID, _) -> NudgeCandidate? in
                let taskDescriptor = FetchDescriptor<NudgeTask>(
                    predicate: #Predicate<NudgeTask> { $0.id == taskID }
                )
                guard let task = (try? modelContext.fetch(taskDescriptor))?.first,
                      !task.isComplete else { return nil }

                let calendar = Calendar.current
                let wake = profile.wakeTime ?? profile.morningCheckInTime
                let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
                var todayComps = calendar.dateComponents([.year, .month, .day], from: Date())
                todayComps.hour = wakeComps.hour
                todayComps.minute = wakeComps.minute
                guard var fireDate = calendar.date(from: todayComps) else { return nil }
                fireDate = fireDate.addingTimeInterval(4 * 60 * 60)
                if fireDate <= Date() {
                    fireDate = calendar.date(byAdding: .day, value: 1, to: fireDate) ?? fireDate
                }

                // Break-it-down is intentionally calmer in tone — always
                // .normal so it doesn't read as urgent pressure. Urgency is
                // forced low (0.3) so a genuinely-urgent candidate beats
                // it inside `pickWinners`; importance still comes from the
                // task's category/dependency/statedUrgency signals so a
                // stuck exam-prep task outranks a stuck errand at the
                // same urgency.
                let signals = NudgeIntelligence.shared.cachedIntelligence(for: task, modelContext: modelContext)
                let importance = EisenhowerScorer.importance(
                    category: task.taskCategory,
                    isDeepWork: false,
                    statedUrgency: signals.statedUrgency,
                    hasDependencies: task.dependsOnTaskId != nil
                )
                let estimatedMinutes = DurationModel.shared.estimate(for: task, modelContext: modelContext)
                return NudgeCandidate(
                    id: "\(prefix)breakDown.\(task.id.uuidString)",
                    kind: .breakItDown,
                    fireDate: fireDate,
                    title: "Let's break this down",
                    body: "\"\(task.title)\" has been sitting for a while. It's probably too big in your head. Want me to break it into steps?",
                    categoryID: .breakDown,
                    interruption: .active,
                    taskID: task.id,
                    tier: .normal,
                    urgency: 0.3,
                    importance: importance,
                    receptivity: 1.0,
                    countsAgainstBudget: true,
                    estimatedMinutes: estimatedMinutes
                )
            }
        return candidates
    }

    // MARK: - Gates

    private struct GateContext {
        let profile: UserProfile
        let modelContext: ModelContext
        let now: Date
    }

    private func passesGates(_ candidate: NudgeCandidate, context: GateContext) -> Bool {
        // Active session
        if SessionCoordinator.shared.isSessionActive { return false }

        // Cooldown — recent session start or task completion suppresses
        // discretionary candidates. Event blocks are factual reminders and
        // pass anyway.
        if candidate.countsAgainstBudget && hadRecentActivity(now: context.now) {
            return false
        }

        // Quiet hours
        if candidate.countsAgainstBudget && !insideAwakeWindow(
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
        // times without action, suppress further pushes for it. The break-
        // it-down offer is the only candidate that's still allowed for that
        // task at that point.
        if candidate.kind != .breakItDown,
           let taskID = candidate.taskID,
           taskFatigueCount(taskID: taskID, context: context) >= NudgeConfig.perTaskMaxNudges {
            return false
        }

        return true
    }

    private func hadRecentActivity(now: Date) -> Bool {
        let cutoff = Calendar.current.date(
            byAdding: .minute,
            value: -NudgeConfig.recentActivityCooldownMinutes,
            to: now
        ) ?? .distantPast
        if let lastStart = SharedModelContainer.appGroupDefaults
            .object(forKey: NotificationScheduler.lastFocusSessionStartedAtKey) as? Date,
           lastStart > cutoff {
            return true
        }
        return false
    }

    private func insideAwakeWindow(fireDate: Date, profile: UserProfile) -> Bool {
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

    private func taskFatigueCount(taskID: UUID, context: GateContext) -> Int {
        // Scoped to the fatigue window for the same reason as
        // buildBreakItDownCandidates — without the date bound, this
        // returns more rows over time forever, and is called once per
        // gate-evaluated candidate per reevaluate.
        let fatigueCutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? .distantPast
        var descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> {
                $0.taskID == taskID
                    && $0.scheduledFor >= fatigueCutoff
                    && ($0.resultRaw == "ignored" || $0.resultRaw == "dismissed")
            }
        )
        descriptor.fetchLimit = NudgeConfig.perTaskMaxNudges + 1
        return (try? context.modelContext.fetch(descriptor))?.count ?? 0
    }

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
