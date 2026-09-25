//
//  TasksTabView.swift
//  Nudge
//
//  Task list with sorting, editing, and completion animations.
//

import Combine
import SwiftUI
import SwiftData
import WidgetKit

struct TasksTabView: View {
    let profile: UserProfile
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var tasks: [NudgeTask]
    @Query private var completedRecords: [CompletedTaskRecord]
    /// Deleted-study-task records — feeds the message box's one-time
    /// "still want study time?" note. Unbounded @Query is fine here: rows
    /// only exist for exams whose prep tasks the user deleted, a handful
    /// at most.
    @Query private var prepTombstones: [PrepTombstone]
    /// Expanded commitments — distinguishes a commitment tombstone (its
    /// parent ID matches one of these rows) from an exam tombstone so the
    /// message-box note gets the right copy. One row per expanded
    /// commitment; unbounded @Query is fine.
    @Query private var commitments: [NudgeCommitment]
    /// Personal goals — feed the goal-lapse hook's deterministic copy and
    /// the gentle invite (cycle 2026-08-04-03). A handful of rows.
    @Query(sort: \NudgeGoal.createdAt) private var allGoals: [NudgeGoal]

    @Binding var selectedTab: AppTab
    @State private var activeSheet: TaskSheetDestination?
    @State private var showCancelSessionAlert = false
    @State private var showSessionTaskPicker = false
    /// A session about to start on top of an anchored item (Roman, Sep 23
    /// 2026): name it, let the user decide. Nil means start straight away.
    @State private var sessionStartConflict: SessionStartConflict?
    /// True when the picker was opened by the idle sheet's "pick something
    /// else" — the user just declined a single proposed task, so opening on
    /// another single suggestion (possibly the same task) would ignore what
    /// they said. Straight to the full list instead. Reset by the Start
    /// Session button on its way in.
    @State private var sessionPickerShowsFullList = false
    /// Which list tab shows below Start Session. Deliberately not persisted:
    /// every launch lands on Today, so the entry point never moves around —
    /// the Overdue badge carries the "look here" signal instead.
    @State private var selectedListTab: TaskListTab = .today
    /// The message box's interactive shell (cycles 2026-08-03-04/-05 —
    /// visual prototype; everything behind it is a stub). Non-nil = open,
    /// carrying the composed message the box was showing so the shell's
    /// dialogue can seed from it.
    @State private var messageShellSeed: TasksMessage?
    /// Events tab lens. Two lenses on the same data, not two buckets — a
    /// high-stakes event tomorrow appears under both.
    @State private var eventLens: EventLens = .thisWeek
    /// Today-tab lens (cycle 2026-09-04-01). Like `eventLens`, deliberately
    /// not persisted — every visit starts on Today.
    @State private var todayLens: TodayLens = .today
    /// Exams whose collapsed prep-day rows are currently expanded in the
    /// Unscheduled tab (keyed by the exam's linkedEventId).
    @State private var expandedPrepExams: Set<String> = []
    /// Set when the user taps empty timeline space — drives the placement
    /// sheet. Carries the (15-min-rounded) tapped time.
    @State private var placement: PlacementContext?
    /// When "New task" is chosen from the placement sheet, the created task
    /// should land at this time. Consumed by the create editor's onSave.
    @State private var pendingPlacementTime: Date?
    /// AI day-plan rationale surfaced through the message box. The Tasks-tab
    /// Refine button is gone (cycle 2026-08-02-01); this is still fed by
    /// `DayPlanRefiner.todaysRationale()` on appear, produced by the Home
    /// chat plan-intent flow (Pro/trial gated).
    @State private var refineRationale: String?
    #if DEBUG
    @State private var showDeleteAllAlert = false
    #endif
    /// Day-groups beyond the first `NudgeConfig.eventsExpandedDays` are
    /// collapsed behind a "Show N more days" button by default; this reveals
    /// them.
    @State private var showAllEventDays = false
    /// Task proposed by the idle nudge's "Not yet" action. When non-nil
    /// we show `IdleStartConfirmationSheet` offering to start a session
    /// on this task with a "pick something else" escape hatch.
    @State private var idleProposedTaskID: UUID?
    /// The nudge the user arrived from (body tap → Tasks), read from the
    /// app-group keys on appear/active — the message box's top-priority
    /// state. Nil once the context has expired.
    @State private var tappedNudgeContext: TappedNudgeContext?
    /// Today's planner outcome for the message box (refusals + the auto-run
    /// announcement). Same appear/active read pattern; expires daily.
    @State private var planOutcome: PlanOutcomeContext?
    /// The AI-written goal-lapse hook, once its async fetch lands — rides
    /// the composer's top-priority seam. Nil shows the deterministic
    /// fallback (`nudgeExplanation`'s `.goalLapse` branch), so the box is
    /// never blank or waiting.
    @State private var goalLapseHookMessage: TasksMessage?
    /// The daily Opus memo (Sep 2026) once its cache read or fetch lands.
    /// Nil shows the deterministic ladder, so the box never waits on the
    /// network. Composer rule: it yields to tapped-nudge context and to any
    /// pending one-time news, and replaces the standing states.
    @State private var tasksMemo: TasksMessage?
    /// The plan proposal awaiting an answer (cycle 2026-09-16-01), read
    /// from `PlanProposalSweep` on appear, on foreground, and whenever the
    /// sweep posts that its store changed.
    @State private var planProposal: PlanProposalContext?
    /// Single-flight guard for the memo fetch — the tab re-appears and the
    /// fingerprint can change while a call is in the air.
    @State private var memoFetchInFlight = false

    private var coordinator: SessionCoordinator { SessionCoordinator.shared }

    /// The gentle invite's goal (cycle 2026-08-04-03): an active goal with
    /// no open task pointing at it. Longest-neglected first so the pick is
    /// stable across renders; nil when every goal has something on the
    /// list (or there are no goals). Ambient — the composer ranks it just
    /// above resting, so any day-relevant state outranks it.
    private var goalInvite: NudgeGoal? {
        let linked = Set(
            tasks.filter { !$0.isComplete && !$0.isInformationalEvent }
                .compactMap(\.goalID)
        )
        return allGoals
            .filter { $0.isActive && !linked.contains($0.id) }
            .min { ($0.lastActivityAt ?? $0.createdAt) < ($1.lastActivityAt ?? $1.createdAt) }
    }

    /// The one-tap goal offer (item 4): accepting either goal message
    /// creates a small task linked to the goal — no form. Sizing choices,
    /// all deliberate: `goalStepMinutes` (20) long, titled with the size
    /// so the ask is visibly small; priority medium; stakes left UNSET
    /// (nil — a self-set step has no external consequence, and nil ranks
    /// above `.low` in the morning ranking as absence-of-evidence);
    /// undated and unscheduled, landing in Unscheduled where the floater
    /// check-in and plan-my-day both cover it. Creating the task is not
    /// working the goal, so `lastActivityAt` is untouched — completing it
    /// writes that, through the normal path.
    private func acceptGoalOffer(_ goal: NudgeGoal) {
        let task = NudgeTask(
            title: "\(NudgeConfig.goalStepMinutes) minutes on \(goal.title)",
            priority: "medium",
            source: "goalOffer",
            estimatedMinutes: NudgeConfig.goalStepMinutes
        )
        task.goalID = goal.id
        modelContext.insert(task)
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        NudgeIntelligence.shared.refreshSoon(for: task)
        refreshNotifications()

        // The offer is answered: the lapse hook stands down (context keys
        // + AI message), and the invite recomputes to nil on its own now
        // that the goal has an open linked task. Show the list the task
        // landed in so the tap has visible effect.
        if tappedNudgeContext?.kind == .goalLapse {
            let defaults = SharedModelContainer.appGroupDefaults
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeKindKey)
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeTaskIDKey)
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeGoalIDKey)
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeDateKey)
            tappedNudgeContext = nil
            goalLapseHookMessage = nil
        }
        withAnimation(NudgeAnimation.standard) {
            selectedListTab = .unscheduled
        }
    }

    /// Fetches the AI-written goal-lapse hook when the user arrived from a
    /// bait tap. The deterministic fallback is already showing; this swaps
    /// in the full message when (and only if) it lands. Per-(goal, day)
    /// cached so re-appears inside the tap window don't re-call; every
    /// failure path (no key, offline, parse) is silent — the fallback IS
    /// the message then.
    private func fetchGoalLapseHookIfNeeded() {
        guard let context = tappedNudgeContext,
              context.kind == .goalLapse,
              let goalID = context.goalID,
              let goal = allGoals.first(where: { $0.id == goalID })
        else {
            // The hook lives exactly as long as the tap context — once
            // that expires, the composer's normal ladder takes back over.
            goalLapseHookMessage = nil
            return
        }

        if let cached = GoalLapseHookCache.read(goalID: goalID) {
            goalLapseHookMessage = cached
            return
        }
        guard goalLapseHookMessage == nil else { return }

        let now = Date()
        let lapseStart = goal.lastActivityAt ?? goal.createdAt
        let openTitles = tasks
            .filter { !$0.isComplete && !$0.isInformationalEvent }
            .prefix(5)
            .map(\.title)
        // "What's been ignored" — read-only arbiter state for the writer.
        let ignoredRaw = NudgeOutcomeResult.ignored.rawValue
        let windowStart = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        var ignoredDescriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> {
                $0.resultRaw == ignoredRaw && $0.scheduledFor > windowStart
            }
        )
        ignoredDescriptor.fetchLimit = 50
        let ignoredCount = (try? modelContext.fetchCount(ignoredDescriptor)) ?? 0

        let hookContext = ClaudeService.GoalLapseHookContext(
            goalTitle: goal.title,
            elapsedPhrase: TasksMessageComposer.goalElapsedPhrase(from: lapseStart, to: now),
            neverWorked: goal.lastActivityAt == nil,
            openTaskTitles: Array(openTitles),
            ignoredNudgeCount: ignoredCount
        )
        Task {
            guard let (headline, detail) = try? await ClaudeService.shared
                .generateGoalLapseHook(context: hookContext) else { return }
            let message = TasksMessage(headline: headline, detail: detail)
            GoalLapseHookCache.write(goalID: goalID, message: message)
            withAnimation(NudgeAnimation.standard) {
                goalLapseHookMessage = message
            }
        }
    }

    /// The check-in's answer from the box (Roman, Sep 25 2026). Yes: leave
    /// them alone for the day, same marker the notification's Yes writes,
    /// and the context is spent. No: the answer is recorded and the box
    /// re-reads into the recommendation.
    private func answerCheckIn(worked: Bool) {
        if worked {
            SharedModelContainer.appGroupDefaults.set(true, forKey: NudgeArbiter.idleDismissedKey(for: Date()))
            TappedNudgeContext.clear()
        } else {
            TappedNudgeContext.writeAnswer("no")
        }
        withAnimation(NudgeAnimation.standard) {
            tappedNudgeContext = TappedNudgeContext.read()
        }
    }

    /// The user's answer to a plan proposal. Yes writes the sessions
    /// (scheduled, never due) through the sweep's writer and reevaluates;
    /// No records the decision. Either way the box moves on.
    private func answerPlanProposal(_ proposal: PlanProposalContext, accepted: Bool) {
        if accepted {
            let written = PlanProposalSweep.shared.accept(proposal, modelContext: modelContext)
            if written > 0 {
                WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                refreshNotifications()
            }
        } else {
            PlanProposalSweep.shared.decline(proposal)
        }
        withAnimation(NudgeAnimation.standard) {
            planProposal = PlanProposalSweep.shared.currentProposal(modelContext: modelContext)
        }
    }

    /// What the memo would be written from right now, hashed. Recomputed
    /// each render; cheap (a few hundred rows at most, one SHA-256).
    private var memoFingerprint: String {
        TasksMemoContextBuilder.fingerprint(tasks: tasks, goals: allGoals, now: Date())
    }

    /// The daily Opus memo (Sep 2026): reads the cache for today's facts,
    /// else asks `ClaudeService` once, within `tasksMemoMaxPerDay`. Every
    /// failure path (no key, offline, parse, cap) is silent: the composer's
    /// deterministic ladder IS the message then, or today's last memo
    /// stands once the cap is spent. Read-only: nothing here writes to any
    /// model row.
    private func fetchTasksMemoIfNeeded() {
        // Muted box (Roman, Sep 25 2026): no memo call, nothing else changes.
        guard profile.tasksMessageBoxEnabled else { return }
        let now = Date()
        let fingerprint = memoFingerprint

        if let cached = TasksMemoCache.read(fingerprint: fingerprint, now: now) {
            if tasksMemo != cached { tasksMemo = cached }
            return
        }
        guard !memoFetchInFlight else { return }
        if TasksMemoCache.generatedToday(now: now) >= NudgeConfig.tasksMemoMaxPerDay {
            // Cap spent: today's latest memo stands, stale rather than costly.
            if let latest = TasksMemoCache.readLatestToday(now: now), tasksMemo != latest {
                tasksMemo = latest
            }
            return
        }

        let ignoredRaw = NudgeOutcomeResult.ignored.rawValue
        let windowStart = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        var ignoredDescriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> {
                $0.resultRaw == ignoredRaw && $0.scheduledFor > windowStart
            }
        )
        ignoredDescriptor.fetchLimit = 50
        let ignoredCount = (try? modelContext.fetchCount(ignoredDescriptor)) ?? 0

        let context = TasksMemoContextBuilder.build(
            tasks: tasks,
            goals: allGoals,
            completedRecords: completedRecords,
            userName: profile.name,
            ignoredNudgeCount: ignoredCount,
            now: now
        )
        memoFetchInFlight = true
        Task {
            defer { memoFetchInFlight = false }
            guard let (headline, detail) = try? await ClaudeService.shared
                .generateTasksMemo(context: context) else { return }
            let message = TasksMessage(headline: headline, detail: detail.isEmpty ? nil : detail)
            TasksMemoCache.write(fingerprint: fingerprint, message: message, now: now)
            withAnimation(NudgeAnimation.standard) {
                tasksMemo = message
            }
        }
    }

    /// The tombstone note the message box should offer: the most recent
    /// exam with an un-shown note (`noteShownAt == nil`), or one shown
    /// recently enough to still be inside its freshness window (so the
    /// note doesn't vanish mid-read the moment it's stamped).
    private var pendingPrepNote: PrepNoteContext? {
        let now = Date()
        let window = Double(NudgeConfig.prepMessageFreshnessMinutes) * 60
        let candidate = prepTombstones
            .filter { row in
                if row.noteShownAt == nil { return true }
                if let shown = row.noteShownAt { return now.timeIntervalSince(shown) < window }
                return false
            }
            .max { $0.deletedAt < $1.deletedAt }
        return candidate.map { row in
            PrepNoteContext(
                examTitle: row.examTitle,
                examEventId: row.examEventId,
                isCommitment: commitments.contains { $0.id.uuidString == row.examEventId }
            )
        }
    }

    /// Stamps every un-shown tombstone row for the exam whose note just
    /// rendered — per-exam consumption; the note never repeats.
    private func markPrepNoteShown(_ note: PrepNoteContext) {
        let now = Date()
        for row in prepTombstones
        where row.examEventId == note.examEventId && row.noteShownAt == nil {
            row.noteShownAt = now
        }
        try? modelContext.save()
    }

    private var actionableTasks: [NudgeTask] {
        tasks.filter { !$0.isInformationalEvent }
    }

    /// Incomplete informational events, time-sorted. Completed events are
    /// excluded to match the Calendar tab preview's `!isComplete` filter.
    private var eventItems: [NudgeTask] {
        tasks
            .filter { $0.isInformationalEvent && !$0.isComplete }
            .sorted { lhs, rhs in
                (lhs.specificTime ?? lhs.dueDate ?? .distantFuture) < (rhs.specificTime ?? rhs.dueDate ?? .distantFuture)
            }
    }

    /// One calendar day's worth of events for the grouped Events section.
    private struct EventDayGroup: Identifiable {
        let day: Date
        let events: [NudgeTask]
        var id: Date { day }
    }

    /// Events bucketed by calendar day, each day time-ordered. Fully dateless
    /// events (no dueDate and no specificTime) have no day of their own, so
    /// they're parked under today — their "needs a time and date" chip stays
    /// visible at the top of the list instead of vanishing, the same surfacing
    /// the old flat list gave them. Takes the event list as a parameter so
    /// each Events-tab lens groups its own subset the same way.
    private func eventDayGroups(for events: [NudgeTask]) -> [EventDayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: events) { event -> Date in
            guard let anchor = event.specificTime ?? event.dueDate else { return today }
            return cal.startOfDay(for: anchor)
        }
        return byDay
            .map { EventDayGroup(day: $0.key, events: $0.value.sorted(by: Self.eventsWithinDayOrder)) }
            .sorted { $0.day < $1.day }
    }

    /// "This week" lens: events whose day falls within the next 7 days.
    /// No lower bound — a past-day incomplete event stays visible here
    /// rather than vanishing. Dateless events pass (they park under today).
    private var thisWeekEvents: [NudgeTask] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let horizon = cal.date(byAdding: .day, value: 7, to: today) else { return eventItems }
        return eventItems.filter { event in
            guard let anchor = event.specificTime ?? event.dueDate else { return true }
            return cal.startOfDay(for: anchor) <= horizon
        }
    }

    /// "Important" lens: high-stakes events, any date. Same data as This
    /// week, different lens — stakes is the one importance signal.
    private var importantEvents: [NudgeTask] {
        eventItems.filter { $0.stakes == .high }
    }

    /// Within a day: untimed / "needs a time" events sort to the top, then
    /// timed events in clock order. `nonisolated` because it's pure — it reads
    /// only its two NudgeTask arguments and no main-actor state — so it can be
    /// handed to the nonisolated `sorted(by:)` without crossing the actor.
    private nonisolated static func eventsWithinDayOrder(_ lhs: NudgeTask, _ rhs: NudgeTask) -> Bool {
        switch (lhs.specificTime, rhs.specificTime) {
        case let (l?, r?): return l < r
        case (nil, nil):   return lhs.title < rhs.title
        case (nil, _):     return true
        case (_, nil):     return false
        }
    }

    /// Normalized titles appearing `routineEventRepeatThreshold`+ times among
    /// the section's events — the repetition half of EventRowView's "routine"
    /// de-emphasis. A row can't see its siblings, so this is computed here and
    /// passed down per row. Counts the same set the section renders
    /// (`eventItems`: incomplete informational events, expanded AND collapsed
    /// days), the population the rule was validated against when chosen.
    private var routineRepeatedTitles: Set<String> {
        let counts = Dictionary(grouping: eventItems) {
            Self.normalizedEventTitle($0.title)
        }.mapValues(\.count)
        return Set(
            counts.filter { $0.value >= NudgeConfig.routineEventRepeatThreshold }.keys
        )
    }

    /// Trim + lowercase, the same normalization `CalendarService.isDuplicate`
    /// uses — "CHEM 210 " and "chem 210" count as the same fixture.
    /// `nonisolated` for the same reason as `eventsWithinDayOrder`: pure.
    private nonisolated static func normalizedEventTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Header for a day-group: "Today · Friday", "Tomorrow · Saturday", then
    /// "Sunday, Jul 27" for everything further out.
    private func eventDayHeader(for day: Date) -> String {
        let cal = Calendar.current
        let daysOut = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: day).day ?? 0
        let weekday = day.formatted(.dateTime.weekday(.wide))
        switch daysOut {
        case 0:  return "Today · \(weekday)"
        case 1:  return "Tomorrow · \(weekday)"
        default: return "\(weekday), \(day.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }


    /// Tasks shown in the main list — informational events excluded,
    /// completed tasks excluded, AND ordered-plan tasks excluded (those live
    /// only in the "Today's plan" section so they're never duplicated).
    private var sortedTasks: [NudgeTask] {
        let comparator = TaskSortComparator()
        return actionableTasks
            .filter { !$0.isComplete && $0.sequenceIndex == nil && !$0.isSkipped }
            .sorted { comparator.compare($0, $1) }
    }

    /// The Skipped section: skipped twice, no due date, not a subtask.
    /// Comparator order, so the list reads like the others.
    private var skippedTasks: [NudgeTask] {
        let comparator = TaskSortComparator()
        return actionableTasks
            .filter { $0.isSkipped }
            .sorted { comparator.compare($0, $1) }
    }

    /// Ordered "Today's plan" tasks (captured from the brain dump), in
    /// sequenceIndex order. Includes completed ones so they stay struck-
    /// through with their number; the section only SHOWS when at least one
    /// is still open (`hasActivePlan`).
    ///
    /// **Completed rows sink to the bottom** — open work is what the list is
    /// for, and a finished task sitting at position 1 puts the thing you can't
    /// act on where the eye lands first. They keep their `sequenceIndex`
    /// numeral and their (muted) slot tint, so a sunk row is still findable;
    /// only its position moves.
    private var planTasks: [NudgeTask] {
        actionableTasks
            .filter { $0.sequenceIndex != nil }
            .sorted { lhs, rhs in
                if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
                return (lhs.sequenceIndex ?? .max) < (rhs.sequenceIndex ?? .max)
            }
    }

    private var hasActivePlan: Bool {
        planTasks.contains { !$0.isComplete }
    }

    /// Incomplete actionable tasks in the SAME order the app list uses.
    /// The comparator is plan-first, so this is a single sort: plan tasks
    /// in sequenceIndex order, then everything else by deadline bucket.
    /// Used by the "start a session" task picker so it matches the list.
    private var orderedActionableTasks: [NudgeTask] {
        let comparator = TaskSortComparator()
        return actionableTasks
            .filter { !$0.isComplete }
            .sorted { comparator.compare($0, $1) }
    }

    /// The task Start Session proposes before showing any list (cycle
    /// 2026-08-04-01 item 2) — the thing Today says to do now, so starting
    /// costs one tap instead of a decision. The rule: the earliest
    /// placement on today's timeline whose slot hasn't fully passed (a
    /// block in progress IS "now", so it counts), else the first open task
    /// in Today's ordered plan. Nil = Today is empty → the picker opens
    /// with the full list, exactly the old behaviour.
    private var suggestedSessionTask: NudgeTask? {
        let now = Date()
        let cal = Calendar.current
        let placedAhead = actionableTasks.filter { task in
            guard !task.isComplete, let p = task.plannedStartDate,
                  cal.isDateInToday(p) else { return false }
            // Same duration resolution as the timeline's blocks (30 is
            // TodayTimelineView's defaultTaskMinutes), so "still ahead"
            // agrees with what the strip draws.
            let minutes = task.plannedDurationMinutes ?? task.estimatedMinutes ?? 30
            return p.addingTimeInterval(Double(minutes) * 60) > now
        }
        if let next = placedAhead.min(by: {
            ($0.plannedStartDate ?? .distantFuture) < ($1.plannedStartDate ?? .distantFuture)
        }) {
            return next
        }
        // Day-integrity glue (cycle 2026-09-13-01): never propose a
        // future-day intention as the session to start now.
        return planTasks.first { !$0.isComplete && !$0.intentIsFuture() }
    }

    /// Open tasks not on today's timeline: unplaced, OR placed on some other
    /// day. Including stale (non-today) placements keeps such a task visible
    /// in a list instead of belonging to no section — the vanishing-task
    /// shape. The rollover sweep that clears stale placements is still a
    /// separate roadmap item; this is presentation only.
    private var unscheduledTasks: [NudgeTask] {
        sortedTasks.filter { task in
            guard let p = task.plannedStartDate else { return true }
            return !Calendar.current.isDateInToday(p)
        }
    }

    // MARK: Day membership (cycle 2026-09-04-01)

    /// The day a TASK belongs to — forwards to `NudgeTask.scheduledDay`
    /// (hoisted to the model in cycle 2026-09-13-02 so the calendar view
    /// reads the same rule). Deadline-only tasks return nil on purpose —
    /// a bare due date is owed, not scheduled (Roman's rule), so they keep
    /// living in Unscheduled/Overdue rather than under a day lens.
    private func scheduledDay(of task: NudgeTask) -> Date? {
        task.scheduledDay
    }

    /// A plan task with no day of its own reads as TODAY — a dateless
    /// ordered plan is today's plan, the pre-lens semantics kept.
    private func planDay(of task: NudgeTask) -> Date {
        scheduledDay(of: task) ?? Calendar.current.startOfDay(for: Date())
    }

    private func planTasks(on day: Date) -> [NudgeTask] {
        NudgeTask.planTasks(among: actionableTasks, on: day)
    }

    /// Non-plan tasks belonging to `day` — the old `scheduledTasks` with
    /// membership widened from "placed today" to "intended OR placed that
    /// day". Kept in the list (in addition to the timeline) so placed tasks
    /// stay checkable. Open rows order by start time — the list must read
    /// in the same order the strip above draws, not the comparator's
    /// deadline buckets; unplaced intents follow; completed rows sink.
    private func dayTasks(on day: Date) -> [NudgeTask] {
        // The rule lives on the model (`NudgeTask.dayTasks`) so the widget
        // reads the same lens; this is a forwarder.
        NudgeTask.dayTasks(among: actionableTasks, on: day)
    }

    /// Events anchored to `day` — same anchor the Events tab uses
    /// (`specificTime ?? dueDate`); `eventItems` is already time-sorted.
    private func dayEvents(on day: Date) -> [NudgeTask] {
        eventItems.filter { event in
            guard let anchor = event.specificTime ?? event.dueDate else { return false }
            return Calendar.current.isDate(anchor, inSameDayAs: day)
        }
    }

    /// Day-slot index per task id — the single assignment both the timeline
    /// and Today's rows tint from. Computed here, off the tab's unbounded
    /// `tasks` query, and passed down; see the note in `DaySlotPalette`.
    private var daySlots: [UUID: Int] {
        DaySlotPalette.assignments(among: tasks)
    }

    /// A row's day-slot fill: the slot's hue, or its greyed-out variant once
    /// the task is checked off. A finished row keeps a hint of the color it
    /// had so it stays matchable to its block on the strip — the tint recedes
    /// with the task rather than disappearing with it.
    private func slotFill(for task: NudgeTask, in slots: [UUID: Int]) -> Color? {
        slots[task.id].map {
            task.isComplete ? NudgeTheme.daySlotFillCompleted($0) : NudgeTheme.daySlotFill($0)
        }
    }

    /// True when "Plan my day" has auto-placed at least one task today —
    /// gates the "Clear plan" button.
    private var hasAutoPlacements: Bool {
        tasks.contains { task in
            guard task.plannedIsAuto, let p = task.plannedStartDate else { return false }
            return Calendar.current.isDateInToday(p)
        }
    }

    private var incompleteCount: Int {
        actionableTasks.filter { !$0.isComplete }.count
    }

    /// Monday 00:00 of the current calendar week. Still needed after the
    /// "Completed (N)" control's removal: `purgeOldCompletedRecords` keys
    /// its cutoff on this.
    private var weekStart: Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return calendar.date(from: comps) ?? Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Order (2026-08-01-01): header → message box → timeline →
                // Start Session → everything else. The box leads because
                // it's the tab's voice; Start Session moved below the
                // timeline so the day's shape reads before the call to act.
                header
                if profile.tasksMessageBoxEnabled {
                TasksMessageBox(
                    tasks: tasks,
                    tappedNudge: tappedNudgeContext,
                    goals: allGoals.filter { $0.isActive },
                    goalInvite: goalInvite,
                    aiMessage: goalLapseHookMessage,
                    memo: tasksMemo,
                    planProposal: planProposal,
                    onAnswerPlanProposal: { proposal, accepted in
                        answerPlanProposal(proposal, accepted: accepted)
                    },
                    onAnswerCheckIn: { worked in answerCheckIn(worked: worked) },
                    // The hook is the point of the bait's tap — it opens
                    // read-in-full, not as a teaser behind a second tap.
                    startsExpanded: tappedNudgeContext?.kind == .goalLapse,
                    onOpenShell: { message in
                        // Cycles 2026-08-03-04/-05: character, chevron, and
                        // row all open the interactive shell (visual
                        // prototype, all stubs), seeded with what the box
                        // was saying.
                        withAnimation(NudgeAnimation.standard) {
                            messageShellSeed = message
                        }
                    },
                    rationale: refineRationale,
                    prepNote: pendingPrepNote,
                    prepAnnouncement: ExamPrepSweep.currentAnnouncement(),
                    commitmentAnnouncement: ExamPrepSweep.currentCommitmentAnnouncement(),
                    planOutcome: planOutcome,
                    onPrepNoteShown: {
                        if let note = pendingPrepNote { markPrepNoteShown(note) }
                    },
                    onPrepAnnouncementShown: {
                        ExamPrepSweep.markAnnouncementShown()
                    },
                    onCommitmentAnnouncementShown: {
                        ExamPrepSweep.markCommitmentAnnouncementShown()
                    },
                    onAcceptGoalOffer: { goal in
                        acceptGoalOffer(goal)
                    }
                )
                }
                // Plan my day left this row for the button stack below the
                // timeline (cycle 2026-08-03-07); the label and the
                // conditional Clear plan stay.
                HStack(alignment: .center, spacing: 10) {
                    sectionLabel("Today")
                    Spacer()
                    // Plan my day lives beside the label (Roman, Sep 2026)
                    // — it acts on the timeline directly below, and moving
                    // it up gives Start Session the full row.
                    planMyDayButton
                    if hasAutoPlacements {
                        Button {
                            clearPlan()
                        } label: {
                            Text("Clear plan")
                                .font(.custom(NudgeTheme.fontMedium, size: 13))
                                .foregroundColor(NudgeTheme.textMuted)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(NudgeTheme.surfaceAlt)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                // The AI Refine rationale renders through the message box
                // above (its fifth composer state) — one voice in one place.
                TodayTimelineView(
                    profile: profile,
                    slots: daySlots,
                    onOpenTask: { task in
                        // A placed task opens the manage window (with the
                        // remove-from-timeline button); events open the editor.
                        if !task.isInformationalEvent && task.plannedStartDate != nil {
                            activeSheet = .manageTimeline(taskID: task.id)
                        } else {
                            activeSheet = .edit(taskID: task.id)
                        }
                    },
                    onTapEmpty: { placement = PlacementContext(time: $0) },
                    onCompleteTask: { toggleCompletion(for: $0) }
                )
                // Full-bleed (Roman, Sep 16 2026): a horizontal scroller
                // clipped at the page gutter reads as "cut off at the
                // sides". It escapes the gutter and runs edge to edge.
                .padding(.horizontal, -20)
                // Control order: box (chat circle on its corner) →
                // Today row (label + Plan my day + Clear plan) → timeline →
                // Start Session full-width and thin (Roman, Sep 2026 —
                // Plan my day moved up beside the label; the primary action
                // gets the whole row at 38pt, so the lists stay above the
                // fold). The active-session banner keeps its taller
                // full-width form; it carries live content.
                startSessionButton
                listTabStrip
                    .padding(.top, 8)
                selectedTabContent
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        // The interactive shell floats over the whole tab so its backdrop
        // can catch taps anywhere ("tap outside collapses") — an in-row
        // overlay would be clipped by the scroll container. Prototype: the
        // floating app tab bar still renders above the dim layer; accepted
        // under the plan's timebox, noted in the report.
        .overlay {
            if let seed = messageShellSeed {
                MessageBoxChatShell(seed: seed, onDismiss: {
                    withAnimation(NudgeAnimation.standard) {
                        messageShellSeed = nil
                    }
                })
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .onAppear {
            purgeOldCompletedRecords()
            // Pick up a rationale produced elsewhere today (e.g. via the
            // Home chat "plan my day" flow).
            refineRationale = DayPlanRefiner.shared.todaysRationale()
            // Durable idle "Not yet" intent — present the sheet whenever the
            // Tasks tab appears, including a cold launch from the tap.
            consumePendingIdleTask()
            // Durable tapped-nudge context for the message box — same
            // launch-path independence, but read-while-fresh, not one-shot.
            tappedNudgeContext = TappedNudgeContext.read()
            planOutcome = PlanOutcomeContext.read()
            fetchGoalLapseHookIfNeeded()
            fetchTasksMemoIfNeeded()
            planProposal = PlanProposalSweep.shared.currentProposal(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nudgePlanProposalsChanged)) { _ in
            withAnimation(NudgeAnimation.standard) {
                planProposal = PlanProposalSweep.shared.currentProposal(modelContext: modelContext)
            }
        }
        .onChange(of: memoFingerprint) { _, _ in
            // The facts the memo was written from changed (a dump landed,
            // a task tipped overdue, a completion) — cache miss, refetch
            // within the daily cap.
            fetchTasksMemoIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Also consume when returning to the foreground while the Tasks
            // tab is already on screen (onAppear won't re-fire then).
            if newPhase == .active {
                consumePendingIdleTask()
                tappedNudgeContext = TappedNudgeContext.read()
                planOutcome = PlanOutcomeContext.read()
                fetchGoalLapseHookIfNeeded()
                fetchTasksMemoIfNeeded()
                planProposal = PlanProposalSweep.shared.currentProposal(modelContext: modelContext)
            }
        }
        .sheet(item: $placement) { ctx in
            placementSheet(for: ctx)
        }
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .create:
                TaskEditorSheet(
                    mode: .create,
                    onSave: { draft in
                        let newTask = NudgeTask(
                            title: draft.title,
                            dueDate: draft.dueDate,
                            dueTime: draft.dueTimeLabel,
                            specificTime: draft.specificTime,
                            priority: draft.priority,
                            source: "manual",
                            estimatedMinutes: draft.durationMinutes
                        )
                        // The scheduled clock from the editor (day, and a
                        // manual placement when a time was picked).
                        if let day = draft.intendedDate {
                            newTask.intendedDate = Calendar.current.startOfDay(for: day)
                            if let start = draft.plannedStart {
                                newTask.plannedStartDate = start
                                newTask.plannedIsAuto = false
                            }
                        }
                        // If "New task" was chosen from a timeline slot, land
                        // the new task at that time.
                        if let placeAt = pendingPlacementTime {
                            newTask.plannedStartDate = placeAt
                            newTask.intendedDate = Calendar.current.startOfDay(for: placeAt)
                            pendingPlacementTime = nil
                        }
                        // Hand-set stakes: write directly + flag as user-set
                        // so no later automation pass overwrites it.
                        if draft.stakesUserPicked, let picked = draft.stakes {
                            newTask.stakes = picked
                            newTask.stakesIsUserSet = true
                        }
                        modelContext.insert(newTask)
                        try? modelContext.save()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                        // Enrich the new task's signals once, explicitly, at
                        // creation — not on every arbiter read.
                        NudgeIntelligence.shared.refreshSoon(for: newTask)
                        PlanProposalSweep.shared.runIfNeeded(modelContext: modelContext)
                        refreshNotifications()
                    }
                )
                .presentationDetents([.medium, .large])
            case .edit(let taskID):
                if let task = tasks.first(where: { $0.id == taskID }) {
                    TaskEditorSheet(
                        mode: .edit(task: task),
                        onSave: { draft in
                            // The write logic lives in the shared, intent-
                            // aware TaskEditorSheet.apply — one rule, two
                            // call sites (here + the calendar view).
                            TaskEditorSheet.apply(draft, to: task, modelContext: modelContext)
                            try? modelContext.save()
                            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                            // Title may have changed — re-enrich once.
                            NudgeIntelligence.shared.refreshSoon(for: task)
                            PlanProposalSweep.shared.runIfNeeded(modelContext: modelContext)
                            refreshNotifications()
                        },
                        onDelete: {
                            // A deleted generated task (study day or
                            // commitment day) is a decision that persists —
                            // tombstone before the row is gone.
                            ExamPrepSweep.recordDeletionIfGenerated(task, modelContext: modelContext)
                            modelContext.delete(task)
                            try? modelContext.save()
                            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                            refreshNotifications()
                        },
                        // Only offered when the task is actually placed on the
                        // timeline. Clears the placement without deleting it.
                        onRemoveFromTimeline: (!task.isInformationalEvent && task.plannedStartDate != nil)
                            ? { unscheduleTask(task) }
                            : nil
                    )
                    .presentationDetents([.medium, .large])
                }
            case .manageTimeline(let taskID):
                if let task = tasks.first(where: { $0.id == taskID }) {
                    manageTimelineSheet(for: task)
                }
            }
        }
        .sheet(isPresented: $showSessionTaskPicker) {
            SessionTaskPickerSheet(
                tasks: orderedActionableTasks,
                suggested: sessionPickerShowsFullList ? nil : suggestedSessionTask,
                onPick: { task in
                    showSessionTaskPicker = false
                    attemptStartSession(task)
                },
                onCreate: { text in await createSessionItem(text) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: idleSheetIsPresented) {
            if let task = idleProposedTask {
                IdleStartConfirmationSheet(
                    task: task,
                    onConfirm: {
                        idleProposedTaskID = nil
                        attemptStartSession(task)
                    },
                    onPickSomethingElse: {
                        idleProposedTaskID = nil
                        sessionPickerShowsFullList = true
                        showSessionTaskPicker = true
                    }
                )
                .presentationDetents([.height(280), .medium])
            }
        }
        .onReceive(
            // Same Combine main-hop as ContentView's openTab observer.
            // This is the @State write that flips the sheet binding — if
            // it lands off-main, SwiftUI's sheet presentation invokes
            // `_performBlockAfterCATransactionCommitSynchronizes` on the
            // wrong thread and UIKit asserts "Call must be made on main
            // thread". `.receive(on: DispatchQueue.main)` makes the
            // publisher itself responsible for delivering on main, so
            // every subsequent step (state mutation → SwiftUI invalidation
            // → CATransaction commit → sheet present) is main-bound.
            NotificationCenter.default
                .publisher(for: .nudgeIdleNotYetTapped)
                .receive(on: DispatchQueue.main)
        ) { note in
            // Posted from the idle "Not yet" delegate handler with the
            // top open task's UUID. The sheet appears the next time this
            // view is on screen (the delegate also requests the Tasks
            // tab via .nudgeNotificationOpenTab).
            guard let uuidString = note.userInfo?["taskID"] as? String,
                  let uuid = UUID(uuidString: uuidString) else { return }
            idleProposedTaskID = uuid
        }
    }

    /// Reads the DURABLE idle "Not yet" intent from the app group and, if a
    /// valid still-open task is pending from today, presents the confirmation
    /// sheet. This is the launch-path-independent path: it works on cold
    /// launch (where the transient .nudgeIdleNotYetTapped post is missed
    /// because this view wasn't subscribed yet) AND warm resume. Consuming
    /// (clearing) the keys makes it one-shot.
    private func consumePendingIdleTask() {
        let defaults = SharedModelContainer.appGroupDefaults
        guard let idString = defaults.string(forKey: NudgeNotificationService.pendingIdleTaskIDKey),
              let uuid = UUID(uuidString: idString) else { return }

        defer {
            defaults.removeObject(forKey: NudgeNotificationService.pendingIdleTaskIDKey)
            defaults.removeObject(forKey: NudgeNotificationService.pendingIdleTaskDateKey)
        }

        // Ignore a stale intent (e.g. tapped yesterday, app opened today).
        if let date = defaults.object(forKey: NudgeNotificationService.pendingIdleTaskDateKey) as? Date,
           !Calendar.current.isDateInToday(date) {
            return
        }
        // Only present if the task still exists and is open.
        guard tasks.contains(where: { $0.id == uuid && !$0.isComplete }) else { return }
        idleProposedTaskID = uuid
    }

    /// Looks up the proposed task, guarding against deletion or completion
    /// between the notification firing and the user tapping "Not yet".
    private var idleProposedTask: NudgeTask? {
        guard let id = idleProposedTaskID else { return nil }
        return tasks.first(where: { $0.id == id && !$0.isComplete })
    }

    /// Binding wired to `idleProposedTaskID` — clearing it on dismiss is
    /// what flips the sheet closed when the user swipes it down.
    private var idleSheetIsPresented: Binding<Bool> {
        Binding(
            get: { idleProposedTask != nil },
            set: { presented in
                if !presented { idleProposedTaskID = nil }
            }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AccountShortcutButton(selectedTab: $selectedTab)
            // No description line: it narrated the sort order, which the
            // list itself makes obvious. The message box below the header
            // is the tab's voice now.
            ScreenHeader(title: "Tasks")

            Spacer()

            #if DEBUG
            // Testing-only: wipe every task + event. Never ships in release.
            Button(action: {
                NudgeHaptics.medium()
                showDeleteAllAlert = true
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(NudgeTheme.overdue)
                    .frame(width: 42, height: 42)
                    .background(NudgeTheme.overdue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            #endif

            Button(action: {
                NudgeHaptics.medium()
                activeSheet = .create
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        #if DEBUG
        .alert("Delete everything?", isPresented: $showDeleteAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete all", role: .destructive) { deleteAllTasksAndEvents() }
        } message: {
            Text("Removes every task and event. Testing only.")
        }
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No tasks yet")
                .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("Use the Home tab to dump what is on your mind, or add one manually here.")
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// Fixed row height so the reorderable List can be sized inside the
    /// outer ScrollView (a scroll-disabled List needs a bounded height).
    private let planRowHeight: CGFloat = 84

    /// Ordered "Today's plan" — a numbered, long-press-reorderable list.
    /// Uses a scroll-disabled List so SwiftUI's `.onMove` gives native drag
    /// reordering while still living inside the tab's ScrollView. No section
    /// label since the Today tab IS the label; the numbers mark the plan rows.
    private func planSection(tasks planTasksForDay: [NudgeTask], slots: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(planTasksForDay, id: \.id) { task in
                    // The numeral takes the row's slot accent so the number,
                    // the card tint and the block on the strip read as one
                    // thing. It still SHOWS `sequenceIndex` — that's the
                    // number drag-reordering rewrites, and the plan's stated
                    // order is a different claim from where a task landed on
                    // the clock.
                    let slot = slots[task.id]
                    HStack(alignment: .center, spacing: 10) {
                        Text("\(task.sequenceIndex ?? 0).")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(
                                slot.map {
                                    task.isComplete
                                        ? NudgeTheme.daySlotAccentCompleted($0)
                                        : NudgeTheme.daySlotAccent($0)
                                } ?? (task.isComplete ? NudgeTheme.textMuted : NudgeTheme.primary)
                            )
                            .frame(width: 20, alignment: .trailing)
                        TaskRowView(
                            task: task,
                            isLastIncompleteTask: false,
                            onOpen: { activeSheet = .edit(taskID: task.id) },
                            onToggleComplete: { toggleCompletion(for: task) },
                            onDelete: { deleteTask(task) },
                            onConvertToEvent: { setEventFlag(task, isEvent: true) },
                            slotTint: slotFill(for: task, in: slots)
                        )
                    }
                    .frame(height: planRowHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    movePlanTasks(from: source, to: destination, displayed: planTasksForDay)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: planRowHeight * CGFloat(max(planTasksForDay.count, 1)))
        }
    }

    /// Rewrites sequenceIndex to match the dropped order, persists, and
    /// reevaluates (order changes which task the idle nudge suggests first).
    ///
    /// The drag happens on TODAY'S slice of the plan (the only reorderable
    /// lens), but numbering is global across the one active plan: today's
    /// reordered tasks take the leading numbers, other days' plan tasks
    /// follow in their existing relative order. A drag on today's list can
    /// shift a future day's numerals but never reorders that day's tasks
    /// among themselves.
    private func movePlanTasks(from source: IndexSet, to destination: Int, displayed: [NudgeTask]) {
        var reorderedToday = displayed
        reorderedToday.move(fromOffsets: source, toOffset: destination)
        let displayedIDs = Set(displayed.map(\.id))
        let otherDays = planTasks.filter { !displayedIDs.contains($0.id) }
        for (i, task) in (reorderedToday + otherDays).enumerated() {
            task.sequenceIndex = i + 1
        }
        try? modelContext.save()
        NudgeHaptics.light()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    // MARK: - List tabs (below Start Session)

    /// The four one-at-a-time lists below Start Session. Raw value is the
    /// tab label.
    private enum TaskListTab: String, CaseIterable {
        // Chip order is declaration order (Roman, Sep 21 2026): Tasks,
        // Events, Unscheduled, Overdue, Skipped. The `today` case keeps its
        // name in code; its chip reads "Tasks" and holds the day lenses.
        case today = "Tasks"
        case events = "Events"
        case unscheduled = "Unscheduled"
        case overdue = "Overdue"
        /// Single no-due-date tasks skipped twice (Roman, Sep 16 2026),
        /// kept apart from Overdue, which is for owed work only.
        case skipped = "Skipped"
    }

    /// The Events tab's two lenses over the same event data.
    /// The Today tab's three day-lenses (cycle 2026-09-04-01), mirroring
    /// `EventLens`. Raw value is the chip label.
    private enum TodayLens: String, CaseIterable {
        case today = "Today"
        case tomorrow = "Tomorrow"
        case thisWeek = "This week"
    }

    private enum EventLens: String, CaseIterable {
        case thisWeek = "This week"
        case important = "Important"
    }

    /// Overdue tab membership: past due, open, excluding deliberately
    /// low-stakes tasks — the same rule as the row treatment (nil stakes is
    /// not low, so unclassified tasks still count). Includes plan tasks so
    /// the badge count never understates.
    private var overdueTasks: [NudgeTask] {
        let comparator = TaskSortComparator()
        return actionableTasks
            .filter { !$0.isComplete && $0.isOverdue && $0.stakes != .low }
            .sorted { comparator.compare($0, $1) }
    }

    private var listTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TaskListTab.allCases, id: \.self) { tab in
                    listTabChip(tab)
                }
            }
            // Room for the content-indicator stroke, which straddles the
            // chip edge — without this the scroll view clips its top and
            // bottom hairlines.
            .padding(.vertical, 1)
        }
        // Full-bleed with the gutter as scroll margin, so a chip past the
        // edge scrolls under the screen edge instead of being sliced at
        // the page's 20pt gutter.
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .padding(.horizontal, -20)
    }

    /// Whether a tab has anything behind it — drives the unselected chip's
    /// content-indicator border. Same membership rules as each tab's own
    /// body, so the border can't promise content the tab won't show.
    private func tabHasContent(_ tab: TaskListTab) -> Bool {
        switch tab {
        case .unscheduled: return !unscheduledTasks.isEmpty
        case .today:
            // Any lens having content lights the chip (cycle 2026-09-04-01)
            // — the stroke must not promise an empty tab, and must not stay
            // dark when only Tomorrow/This week hold items.
            if hasActivePlan { return true }
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            guard let horizon = cal.date(byAdding: .day, value: 7, to: today) else { return hasActivePlan }
            let anyDayTask = actionableTasks.contains { task in
                guard !task.isComplete, let d = scheduledDay(of: task) else { return false }
                return d >= today && d <= horizon
            }
            return anyDayTask || !thisWeekEvents.isEmpty
        case .events:      return !thisWeekEvents.isEmpty || !importantEvents.isEmpty
        case .overdue:     return !overdueTasks.isEmpty
        case .skipped:     return !skippedTasks.isEmpty
        }
    }

    /// One tab chip. The Overdue tab renders in `NudgeTheme.overdue` red —
    /// with a count badge — only while something is actually overdue; at
    /// zero it drops to the standard chip colors, because red with nothing
    /// behind it is alarm without cause.
    ///
    /// Unselected chips carry a content-indicator border (design feedback
    /// after cycle 2026-08-03-08): a `primary` stroke when the tab has
    /// tasks/events behind it, in the overdue red for the Overdue chip so
    /// its existing color language stays consistent. Selected chips are
    /// filled and show none — you're already looking at that tab.
    private func listTabChip(_ tab: TaskListTab) -> some View {
        let isSelected = selectedListTab == tab
        let overdueCount = overdueTasks.count
        let isRed = tab == .overdue && overdueCount > 0
        let showIndicator = !isSelected && tabHasContent(tab)
        let textColor: Color = isSelected ? .white : (isRed ? NudgeTheme.overdue : NudgeTheme.textPrimary)
        let background: Color = isSelected
            ? (isRed ? NudgeTheme.overdue : NudgeTheme.primary)
            : NudgeTheme.surfaceAlt
        return Button {
            NudgeHaptics.light()
            withAnimation(NudgeAnimation.standard) { selectedListTab = tab }
        } label: {
            HStack(spacing: 6) {
                Text(tab.rawValue)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 13))
                if isRed {
                    Text("\(overdueCount)")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 11))
                        .foregroundColor(isSelected ? NudgeTheme.overdue : .white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white : NudgeTheme.overdue)
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(textColor)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(background)
            .clipShape(Capsule())
            .overlay {
                if showIndicator {
                    Capsule().stroke(
                        isRed ? NudgeTheme.overdue : NudgeTheme.primary,
                        lineWidth: 1.5
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedListTab {
        case .unscheduled: unscheduledTab
        case .today:       todayTab
        case .events:      eventsTab
        case .overdue:     overdueTab
        case .skipped:     skippedTab
        }
    }

    /// The shared task row wiring, used by every tab that renders task rows.
    ///
    /// `slotTint` is the row's day-slot color — passed under Today, where the
    /// tint is what pairs a row with its block on the timeline, and nil in the
    /// other tabs, which aren't showing a day and would just get a rainbow.
    /// The COLOR is passed, not the slot map: `daySlots` scans every task, so
    /// looking it up per row would make Today O(rows × tasks) on each 60s tick.
    private func taskRow(_ task: NudgeTask, slotTint: Color? = nil) -> some View {
        TaskRowView(
            task: task,
            isLastIncompleteTask: incompleteCount == 1 && !task.isComplete,
            onOpen: { activeSheet = .edit(taskID: task.id) },
            onToggleComplete: { toggleCompletion(for: task) },
            onDelete: { deleteTask(task) },
            onConvertToEvent: { setEventFlag(task, isEvent: true) },
            slotTint: slotTint
        )
    }

    /// Quiet one-line empty state for a tab whose list has nothing in it.
    private func tabEmptyLine(_ text: String) -> some View {
        Text(text)
            .font(.custom(NudgeTheme.fontBody, size: 14))
            .foregroundColor(NudgeTheme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }

    // MARK: Unscheduled tab (with per-parent generated-task collapsing)

    /// A row in the Unscheduled tab: a plain task, or a parent's generated
    /// daily tasks (exam prep OR commitment dailies — a 2-week rate is 14
    /// rows) folded into one group (visible head + collapsible rest).
    private enum UnscheduledItem: Identifiable {
        case task(NudgeTask)
        case prepGroup(examId: String, head: NudgeTask, rest: [NudgeTask])

        var id: String {
            switch self {
            case .task(let task):              return task.id.uuidString
            case .prepGroup(let examId, _, _): return "prep-\(examId)"
            }
        }
    }

    /// Unscheduled rows with prep tasks grouped per exam. The list is
    /// comparator-sorted, so each exam's head is its nearest study day —
    /// today's, whenever the sweep is current — sitting at that task's
    /// natural sort position; the exam's remaining days collapse behind one
    /// "Show N more" control (the Events section's collapse idiom).
    private var unscheduledItems: [UnscheduledItem] {
        let listed = unscheduledTasks
        let generatedSources: Set<String> = ["prep", "commitment"]
        let prepByExam = Dictionary(
            grouping: listed.filter { generatedSources.contains($0.source) && $0.linkedEventId != nil },
            by: { $0.linkedEventId ?? "" }
        )
        var seenExams = Set<String>()
        var items: [UnscheduledItem] = []
        for task in listed {
            if generatedSources.contains(task.source), let examId = task.linkedEventId {
                guard seenExams.insert(examId).inserted else { continue }
                let group = prepByExam[examId] ?? [task]
                items.append(.prepGroup(
                    examId: examId,
                    head: group[0],
                    rest: Array(group.dropFirst())
                ))
            } else {
                items.append(.task(task))
            }
        }
        return items
    }

    @ViewBuilder
    private var unscheduledTab: some View {
        if unscheduledTasks.isEmpty {
            if incompleteCount == 0 && eventItems.isEmpty && !hasActivePlan {
                emptyState
            } else {
                tabEmptyLine("Nothing unscheduled.")
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(unscheduledItems) { item in
                    switch item {
                    case .task(let task):
                        taskRow(task)
                    case .prepGroup(let examId, let head, let rest):
                        taskRow(head)
                        if !rest.isEmpty {
                            if expandedPrepExams.contains(examId) {
                                ForEach(rest, id: \.id) { taskRow($0) }
                            }
                            prepToggleButton(
                            examId: examId,
                            hiddenCount: rest.count,
                            unit: head.source == "prep" ? "study day" : "day"
                        )
                        }
                    }
                }
            }
        }
    }

    /// Per-parent "Show N more" control — same styling as the Events tab's
    /// show-more-days button, one idiom for all the collapses. `unit` is
    /// "study day" for exam prep, "day" for commitment dailies.
    private func prepToggleButton(examId: String, hiddenCount: Int, unit: String) -> some View {
        let isExpanded = expandedPrepExams.contains(examId)
        return Button {
            NudgeHaptics.light()
            withAnimation(NudgeAnimation.standard) {
                if isExpanded {
                    expandedPrepExams.remove(examId)
                } else {
                    expandedPrepExams.insert(examId)
                }
            }
        } label: {
            Text(isExpanded
                 ? "Show fewer \(unit)s"
                 : "Show \(hiddenCount) more \(unit)\(hiddenCount == 1 ? "" : "s")")
                .font(.custom(NudgeTheme.fontMedium, size: 14))
                .foregroundColor(NudgeTheme.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
        .buttonStyle(.plain)
    }

    // MARK: Today tab — three lenses (cycle 2026-09-04-01)

    /// Today / Tomorrow / This week, mirroring the Events tab's lens
    /// pattern. Membership is DAY-based: a task belongs to its intent day,
    /// else its placement's day (`scheduledDay`); a plan task with no day
    /// of its own is today's plan. Each lens shows that day's events AND
    /// its tasks — the fix for tomorrow's plan bleeding into Today.
    @ViewBuilder
    private var todayTab: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: 16) {
            todayLensPicker
            switch todayLens {
            case .today:
                todayLensBody(today: today)
            case .tomorrow:
                dayLensBody(day: cal.date(byAdding: .day, value: 1, to: today) ?? today)
            case .thisWeek:
                thisWeekLensBody(today: today)
            }
        }
    }

    private var todayLensPicker: some View {
        HStack(spacing: 8) {
            ForEach(TodayLens.allCases, id: \.self) { lens in
                let isSelected = todayLens == lens
                Button {
                    NudgeHaptics.light()
                    withAnimation(NudgeAnimation.standard) { todayLens = lens }
                } label: {
                    Text(lens.rawValue)
                        .font(.custom(NudgeTheme.fontMedium, size: 12))
                        .foregroundColor(isSelected ? .white : NudgeTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(isSelected ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    /// The Today lens keeps everything the old tab had — reorderable plan,
    /// slot-tinted rows, the Plan-my-day empty state — and adds today's
    /// events between them (Roman: "the today tab should also show events").
    @ViewBuilder
    private func todayLensBody(today: Date) -> some View {
        let plan = planTasks(on: today)
        let dayTasks = dayTasks(on: today)
        let events = dayEvents(on: today)
        let hasOpenPlan = plan.contains { !$0.isComplete }
        if !hasOpenPlan && dayTasks.isEmpty && events.isEmpty {
            // Nothing on today (Roman, Sep 16 2026): still offer something
            // to work on — the fillers (floaters, loose tasks) and work
            // that could be done early — above the Plan my day button.
            VStack(alignment: .leading, spacing: 12) {
                let fillers = fillerCandidates(today: today)
                if !fillers.isEmpty {
                    Text("Nothing planned yet. You could work on:")
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                    ForEach(fillers, id: \.id) { taskRow($0) }
                }
                planMyDayEmptyButton
            }
        } else {
            // Resolved ONCE for the whole lens — `daySlots` scans every
            // task, and this body re-evaluates on the 60s clock tick.
            let slots = daySlots
            VStack(alignment: .leading, spacing: 20) {
                if hasOpenPlan {
                    planSection(tasks: plan, slots: slots)
                }
                if !events.isEmpty {
                    lensEventRows(events)
                }
                if !dayTasks.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(dayTasks, id: \.id) { task in
                            taskRow(task, slotTint: slotFill(for: task, in: slots))
                        }
                    }
                }
            }
        }
    }

    /// One future day (Tomorrow lens): numbered plan rows WITHOUT drag
    /// reordering — a sequence spanning days can't be coherently reordered
    /// from one day's slice — then events, then tasks. No slot tints: slots
    /// describe today's timeline only.
    @ViewBuilder
    private func dayLensBody(day: Date) -> some View {
        let plan = planTasks(on: day)
        let dayTasks = dayTasks(on: day)
        let events = dayEvents(on: day)
        VStack(alignment: .leading, spacing: 20) {
            // Plan-ahead (cycle 2026-09-13-03): same free deterministic
            // engine, pointed at this day. Its placements are marked
            // manual, so tomorrow's morning auto-run respects them and
            // fills the remaining gaps with whatever arrives overnight.
            HStack {
                Spacer()
                Button {
                    planFutureDay(day)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Plan tomorrow")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 13))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(NudgeTheme.primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if plan.isEmpty && dayTasks.isEmpty && events.isEmpty {
                tabEmptyLine("Nothing scheduled yet.")
            } else {
                if !plan.isEmpty { staticPlanRows(plan) }
                if !events.isEmpty { lensEventRows(events) }
                if !dayTasks.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(dayTasks, id: \.id) { taskRow($0) }
                    }
                }
            }
        }
    }

    private func planFutureDay(_ day: Date) {
        NudgeHaptics.medium()
        DayPlanEngine.plan(day: day, profile: profile, modelContext: modelContext)
        refreshNotifications()
    }

    /// Days +2 through +7, grouped with the Events tab's day-header idiom.
    @ViewBuilder
    private func thisWeekLensBody(today: Date) -> some View {
        let cal = Calendar.current
        let days = (2...7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let populated = days.filter { day in
            !planTasks(on: day).isEmpty || !dayTasks(on: day).isEmpty || !dayEvents(on: day).isEmpty
        }
        if populated.isEmpty {
            tabEmptyLine("Nothing scheduled for the rest of the week.")
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(populated, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(eventDayHeader(for: day))
                            .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                        let plan = planTasks(on: day)
                        let dayTasks = dayTasks(on: day)
                        let events = dayEvents(on: day)
                        if !plan.isEmpty { staticPlanRows(plan) }
                        if !events.isEmpty { lensEventRows(events) }
                        if !dayTasks.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(dayTasks, id: \.id) { taskRow($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// What an empty Today can offer: open single tasks with no day of
    /// their own (floaters, loose tasks) and due-dated work whose anchor
    /// is still ahead (could be done early). Skipped tasks and other days'
    /// intentions stay out; comparator order; a short list on purpose.
    private func fillerCandidates(today: Date) -> [NudgeTask] {
        sortedTasks
            .filter { task in
                guard task.linkedEventId == nil || task.intendedDate == nil else { return false }
                if let day = task.scheduledDay { return day <= today }
                if task.hasDeadline { return task.sortDeadline >= Date() }
                return true
            }
            .prefix(6)
            .map { $0 }
    }

    private var planMyDayEmptyButton: some View {
        Button {
            planMyDay()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                Text("Plan my day")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 13))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(NudgeTheme.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Plan rows for a non-today day: same numeral + row as the reorderable
    /// section, minus the List/onMove and minus slot accents.
    private func staticPlanRows(_ tasks: [NudgeTask]) -> some View {
        VStack(spacing: 12) {
            ForEach(tasks, id: \.id) { task in
                HStack(alignment: .center, spacing: 10) {
                    Text("\(task.sequenceIndex ?? 0).")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(task.isComplete ? NudgeTheme.textMuted : NudgeTheme.primary)
                        .frame(width: 20, alignment: .trailing)
                    TaskRowView(
                        task: task,
                        isLastIncompleteTask: false,
                        onOpen: { activeSheet = .edit(taskID: task.id) },
                        onToggleComplete: { toggleCompletion(for: task) },
                        onDelete: { deleteTask(task) },
                        onConvertToEvent: { setEventFlag(task, isEvent: true) }
                    )
                }
            }
        }
    }

    /// Event rows inside a day lens — the Events tab's row, minus the
    /// routine detection (a single day's slice can't see repetition).
    private func lensEventRows(_ events: [NudgeTask]) -> some View {
        VStack(spacing: 12) {
            ForEach(events, id: \.id) { event in
                EventRowView(
                    task: event,
                    onOpen: { activeSheet = .edit(taskID: event.id) },
                    onDelete: { deleteTask(event) },
                    onConvertToTask: { setEventFlag(event, isEvent: false) },
                    onSetTime: { setEventTime(event, to: $0) }
                )
            }
        }
    }

    // MARK: Events tab

    @ViewBuilder
    private var eventsTab: some View {
        let lensEvents = eventLens == .thisWeek ? thisWeekEvents : importantEvents
        let groups = eventDayGroups(for: lensEvents)
        VStack(alignment: .leading, spacing: 16) {
            eventLensPicker
            if groups.isEmpty {
                tabEmptyLine(eventLens == .thisWeek
                             ? "No events in the next 7 days."
                             : "No high-stakes events.")
            } else {
                // Computed once per render, not once per row — the repeat
                // count scans every event. Deliberately counted over ALL
                // events (both lenses), the population the routine rule was
                // validated against.
                let routineTitles = routineRepeatedTitles
                let expandedGroups = Array(groups.prefix(NudgeConfig.eventsExpandedDays))
                let collapsedGroups = Array(groups.dropFirst(NudgeConfig.eventsExpandedDays))
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(expandedGroups) { group in
                        eventDaySection(group, routineTitles: routineTitles)
                    }

                    if showAllEventDays {
                        ForEach(collapsedGroups) { group in
                            eventDaySection(group, routineTitles: routineTitles)
                        }
                    }

                    if !collapsedGroups.isEmpty {
                        Button {
                            NudgeHaptics.light()
                            withAnimation(NudgeAnimation.standard) {
                                showAllEventDays.toggle()
                            }
                        } label: {
                            Text(showAllEventDays
                                 ? "Show fewer days"
                                 : "Show \(collapsedGroups.count) more day\(collapsedGroups.count == 1 ? "" : "s")")
                                .font(.custom(NudgeTheme.fontMedium, size: 14))
                                .foregroundColor(NudgeTheme.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(NudgeTheme.surfaceAlt)
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var eventLensPicker: some View {
        HStack(spacing: 8) {
            ForEach(EventLens.allCases, id: \.self) { lens in
                let isSelected = eventLens == lens
                Button {
                    NudgeHaptics.light()
                    withAnimation(NudgeAnimation.standard) { eventLens = lens }
                } label: {
                    Text(lens.rawValue)
                        .font(.custom(NudgeTheme.fontMedium, size: 12))
                        .foregroundColor(isSelected ? .white : NudgeTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(isSelected ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: Overdue tab

    @ViewBuilder
    private var overdueTab: some View {
        if overdueTasks.isEmpty {
            tabEmptyLine("Nothing overdue.")
        } else {
            VStack(spacing: 12) {
                ForEach(overdueTasks, id: \.id) { taskRow($0) }
            }
        }
    }

    /// Skipped (Roman, Sep 16 2026): a task the user put on Today twice
    /// and did not finish. Dating or placing it again brings it back.
    @ViewBuilder
    private var skippedTab: some View {
        if skippedTasks.isEmpty {
            tabEmptyLine("Nothing skipped.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Put on Today twice and not finished. Date it or place it again to bring it back.")
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.textMuted)
                ForEach(skippedTasks, id: \.id) { taskRow($0) }
            }
        }
    }

    /// Plan my day, half of the compact 44pt action row beside Start
    /// Session (same treatment on purpose — the pair's visual distinction
    /// is a separate upcoming decision; the compact row is about the task
    /// lists staying above the fold, not about telling the two apart).
    /// Compact capsule form, sized for the Today label row beside Clear
    /// plan (Roman, Sep 2026 — moved up from the post-timeline row so
    /// Start Session gets that row to itself).
    private var planMyDayButton: some View {
        Button(action: planMyDay) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))

                Text("Plan my day")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 13))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(NudgeTheme.primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var startSessionButton: some View {
        Group {
            if coordinator.isSessionActive {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: sessionStateIcon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(sessionStateLabel)
                                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                                .foregroundColor(.white)

                            Text(coordinator.currentTaskName)
                                .font(.custom(NudgeTheme.fontBody, size: 12))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }

                        Spacer()

                        if coordinator.sessionState == .active {
                            Button(action: {
                                NudgeHaptics.medium()
                                coordinator.completeCurrentTask()
                            }) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(NudgeTheme.primary)
                                    .frame(width: 34, height: 34)
                                    .background(.white)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: {
                            NudgeHaptics.medium()
                            showCancelSessionAlert = true
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(sessionStateTint)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .alert(item: $sessionStartConflict) { pending in
                    Alert(
                        title: Text("Starting now overlaps \(pending.conflict.isEvent ? "an event" : "a task")"),
                        message: Text("\(pending.conflict.title) is at \(pending.conflict.timeLabel) and can't be moved. Start anyway and they'll overlap on the timeline."),
                        primaryButton: .default(Text("Start anyway")) {
                            coordinator.startSession(task: pending.task, userName: profile.name)
                        },
                        secondaryButton: .cancel()
                    )
                }
                .alert("Cancel Session?", isPresented: $showCancelSessionAlert) {
                    Button("Keep going", role: .cancel) { }
                    Button("Cancel session", role: .destructive) {
                        coordinator.cancelSession()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                    }
                } message: {
                    Text("This will end your current session and stop all timers.")
                }
            } else {
                // Full-width, thinner form (Roman, Sep 2026): with Plan my
                // day moved up to the Today row, the primary action owns
                // this row alone — longer and 38pt tall.
                Button(action: startSession) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .bold))

                        Text("Start Session")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sessionStateLabel: String {
        coordinator.sessionState == .complete ? "All Done" : "Focusing"
    }

    private var sessionStateIcon: String {
        coordinator.sessionState == .complete ? "checkmark.circle.fill" : "bolt.fill"
    }

    private var sessionStateTint: Color {
        coordinator.sessionState == .complete
            ? NudgeTheme.goalAccent
            : NudgeTheme.primary
    }

    private func toggleCompletion(for task: NudgeTask) {
        let newValue = !task.isComplete

        withAnimation(NudgeAnimation.standard) {
            task.isComplete = newValue
        }

        if newValue {
            let completionDate = Date()
            task.completedAt = completionDate

            // Completing a goal-linked task counts as working on the goal.
            NudgeGoal.recordActivity(
                goalID: task.goalID, at: completionDate, in: modelContext
            )

            // Completing a count task wholesale (timeline long-press, or
            // the final unit tap that funnels here) means the whole day's
            // count — the two numbers must agree.
            if let target = task.effectiveTargetCount {
                task.completedCount = target
            }

            // Create a persistent record so stats survive task deletion
            let sourceID = task.id
            let existing = try? modelContext.fetch(
                FetchDescriptor<CompletedTaskRecord>(
                    predicate: #Predicate<CompletedTaskRecord> { $0.sourceTaskID == sourceID }
                )
            ).first
            if existing == nil {
                let record = CompletedTaskRecord(
                    title: task.title,
                    priority: task.priority,
                    completedAt: completionDate,
                    sourceTaskID: task.id
                )
                modelContext.insert(record)
            }
        } else {
            task.completedAt = nil

            // Un-completing a count task steps back one unit — otherwise
            // the count still reads "met" and the next tap re-completes.
            if let target = task.effectiveTargetCount {
                task.completedCount = max(0, target - 1)
            }

            // Remove the record if unchecking
            let sourceID = task.id
            if let record = try? modelContext.fetch(
                FetchDescriptor<CompletedTaskRecord>(
                    predicate: #Predicate<CompletedTaskRecord> { $0.sourceTaskID == sourceID }
                )
            ).first {
                modelContext.delete(record)
            }
        }

        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")

        // Re-evaluate the wasting-time nudge + class/work reminders. If the
        // user just completed a task, this cancels today's pending nudge.
        refreshNotifications()

        // If the coordinator session is active and the task being completed is
        // the CURRENT block, advance the session. Completing any other task
        // (out-of-order) must NOT advance the coordinator's index.
        if coordinator.isSessionActive
            && newValue
            && coordinator.currentTaskID == task.id {
            coordinator.completeCurrentTask()
        }

        guard newValue, incompleteCount == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NudgeHaptics.success()
        }
    }

    private func deleteTask(_ task: NudgeTask) {
        NudgeHaptics.light()
        // A deleted generated task (study day or commitment day) is a
        // decision that persists (`DESIGN.md`) — record the tombstone
        // BEFORE the row is gone so `ExamPrepSweep` never recreates this
        // day. (The DEBUG wipe-everything helper below deliberately does
        // NOT tombstone: it resets a test store, and poisoning every
        // sweep would defeat the reset.)
        ExamPrepSweep.recordDeletionIfGenerated(task, modelContext: modelContext)
        withAnimation(NudgeAnimation.standard) {
            modelContext.delete(task)
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    #if DEBUG
    /// Testing-only: wipes every NudgeTask (tasks AND events). Not compiled
    /// into release builds.
    private func deleteAllTasksAndEvents() {
        NudgeHaptics.medium()
        withAnimation(NudgeAnimation.standard) {
            for task in tasks {
                modelContext.delete(task)
            }
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }
    #endif

    /// One-tap correction when the AI misclassified an item. Flips it
    /// between task and event, then re-runs the arbiter since the two are
    /// scheduled differently (events get factual heads-ups; tasks get
    /// discretionary nudges).
    private func setEventFlag(_ task: NudgeTask, isEvent: Bool) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            task.isInformationalEvent = isEvent
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    /// Fills in a missing start time on an event (from the "needs a time"
    /// chip). Combines the chosen clock time with the event's existing day
    /// (or today if it had no date), then re-runs the arbiter so the event
    /// reminder can schedule immediately.
    private func setEventTime(_ event: NudgeTask, to time: Date) {
        let cal = Calendar.current
        let timeComps = cal.dateComponents([.hour, .minute], from: time)
        // If the event already has a day, keep it (time-only edit). If not,
        // the picker included a date, so take the day from the picked value.
        let baseDay = event.dueDate ?? time
        var dayComps = cal.dateComponents([.year, .month, .day], from: baseDay)
        dayComps.hour = timeComps.hour
        dayComps.minute = timeComps.minute
        let combined = cal.date(from: dayComps)

        withAnimation(NudgeAnimation.standard) {
            event.specificTime = combined
            if event.dueDate == nil { event.dueDate = combined }
            if let combined {
                let fmt = DateFormatter()
                fmt.dateFormat = "h:mm a"
                event.dueTime = fmt.string(from: combined)
            }
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    // MARK: - Timeline placement

    /// Identifies a tapped empty-timeline slot for the placement sheet.
    struct PlacementContext: Identifiable {
        let id = UUID()
        let time: Date
    }

    /// Places (or moves) a task onto today's timeline at `time`. Does NOT
    /// touch dueDate/specificTime — placement is independent of the deadline.
    private func placeTask(_ task: NudgeTask, at time: Date) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            task.plannedStartDate = time
            task.plannedIsAuto = false   // user-placed
            task.skipCount = 0           // a fresh request from the user
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    /// Clears a task's timeline placement (back to Unscheduled).
    private func unscheduleTask(_ task: NudgeTask) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            task.plannedStartDate = nil
            task.plannedIsAuto = false
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    // MARK: - Plan my day (deterministic, no AI)

    /// The Tasks-tab button — delegates to `DayPlanEngine` (extracted in
    /// cycle 2026-08-02-02 so the morning auto-run can plan without this
    /// view) as a REPLAN: today's auto placements are released and
    /// re-placed, manual ones untouched, so a second tap re-rolls the plan
    /// instead of erroring on an empty candidate pool. Deliberately NOT
    /// merged with Clear plan: this is the re-roll, Clear plan is the undo
    /// (remove the auto plan, place nothing) — one button can't say both.
    private func planMyDay() {
        let outcome = DayPlanEngine.planToday(
            profile: profile,
            modelContext: modelContext,
            clearAutoFirst: true
        )
        switch outcome {
        case .placed(_, _, _, let outOfBand):
            // The placements on the timeline are the feedback; clear any
            // earlier refusal message ("clears on the next successful
            // plan"). A displacement during a manual REPLAN needs no
            // narration either: the replan released every auto placement
            // first, so "released and not re-placed" is the pass's normal
            // shape, already visible in Unscheduled. A band refusal is the
            // exception (cycle 2026-08-04-01 item 1): unlike everything
            // above it leaves no visible trace, so it's written instead of
            // cleared — the message box names the task and the hours rule.
            if outOfBand.isEmpty {
                PlanOutcomeContext.clear()
                planOutcome = nil
            } else {
                PlanOutcomeContext.write(
                    kind: .planned,
                    outOfBandTitles: outOfBand.map(\.title),
                    outOfBandBands: outOfBand.map(\.band.rawValue),
                    isAuto: false
                )
                planOutcome = PlanOutcomeContext.read()
            }
            NudgeHaptics.success()
        case .noCandidates:
            recordPlanOutcome(.noCandidates)
        case .noRoom(let contention, let outOfBand):
            recordPlanOutcome(
                .noRoom,
                contentionTitle: contention,
                outOfBand: outOfBand
            )
        case .windowCollapsed:
            recordPlanOutcome(.windowCollapsed)
        }
        // Reevaluate on every outcome: even a refusal may have RELEASED
        // auto placements (replan pass) before finding no room, and the
        // arbiter must see the store as it now is.
        refreshNotifications()
    }

    /// Removes only auto (Plan my day) placements from today; keeps manual
    /// ones.
    private func clearPlan() {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            for task in tasks {
                guard task.plannedIsAuto, let p = task.plannedStartDate,
                      Calendar.current.isDateInToday(p) else { continue }
                task.plannedStartDate = nil
                task.plannedDurationMinutes = nil
                task.plannedIsAuto = false
            }
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    @ViewBuilder
    private func manageTimelineSheet(for task: NudgeTask) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(task.title)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 18))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .multilineTextAlignment(.center)
                    if let planned = task.plannedStartDate {
                        Text("Placed at \(planned.formatted(date: .omitted, time: .shortened))")
                            .font(.custom(NudgeTheme.fontBody, size: 13))
                            .foregroundColor(NudgeTheme.textMuted)
                    }
                }
                .padding(.top, 12)

                // Swap this slot for a different task: free the slot, then
                // open the placement picker at the same time.
                Button {
                    let time = task.plannedStartDate
                    unscheduleTask(task)
                    activeSheet = nil
                    if let time {
                        DispatchQueue.main.async { placement = PlacementContext(time: time) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Swap for another task")
                    }
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                    .foregroundColor(NudgeTheme.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(NudgeTheme.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)

                Button {
                    let id = task.id
                    activeSheet = nil
                    DispatchQueue.main.async { activeSheet = .edit(taskID: id) }
                } label: {
                    Text("Open task details")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(20)
            .background(NudgeTheme.background)
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { activeSheet = nil }
                }
                // Small remove button, top-right.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        unscheduleTask(task)
                        activeSheet = nil
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(NudgeTheme.overdue)
                    }
                    .accessibilityLabel("Remove from timeline")
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    @ViewBuilder
    private func placementSheet(for ctx: PlacementContext) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        NudgeHaptics.light()
                        pendingPlacementTime = ctx.time
                        placement = nil
                        // Present the create editor on the next runloop tick
                        // so the placement sheet finishes dismissing first.
                        DispatchQueue.main.async { activeSheet = .create }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("New task")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            Spacer()
                        }
                        .foregroundColor(NudgeTheme.primary)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(NudgeTheme.primary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                    }
                    .buttonStyle(.plain)

                    if unscheduledTasks.isEmpty {
                        Text("No unscheduled tasks to place.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(unscheduledTasks, id: \.id) { task in
                            Button {
                                placeTask(task, at: ctx.time)
                                placement = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title)
                                        .font(.custom(NudgeTheme.fontMedium, size: 15))
                                        .foregroundColor(NudgeTheme.textPrimary)
                                    // Importance (stakes), one channel app-wide.
                                    // "—" when unclassified (nil stakes).
                                    Text(task.stakes?.rawValue.capitalized ?? "·")
                                        .font(.custom(NudgeTheme.fontBody, size: 12))
                                        .foregroundColor(NudgeTheme.textMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(NudgeTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                                .overlay(
                                    RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                                        .stroke(NudgeTheme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle("Place at \(ctx.time.formatted(date: .omitted, time: .shortened))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { placement = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Records a no-placement planner outcome: persists it for the message
    /// box (App Group, today-scoped), refreshes the box immediately, and
    /// gives the shared refusal haptic. The message carries the
    /// distinction between refusal kinds; the haptic only says "nothing
    /// was placed."
    private func recordPlanOutcome(
        _ kind: PlanOutcomeContext.Kind,
        contentionTitle: String? = nil,
        outOfBand: [DayPlanEngine.BandRefusal] = []
    ) {
        PlanOutcomeContext.write(
            kind: kind,
            contentionTitle: contentionTitle,
            outOfBandTitles: outOfBand.map(\.title),
            outOfBandBands: outOfBand.map(\.band.rawValue),
            isAuto: false
        )
        planOutcome = PlanOutcomeContext.read()
        NudgeHaptics.error()
    }

    /// Re-runs every notification decision via the arbiter using the
    /// current data state. The reason flag lets the arbiter pick the
    /// appropriate cancel/keep semantics for the trigger.
    private func refreshNotifications(reason: NudgeArbiterReason = .taskCreatedOrEdited) {
        NudgeArbiter.shared.reevaluate(
            reason: reason,
            profile: profile,
            modelContext: modelContext
        )
    }

    /// Deletes CompletedTaskRecord rows from any week prior to the current one.
    /// Runs on appear, so the cleanup happens whenever the user opens the tab
    /// on or after a Monday boundary.
    private func purgeOldCompletedRecords() {
        let cutoff = weekStart
        let stale = completedRecords.filter { $0.completedAt < cutoff }
        guard !stale.isEmpty else { return }
        for record in stale {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    /// "Add your own" from the session picker (Roman, Sep 25 2026): the same
    /// capture path as the Home chat, empty history, the current task list
    /// and goals as context, then the same aftermath. Returns the first
    /// task the dump created (the session starts on it), or reports an
    /// event, nothing, or a failure. Rows written stay written either way.
    private func createSessionItem(_ text: String) async -> SessionCreateResult {
        let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"; iso.locale = Locale(identifier: "en_US_POSIX")
        let existing = tasks.filter { !$0.isComplete }.map { task in
            ExistingTaskContext(id: task.id.uuidString, title: task.title, priority: task.priority,
                                category: task.category, estimatedMinutes: task.estimatedMinutes,
                                dueDate: task.dueDate.map { iso.string(from: $0) })
        }
        let goalContexts = allGoals.filter { $0.isActive }.enumerated().map { i, g in
            ActiveGoalContext(ref: "G\(i + 1)", id: g.id, title: g.title)
        }
        do {
            let response = try await ClaudeService.shared.sendChat(
                conversationHistory: [], userMessage: text,
                existingTasks: existing, knownCommitmentSizes: [], activeGoals: goalContexts
            )
            let written = CaptureWriter.apply(
                response: response, allTasks: tasks, goalContexts: goalContexts,
                modelContext: modelContext, userMessage: text
            )
            try modelContext.save()
            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
            for row in written.created { NudgeIntelligence.shared.refreshSoon(for: row) }
            ExamPrepSweep.shared.run(modelContext: modelContext)
            PlanProposalSweep.shared.runIfNeeded(modelContext: modelContext)
            refreshNotifications()
            if let task = written.created.first(where: { !$0.isInformationalEvent }) { return .task(task) }
            if let event = written.created.first(where: { $0.isInformationalEvent }) { return .event(title: event.title) }
            return .nothing
        } catch {
            #if DEBUG
            print("[SessionPicker] add-your-own failed: \(error)")
            #endif
            return .failed
        }
    }

    /// Starts a session unless the block it would put at now runs into an
    /// anchored item; then the alert above asks first.
    private func attemptStartSession(_ task: NudgeTask) {
        let minutes = coordinator.sessionMinutes(for: task)
        if !task.isInformationalEvent,
           let conflict = TimelineReflow.anchoredConflict(for: task, start: Date(), minutes: minutes, pinStart: true, modelContext: modelContext) {
            NudgeHaptics.light()
            sessionStartConflict = SessionStartConflict(task: task, conflict: conflict)
            return
        }
        coordinator.startSession(task: task, userName: profile.name)
    }

    private func startSession() {
        NudgeHaptics.medium()
        guard !coordinator.isSessionActive else { return }

        let incompleteTasks = actionableTasks.filter { !$0.isComplete }
        guard !incompleteTasks.isEmpty else { return }

        sessionPickerShowsFullList = false
        showSessionTaskPicker = true
    }

    /// One day's section in the Events list: a day header over that day's
    /// event rows. The header is the quietest text layer (muted), so the rows
    /// — and their high-stakes emphasis — carry the visual weight.
    @ViewBuilder
    private func eventDaySection(_ group: EventDayGroup, routineTitles: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eventDayHeader(for: group.day))
                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                .foregroundColor(NudgeTheme.textMuted)

            VStack(spacing: 12) {
                ForEach(group.events, id: \.id) { event in
                    EventRowView(
                        task: event,
                        titleRepeatsAsRoutine: routineTitles.contains(
                            Self.normalizedEventTitle(event.title)
                        ),
                        onOpen: { activeSheet = .edit(taskID: event.id) },
                        onDelete: { deleteTask(event) },
                        onConvertToTask: { setEventFlag(event, isEvent: false) },
                        onSetTime: { setEventTime(event, to: $0) }
                    )
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.custom(NudgeTheme.fontSemiBold, size: 18))
            .foregroundColor(NudgeTheme.textPrimary)
    }
}

// MARK: - Shared stakes row styling
//
// The high-stakes visual treatment shared by task and event rows: the amber
// "High" pill and the semibold title weight. Task rows layer their own
// time-pressure states (overdue / approaching / sitting) on top; event rows
// use ONLY these two, because those time states are task concepts.

/// Amber "High" importance pill. Shared so a high-stakes item reads identically
/// whether it's a task or an event. Callers guard on stakes/completion; this is
/// purely the pill's appearance. Its text is folded into the row title's
/// VoiceOver label, so it stays hidden from the a11y tree here.
struct HighStakesPill: View {
    var body: some View {
        Text("High")
            .font(.custom(NudgeTheme.fontSemiBold, size: 11))
            .foregroundColor(NudgeTheme.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NudgeTheme.amber.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

enum StakesRowStyle {
    /// Semibold title when the row is high-stakes, else the normal medium
    /// weight. Task rows pass their calm high-stakes state (the weight bump is
    /// suppressed under time pressure, where color carries the signal); event
    /// rows pass the event's stakes directly.
    static func titleFontName(isHighStakes: Bool) -> String {
        isHighStakes ? NudgeTheme.fontSemiBold : NudgeTheme.fontMedium
    }
}

// MARK: - Task Row

struct TaskRowView: View {
    @Bindable var task: NudgeTask
    @Environment(\.modelContext) private var modelContext
    let isLastIncompleteTask: Bool
    let onOpen: () -> Void
    let onToggleComplete: () -> Void
    let onDelete: () -> Void
    /// Flips this task into an event (isInformationalEvent = true) when the
    /// AI misclassified it. One-tap correction.
    let onConvertToEvent: () -> Void
    /// Day-slot tint (`NudgeTheme.daySlotFill`) when this row is showing under
    /// Today, where it pairs the row with its block on the timeline. Nil
    /// everywhere else, which leaves the row exactly as it was.
    var slotTint: Color? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(priorityColor)
                .frame(width: 10, height: 10)

            // Quantity tasks ("three applications a day") replace the single
            // checkbox with per-unit progress: the task does not complete
            // until the count is met. Everything else keeps the checkbox.
            if let target = task.effectiveTargetCount, !task.isComplete {
                countControl(target: target)
            } else {
                Button(action: onToggleComplete) {
                    ZStack {
                        Circle()
                            .stroke(task.isComplete ? NudgeTheme.primary : NudgeTheme.border, lineWidth: 2)
                            .fill(task.isComplete ? NudgeTheme.primary : Color.clear)
                            .frame(width: 28, height: 28)

                        if task.isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .checkboxBounce(isComplete: $task.isComplete)
            }

            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .leading) {
                    Text(task.title)
                        .font(.custom(titleFontName, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .strikethrough(task.isComplete, color: NudgeTheme.textMuted)
                        .accessibilityLabel(titleAccessibilityLabel)

                    if task.isComplete {
                        AnimatedStrikethrough(isVisible: $task.isComplete)
                    }
                }

                // Subtitle slot — the remaining-time line ("12 hours left" /
                // "5 days away"), recolored coral when the deadline is
                // approaching, or the amber "Sitting N days" line for aging
                // low-stakes floaters. Nil ⇒ no subtitle, so calm rows stay
                // exactly as before.
                if let subtitle {
                    Text(subtitle.text)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(subtitle.color)
                }
            }

            Spacer()

            // Right-side date + clock-time line. Hidden for floaters.
            if !task.isComplete,
               let dueLine = CountdownState.dueDateLine(
                    dueDate: task.dueDate,
                    specificTime: task.specificTime
               ) {
                Text(dueLine)
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(rowTreatment == .overdue ? NudgeTheme.overdue : NudgeTheme.textMuted)
            } else if !task.isComplete, !task.hasDeadline, let intended = task.intendedDate {
                // Intent day (cycle 2026-09-03-01): the day the user means
                // to do it — always muted, never a countdown, never coral or
                // overdue red. The day is information; urgency would be
                // fabrication.
                Text(intendedDayLabel(intended))
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            // One-tap "this is actually an event" correction.
            if !task.isComplete {
                Button(action: onConvertToEvent) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(width: 30, height: 30)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Convert to event")
            }

            if task.isComplete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(width: 30, height: 30)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // Stakes importance badge. Last element so it sits flush at the
            // trailing edge and aligns vertically down the list. Amber in
            // every row state — importance is constant; the row's time
            // colors move independently. Its text is folded into the title's
            // VoiceOver label, so it's hidden from the a11y tree here.
            if task.stakes == .high, !task.isComplete {
                HighStakesPill()
            }
        }
        .padding(16)
        .background(rowBackground)
        // Leading stakes/time bar. Added before the clip so its outer
        // corners round with the card; clear (absent) for calm + sitting.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(stakesBarColor ?? .clear)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .taskCompletionEffect(isComplete: $task.isComplete)
        .contentShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .onTapGesture(perform: onOpen)
    }

    // MARK: - Quantity count control (item 3, cycle 2026-08-03-01)

    /// Per-unit completion for a count task. Under four units: one small
    /// checkbox per unit, tap each (tap a filled one to step back). Four
    /// or more: one control with the running number, tap to increment.
    /// `target` is `effectiveTargetCount` — base plus capped carry — so
    /// the displayed number is always the capped one. `NudgeTheme` colors
    /// only; no new colors.
    @ViewBuilder
    private func countControl(target: Int) -> some View {
        let done = min(task.completedCount ?? 0, target)
        if target < 4 {
            HStack(spacing: 6) {
                ForEach(0..<target, id: \.self) { index in
                    Button {
                        setCount(index < done ? done - 1 : done + 1)
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(index < done ? NudgeTheme.primary : NudgeTheme.border, lineWidth: 2)
                                .fill(index < done ? NudgeTheme.primary : Color.clear)
                                .frame(width: 22, height: 22)

                            if index < done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(done) of \(target) done")
            .accessibilityHint("Tap to mark one more done")
        } else {
            Button {
                setCount(done + 1)
            } label: {
                Text("\(done)/\(target)")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 12))
                    .foregroundColor(done > 0 ? .white : NudgeTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(done > 0 ? NudgeTheme.primary : Color.clear)
                    .overlay(
                        Capsule().stroke(
                            done > 0 ? NudgeTheme.primary : NudgeTheme.border,
                            lineWidth: 2
                        )
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(done) of \(target) done")
            .accessibilityHint("Tap to mark one more done")
        }
    }

    /// The one write path for unit progress. Reaching the target funnels
    /// through `onToggleComplete` so a met count gets the full completion
    /// treatment (record, save, haptics, arbiter); anything short of it
    /// just persists the new count.
    private func setCount(_ newValue: Int) {
        guard let target = task.effectiveTargetCount else { return }
        let clamped = max(0, min(newValue, target))
        guard clamped != min(task.completedCount ?? 0, target) else { return }
        NudgeHaptics.light()
        task.completedCount = clamped
        if clamped >= target {
            onToggleComplete()
        } else {
            try? modelContext.save()
        }
    }

    /// "Today" / "Tomorrow" / weekday within a week / short date beyond —
    /// the intent-day label. A PAST intent day shows the day name plainly
    /// too ("Mon"): the slip is visible from the date itself, and coloring
    /// it would be the shame-free rule losing to the overdue idiom.
    private func intendedDayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: Date()),
            to: cal.startOfDay(for: day)
        ).day ?? 0
        let f = DateFormatter()
        f.dateFormat = (days > 0 && days < 7) ? "EEE" : "MMM d"
        return f.string(from: day)
    }

    /// Leading importance dot. Reads STAKES (not priority) so importance is
    /// one channel app-wide — same mapping as the session picker's dot.
    private var priorityColor: Color {
        switch task.stakes {
        case .high:
            return NudgeTheme.primary
        case .medium:
            return NudgeTheme.textMuted.opacity(0.6)
        case .low, .none:
            return NudgeTheme.textMuted
        }
    }

    // MARK: - Stakes row treatment (display only)
    //
    // First match wins. Time-pressure states (overdue, approaching) outrank
    // the calm high-stakes state. The amber "High" pill and the leading dot
    // are computed separately and do NOT depend on this — importance shows
    // regardless of which time state the row is in.

    private enum StakesRowTreatment: Equatable {
        case overdue                // stakes medium|high AND past deadline
        case approaching            // stakes high AND deadline within N days
        case highStakes             // stakes high, no time pressure
        case sitting(days: Int)     // stakes low, undated, aging
        case none
    }

    private var rowTreatment: StakesRowTreatment {
        // A finished task needs no flagging. Returning .none keeps completed
        // rows exactly as today — no bar, tint, weight bump, or subtitle
        // change — and (with the pill's own guard) no pill either.
        guard !task.isComplete else { return .none }

        let stakes = task.stakes
        // Overdue is a factual state, so everything past due reads
        // overdue-red EXCEPT deliberately low-stakes tasks, which we protect
        // from red. nil (unclassified) is not low, so it still shows overdue.
        if task.isOverdue, stakes != .low {
            return .overdue
        }
        if stakes == .high, isApproaching {
            return .approaching
        }
        if stakes == .high {
            return .highStakes
        }
        if stakes == .low,
           task.dueDate == nil, task.specificTime == nil,
           let days = daysSitting, days >= NudgeConfig.stakesSittingDays {
            return .sitting(days: days)
        }
        return .none
    }

    /// "Approaching" = deadline within `stakesApproachingDays` calendar days,
    /// measured off `sortDeadline`. Deliberately a plain day count and NOT
    /// the EisenhowerScorer urgency curve: that curve is a function of slack
    /// (hoursUntilDue − effortHoursRemaining), so a fixed urgency value maps
    /// to a different day count per task and can't express a clean "3 days."
    /// Keeping this off the curve also keeps the display fully independent of
    /// scoring — the entire reason stakes exists as its own signal.
    private var isApproaching: Bool {
        let deadline = task.sortDeadline
        guard deadline != .distantFuture else { return false }
        let now = CountdownClock.shared.now
        let window = Double(NudgeConfig.stakesApproachingDays) * 86_400
        return deadline > now && deadline <= now.addingTimeInterval(window)
    }

    private var daysSitting: Int? {
        Calendar.current.dateComponents(
            [.day], from: task.createdAt, to: CountdownClock.shared.now
        ).day
    }

    /// Card fill. The day-slot tint takes the fill when there is one: under
    /// Today the fill is a wayfinding channel — it says which block on the
    /// strip this row is — and that's a question the time-pressure tints
    /// can't answer. No urgency signal is lost, because `stakesBarColor`
    /// below still paints the leading bar overdue/coral; the tint was only
    /// ever its second copy. Everywhere else `slotTint` is nil and the two
    /// time-pressure states keep the fill exactly as before.
    private var rowBackground: Color {
        if let slotTint { return slotTint }
        switch rowTreatment {
        case .overdue:     return NudgeTheme.overdue.opacity(0.12)
        case .approaching: return NudgeTheme.coral.opacity(0.12)
        default:           return NudgeTheme.surface
        }
    }

    /// Leading edge bar. Amber for calm high-stakes; the time colors when
    /// the row is under time pressure; absent otherwise (sitting shows only
    /// its subtitle, no bar).
    private var stakesBarColor: Color? {
        switch rowTreatment {
        case .overdue:        return NudgeTheme.overdue
        case .approaching:    return NudgeTheme.coral
        case .highStakes:     return NudgeTheme.amber
        case .sitting, .none: return nil
        }
    }

    /// Title weight bumps only in the calm high-stakes state. Under time
    /// pressure the row color carries the signal and the title stays as-is;
    /// non-high rows keep today's weight exactly.
    private var titleFontName: String {
        StakesRowStyle.titleFontName(isHighStakes: rowTreatment == .highStakes)
    }

    /// Subtitle under the title. Generated-series rows get the day they
    /// belong to instead of a countdown (cycle 2026-08-03-02 item 2 —
    /// five "4 hours left / 28 hours left / 2 days" rows under one title
    /// read as five competing deadlines, not one commitment spread across
    /// a week); ordinary rows keep today's remaining-time line, recolored
    /// coral when approaching; the sitting state substitutes its amber
    /// line (undated, so it can never be a series row).
    private var subtitle: (text: String, color: Color)? {
        if !task.isComplete, isGeneratedSeriesTask, let due = task.dueDate {
            return seriesDayLabel(due: due, now: CountdownClock.shared.now)
        }
        if case .sitting(let days) = rowTreatment {
            return ("Sitting \(days) day\(days == 1 ? "" : "s")", NudgeTheme.amber)
        }
        if let dueDate = task.specificTime ?? task.dueDate,
           let remaining = CountdownState.remainingLine(
               dueDate: dueDate, now: CountdownClock.shared.now
           ) {
            let color = (rowTreatment == .approaching)
                ? NudgeTheme.coral : NudgeTheme.textSecondary
            return (remaining, color)
        }
        return nil
    }

    /// Whether this task belongs to a generated series — exam prep and
    /// commitment dailies share the generator, so one rule covers both.
    private var isGeneratedSeriesTask: Bool {
        task.source == "prep" || task.source == "commitment"
    }

    /// The series subtitle: which day this session belongs to. "Today's
    /// session"; a weekday name within a week ("Wednesday's session"); a
    /// date beyond that. A MISSED session keeps its day label in the
    /// overdue color rather than a countdown — "Monday's session" in red
    /// states which day slipped, where a growing "26 hours ago" counter
    /// is a shame ticker (`DESIGN.md`); the row's existing overdue
    /// treatment already carries the flag once.
    private func seriesDayLabel(due: Date, now: Date) -> (text: String, color: Color) {
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: due)
        ).day ?? 0

        func dateLabel() -> String {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return "Session on \(fmt.string(from: due))"
        }
        func weekdayLabel() -> String {
            "\(due.formatted(.dateTime.weekday(.wide)))'s session"
        }

        if days < 0 {
            // Beyond a week back a weekday name is ambiguous; use the date.
            return (days > -7 ? weekdayLabel() : dateLabel(), NudgeTheme.overdue)
        }
        if days == 0 {
            return ("Today's session", NudgeTheme.textSecondary)
        }
        if days < 7 {
            return (weekdayLabel(), NudgeTheme.textSecondary)
        }
        return (dateLabel(), NudgeTheme.textSecondary)
    }

    /// VoiceOver label for the title element. Adds stakes + state words on
    /// high-stakes and overdue rows (the two the spec calls out); other rows
    /// keep just the title, and the sitting subtitle is already spoken as
    /// its own text element.
    private var titleAccessibilityLabel: String {
        var parts = [task.title]
        if task.stakes == .high, !task.isComplete { parts.append("High stakes") }
        switch rowTreatment {
        case .overdue:     parts.append("overdue")
        case .approaching: parts.append("due soon")
        default:           break
        }
        return parts.joined(separator: ", ")
    }

    /// Picks the leading word for the CountdownLabel based on what the task
    /// actually is — "Exam Nov 15" reads better than "Due Nov 15" for a
    /// midterm. Falls back to "Due".
    private func countdownPrefix(for task: NudgeTask) -> String {
        let title = task.title.lowercased()
        if title.contains("exam") || title.contains("midterm") || title.contains("final") {
            return "Exam"
        }
        if title.contains("quiz") {
            return "Quiz"
        }
        if title.contains("presentation") {
            return "Presentation"
        }
        return "Due"
    }
}

struct EventRowView: View {
    let task: NudgeTask
    /// True when this event's normalized title appears
    /// `NudgeConfig.routineEventRepeatThreshold`+ times among the section's
    /// events — computed by the parent, since a row can't see its siblings.
    /// The repetition half of `isRoutine` below.
    var titleRepeatsAsRoutine: Bool = false
    /// Tap opens the editor (where the user can reschedule the date/time or
    /// delete). Defaulted so existing previews / call sites still compile.
    var onOpen: () -> Void = {}
    /// Quick trash button — events never "complete," so unlike tasks the
    /// delete affordance is always present on the row itself.
    var onDelete: () -> Void = {}
    /// Flips this event back into a task (isInformationalEvent = false) when
    /// the AI misclassified it. One-tap correction.
    var onConvertToTask: () -> Void = {}
    /// Called with a chosen clock time when the user fills in a missing start
    /// time via the "needs a time" chip.
    var onSetTime: (Date) -> Void = { _ in }

    @State private var showTimePicker = false
    @State private var pickedTime = Date()

    /// An event with no concrete start time needs one before reminders can
    /// fire — surfaced via the "needs a time" chip.
    private var needsTime: Bool { task.specificTime == nil }

    /// A timeless event may also be missing its day entirely. When so, the
    /// chip and picker cover BOTH date and time.
    private var needsDate: Bool { task.dueDate == nil }

    private var chipLabel: String {
        needsDate ? "needs a time and date" : "needs a time"
    }

    // MARK: - Stakes display (parity with TaskRowView)
    //
    // Events borrow only the two importance channels from the task row — the
    // amber "High" pill and the semibold title weight. The time-pressure
    // states (overdue / approaching / sitting) are deliberately absent: an
    // event isn't "completed" or "overdue," the user just shows up.

    /// High-stakes events get the pill + heavier title, exactly like tasks.
    private var isHighStakes: Bool { task.stakes == .high }

    /// "Routine" = a recurring fixture, not a notable commitment: the title
    /// repeats `routineEventRepeatThreshold`+ times (≈ weekly-or-denser within
    /// the 21-day window), stakes below high, already timed (so it isn't the
    /// attention-needing "needs a time" case), and not a work shift — the
    /// `.work` carve-out is insurance so repeated shifts keep full weight.
    /// Repetition was chosen over source-keyed dimming after a real-data
    /// comparison: it catches typed AND imported class meetings; source
    /// caught only imported ones. These render in a lighter title and quieter
    /// icon so exams and needs-a-time events carry the weight in each day.
    private var isRoutine: Bool {
        titleRepeatsAsRoutine
            && task.stakes != .high
            && !needsTime
            && task.taskCategory != .work
    }

    private var titleFontName: String {
        StakesRowStyle.titleFontName(isHighStakes: isHighStakes)
    }

    private var titleColor: Color {
        isRoutine ? NudgeTheme.textSecondary : NudgeTheme.textPrimary
    }

    private var iconColor: Color {
        isRoutine ? NudgeTheme.textMuted : NudgeTheme.primary
    }

    private var iconBackground: Color {
        isRoutine ? NudgeTheme.surfaceAlt : NudgeTheme.primary.opacity(0.12)
    }

    /// Folds "High stakes" into the title's VoiceOver label, mirroring
    /// TaskRowView so the hidden pill's meaning is still announced.
    private var titleAccessibilityLabel: String {
        isHighStakes ? "\(task.title), High stakes" : task.title
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: task.specificTime == nil ? "calendar" : "calendar.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(iconBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.custom(titleFontName, size: 15))
                    .foregroundColor(titleColor)
                    .accessibilityLabel(titleAccessibilityLabel)

                // Events use their own timing phrasing (Today / Tomorrow /
                // In N days, date / date) — NOT the task-style "hours left /
                // days away" countdown.
                if let eventLine = CountdownState.eventLine(
                    specificTime: task.specificTime,
                    dueDate: task.dueDate,
                    now: CountdownClock.shared.now
                ) {
                    Text(eventLine)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(NudgeTheme.textSecondary)
                }

                // "needs a time" chip — opens an inline time picker. Tapping
                // it must NOT also trigger the row's edit tap, so it lives in
                // its own button.
                if needsTime {
                    Button {
                        NudgeHaptics.light()
                        pickedTime = task.specificTime ?? task.dueDate ?? Date()
                        showTimePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text(chipLabel)
                                .font(.custom(NudgeTheme.fontMedium, size: 11))
                        }
                        .foregroundColor(NudgeTheme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(NudgeTheme.primary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // One-tap "this is actually a task" correction.
            Button(action: onConvertToTask) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
                    .frame(width: 30, height: 30)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Convert to task")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
                    .frame(width: 30, height: 30)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            // High-stakes importance pill — parity with task rows. Last in the
            // row so it sits flush at the trailing edge; hidden from a11y since
            // its text is folded into the title's VoiceOver label.
            if isHighStakes {
                HighStakesPill()
            }
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .onTapGesture(perform: onOpen)
        .sheet(isPresented: $showTimePicker) {
            NavigationStack {
                VStack(spacing: 20) {
                    DatePicker(
                        "Start",
                        selection: $pickedTime,
                        displayedComponents: needsDate ? [.date, .hourAndMinute] : [.hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                    Button {
                        NudgeHaptics.medium()
                        onSetTime(pickedTime)
                        showTimePicker = false
                    } label: {
                        Text("Set time")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NudgeTheme.primary)
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }

                    Spacer()
                }
                .padding(20)
                .background(NudgeTheme.background)
                .navigationTitle("When is \(task.title)?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showTimePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    /// Events use "Starts" (or "Class starts") instead of "Due" because
    /// they don't get "completed" — the user just shows up.
    private var eventPrefix: String {
        switch task.category {
        case "school": return "Class"
        case "work":   return "Work"
        default:       return "Starts"
        }
    }
}

// MARK: - Task Editor Sheet

struct TaskEditorSheet: View {
    enum Mode {
        case create
        case edit(task: NudgeTask)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mode: Mode
    let onSave: (TaskDraft) -> Void
    var onDelete: (() -> Void)? = nil
    /// When set (task is placed on today's timeline), shows a button to
    /// remove it from the timeline without deleting the task itself.
    var onRemoveFromTimeline: (() -> Void)? = nil

    @State private var draft = TaskDraft()
    /// A duration the timeline cannot fit without overlapping an anchored
    /// item (Roman, Sep 23 2026): the sheet says which one and the user
    /// decides. Nil means Save proceeds.
    @State private var durationConflict: TimelineReflow.AnchoredConflict?

    /// In edit mode, the AI-derived first step for this task so the
    /// under-3-hour CountdownLabel can suggest it. Pure READ — enrichment
    /// (if the cache is stale/missing) is kicked off separately from the
    /// editor's `.task` below, never as a side effect of this getter.
    private var suggestedFirstStep: String? {
        guard case .edit(let task) = mode else { return nil }
        let intel = NudgeIntelligence.shared.cachedIntelligence(
            for: task,
            modelContext: modelContext
        )
        return intel.suggestedFirstStep
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Task title", text: $draft.title, axis: .vertical)
                            .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                            .foregroundColor(NudgeTheme.textPrimary)

                        // Live countdown — the editor sheet is the only place
                        // where the "Want to start on this now?" suggestion
                        // appears (per spec rule 5). Tapping the suggestion
                        // dismisses the sheet so the user can hit Start Session.
                        // The AI's suggested first step shows underneath as
                        // a small subtitle to lower activation energy.
                        CountdownLabel(
                            dueDate: draft.specificTime ?? draft.dueDate,
                            prefix: countdownPrefix(forTitle: draft.title),
                            showsActionSuggestion: true,
                            suggestedFirstStep: suggestedFirstStep,
                            onStartNow: { dismiss() }
                        )

                        Text("Edit details, reschedule, or remove the task.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                    }

                    // Duration — how long the thing runs. This is the ONLY
                    // hand-editable route to an event's length (capture is
                    // the other writer), and the timeline draws an event one
                    // hour long without it. Chips cover the common lengths;
                    // a value between chips (AI-captured 45m, learned 100m)
                    // shows in the header so it isn't silently invisible.
                    editorSection(title: durationSectionTitle) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                durationChip(minutes: 30)
                                durationChip(minutes: 60)
                                durationChip(minutes: 90)
                            }
                            HStack(spacing: 10) {
                                durationChip(minutes: 120)
                                durationChip(minutes: 180)
                                durationChip(minutes: 240)
                            }
                        }
                    }

                    editorSection(title: "Importance") {
                        HStack(spacing: 10) {
                            stakesChip(title: "High", value: .high)
                            stakesChip(title: "Medium", value: .medium)
                            stakesChip(title: "Low", value: .low)
                        }
                    }

                    // Reschedule and due date come after duration and
                    // importance (Roman, Sep 23 2026: read the size and the
                    // weight first, then decide when).
                    if isEventMode {
                        // An event has one clock: when it is. Unchanged.
                        editorSection(title: "Reschedule") {
                            HStack(spacing: 10) {
                                quickDateChip(title: "Today", offset: 0)
                                quickDateChip(title: "Tomorrow", offset: 1)
                                quickDateChip(title: "Next Week", offset: 7)
                            }

                            HStack(spacing: 10) {
                                clearButton("No date") { draft.clearDueDate() }
                                Spacer()
                            }

                            DatePicker(
                                "Time",
                                selection: Binding(
                                    get: { draft.specificTime ?? draft.defaultDateForPicker },
                                    set: { draft.setSpecificTime($0) }
                                ),
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .datePickerStyle(.compact)
                        }
                    } else {
                        // A task has two clocks (Roman, Sep 16 2026):
                        // when you mean to work on it, and when it is owed.
                        scheduledSection
                        dueDateSection
                    }

                    if let onRemoveFromTimeline {
                        Button(action: {
                            onRemoveFromTimeline()
                            dismiss()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar.badge.minus")
                                Text("Remove from timeline")
                            }
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(NudgeTheme.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NudgeTheme.primary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onDelete {
                        Button(role: .destructive, action: {
                            onDelete()
                            dismiss()
                        }) {
                            Text("Delete task")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle(modeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        if let conflict = pendingDurationConflict() {
                            NudgeHaptics.light()
                            durationConflict = conflict
                            return
                        }
                        NudgeHaptics.medium()
                        onSave(draft.cleaned())
                        dismiss()
                    }
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                }
            }
            .alert(item: $durationConflict) { conflict in
                Alert(
                    title: Text("This runs into \(conflict.isEvent ? "an event" : "a task")"),
                    message: Text("\(conflict.title) is at \(conflict.timeLabel) and can't be moved. Saving keeps both where they are, overlapping."),
                    primaryButton: .default(Text("Save anyway")) {
                        NudgeHaptics.medium()
                        onSave(draft.cleaned())
                        dismiss()
                    },
                    secondaryButton: .cancel(Text("Go back"))
                )
            }
        }
        .onAppear(perform: populateDraftIfNeeded)
    }

    private var modeTitle: String {
        switch mode {
        case .create:
            return "New Task"
        case .edit:
            return "Task Details"
        }
    }

    /// Mirror of the helper on TaskRowView — picks the leading word for
    /// the live countdown based on the task title.
    private func countdownPrefix(forTitle title: String) -> String {
        let t = title.lowercased()
        if t.contains("exam") || t.contains("midterm") || t.contains("final") { return "Exam" }
        if t.contains("quiz") { return "Quiz" }
        if t.contains("presentation") { return "Presentation" }
        return "Due"
    }

    /// Editing an event: one picker, its time. Creating is always a task.
    private var isEventMode: Bool {
        if case .edit(let task) = mode { return task.isInformationalEvent }
        return false
    }

    /// The SCHEDULED clock: the day (and optionally the time) the user
    /// means to work on this, before it is owed. Writes the intention and
    /// a manual placement; never the due date.
    private var scheduledSection: some View {
        editorSection(title: "Reschedule") {
            HStack(spacing: 10) {
                quickDateChip(title: "Today", offset: 0)
                quickDateChip(title: "Tomorrow", offset: 1)
                quickDateChip(title: "Next Week", offset: 7)
            }

            DatePicker(
                "Day",
                selection: Binding(
                    get: { draft.intendedDate ?? Date() },
                    set: { draft.setScheduledDay($0) }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
            .opacity(draft.intendedDate == nil ? 0.55 : 1)

            if draft.intendedDate != nil {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: { draft.plannedStart ?? draft.defaultScheduledTime },
                        set: { draft.setScheduledTime($0) }
                    ),
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.compact)
                .opacity(draft.plannedStart == nil ? 0.55 : 1)
            }

            HStack(spacing: 10) {
                clearButton("No date") { draft.clearScheduled() }
                if draft.intendedDate != nil {
                    clearButton("No time") { draft.clearScheduledTime() }
                }
                Spacer()
            }

            Text(draft.intendedDate == nil
                 ? "No day picked: the app places it when it fits."
                 : (draft.plannedStart == nil
                    ? "That day, as a floater. Plan my day picks the time."
                    : "Anchored to the timeline at that time."))
                .font(.custom(NudgeTheme.fontBody, size: 12))
                .foregroundColor(NudgeTheme.textMuted)
        }
    }

    /// The DUE clock: the anchor. A due date is medium importance from the
    /// day it is set and high on the day it lands; a date with no time is
    /// due at 11:59 PM. Only a task with a due date can receive a plan.
    private var dueDateSection: some View {
        editorSection(title: "Due date") {
            DatePicker(
                "Due",
                selection: Binding(
                    get: { draft.dueDate ?? Date() },
                    set: { draft.setDueDay($0) }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
            .opacity(draft.dueDate == nil ? 0.55 : 1)

            if draft.dueDate != nil {
                DatePicker(
                    "Due time",
                    selection: Binding(
                        get: { draft.specificTime ?? draft.defaultDueTime },
                        set: { draft.setDueTime($0) }
                    ),
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.compact)
                .opacity(draft.specificTime == nil ? 0.55 : 1)
            }

            HStack(spacing: 10) {
                clearButton("No due date") { draft.clearDueDate() }
                if draft.dueDate != nil {
                    clearButton("No time") { draft.clearDueTime() }
                }
                Spacer()
            }

            Text(draft.dueDate == nil
                 ? "No due date: nothing is owed, so it never shows as overdue."
                 : (draft.specificTime == nil
                    ? "Due by 11:59 PM that day."
                    : "Due at that time. Overdue after it."))
                .font(.custom(NudgeTheme.fontBody, size: 12))
                .foregroundColor(NudgeTheme.textMuted)
        }
    }

    private func clearButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            NudgeHaptics.light()
            action()
        }) {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
    }

    private func quickDateChip(title: String, offset: Int) -> some View {
        Button(action: {
            NudgeHaptics.light()
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            if isEventMode { draft.setDate(date) } else { draft.setScheduledDay(date) }
        }) {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(NudgeTheme.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
    }

    /// "Duration" plus the current value when it isn't one of the chips —
    /// "Duration · 45 min" — so a captured or learned length is visible
    /// even though no chip lights up for it.
    private var durationSectionTitle: String {
        guard let mins = draft.durationMinutes,
              ![30, 60, 90, 120, 180, 240].contains(mins) else { return "Duration" }
        return "Duration · \(formatDuration(mins))"
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Duration selector chip. Tapping the selected chip clears the value
    /// (back to "unknown" — the timeline then uses its fallback), tapping
    /// another sets it. Either way it counts as a user pick, same rule as
    /// stakes: only a tap writes back on save.
    private func durationChip(minutes: Int) -> some View {
        let isSelected = draft.durationMinutes == minutes
        return Button(action: {
            NudgeHaptics.light()
            draft.durationMinutes = isSelected ? nil : minutes
            draft.durationUserPicked = true
        }) {
            Text(formatDuration(minutes))
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(isSelected ? .white : NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(isSelected ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
        .buttonStyle(.plain)
    }

    /// Stakes selector chip. Writes `draft.stakes` and flags the choice as
    /// user-made so the save path can set `stakesIsUserSet` (which makes
    /// `setStakesFromAutomation` a no-op on the row thereafter). Priority is
    /// no longer surfaced or edited here; it stays in the model untouched.
    private func stakesChip(title: String, value: TaskStakes) -> some View {
        let isSelected = draft.stakes == value
        return Button(action: {
            NudgeHaptics.light()
            draft.stakes = value
            draft.stakesUserPicked = true
        }) {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(isSelected ? .white : NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isSelected ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
    }

    private func editorSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                .foregroundColor(NudgeTheme.textPrimary)

            content()
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    /// The ONE application of an editor draft to a task — used by the Tasks
    /// tab AND the calendar view (cycle 2026-09-13-02), so a second call
    /// site can't drift from the first.
    ///
    /// INTENT-AWARE: for a task whose only day is an intent day, the date
    /// picker moves `intendedDate` (plus the placement when a clock time
    /// was chosen) and NEVER mints a deadline — sliding an airport pickup
    /// from Friday to Saturday on the calendar must not fabricate the time
    /// pressure the deadline/intent split removed. Events and deadline
    /// tasks keep deadline-field semantics; a task carrying BOTH edits its
    /// deadline (rare — capture never writes both). Floaters given a date
    /// here still receive a deadline: the editor's field says "Due", and
    /// re-deciding that default is the deferred convert-kind question.
    static func apply(_ draft: TaskDraft, to task: NudgeTask, modelContext: ModelContext) {
        task.title = draft.title
        task.priority = draft.priority

        if task.isInformationalEvent {
            // One clock: the event's time.
            task.dueDate = draft.dueDate
            task.dueTime = draft.dueTimeLabel
            task.specificTime = draft.specificTime
        } else {
            // Two clocks (Roman, Sep 16 2026). Each is written only when
            // the user touched it, so opening a row and saving can't
            // clobber an auto placement or a captured deadline.
            if draft.scheduleTouched {
                if let day = draft.intendedDate {
                    task.intendedDate = Calendar.current.startOfDay(for: day)
                    task.skipCount = 0
                    if let time = draft.plannedStart {
                        // A picked clock time is the user scheduling the
                        // start: a manual placement, same as a timed intent.
                        task.plannedStartDate = time
                        task.plannedIsAuto = false
                    } else {
                        task.plannedStartDate = nil
                        task.plannedIsAuto = false
                    }
                } else {
                    // "No date": released back to a floater.
                    task.intendedDate = nil
                    task.plannedStartDate = nil
                    task.plannedIsAuto = false
                }
            }
            if draft.dueTouched {
                task.dueDate = draft.dueDate
                task.dueTime = draft.dueTimeLabel
                task.specificTime = draft.specificTime
            }
            // A day you mean to work on it after the day it is owed is a
            // contradiction, and the scheduled clock is the one the user
            // just set, so the due clock follows it (Roman, Sep 25 2026:
            // an overdue task rescheduled to next week stayed overdue
            // because only the intention moved). Any task with both
            // clocks can hit this, not only overdue ones; the due time of
            // day is kept. A due day still ahead of the intention is
            // untouched.
            if draft.scheduleTouched, let intent = task.intendedDate, let due = task.dueDate {
                let cal = Calendar.current
                let intentDay = cal.startOfDay(for: intent)
                if intentDay > cal.startOfDay(for: due) {
                    if let time = task.specificTime {
                        let c = cal.dateComponents([.hour, .minute], from: time)
                        task.specificTime = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: intentDay)
                        task.dueDate = intentDay
                        task.dueTime = task.specificTime?.formatted(date: .omitted, time: .shortened)
                    } else {
                        task.dueDate = intentDay
                        task.dueTime = intentDay.formatted(date: .abbreviated, time: .omitted)
                    }
                }
            }
        }

        // Hand-set stakes: write directly + flag as user-set so no later
        // automation pass overwrites it. Only when a chip was tapped.
        if draft.stakesUserPicked, let picked = draft.stakes {
            task.stakes = picked
            task.stakesIsUserSet = true
        }
        // Duration: only a tapped chip writes. A hand-set EVENT length also
        // feeds the learned per-title stats — user correction is the ground
        // truth the learning tier exists for.
        if draft.durationUserPicked {
            task.estimatedMinutes = draft.durationMinutes
            if task.isInformationalEvent,
               let mins = draft.durationMinutes, mins > 0 {
                BusyWindowResolver.shared.recordDuration(
                    title: task.title,
                    durationMinutes: mins,
                    modelContext: modelContext
                )
            } else if !task.isInformationalEvent {
                // A placed task's block follows the chip (Roman, Sep 23
                // 2026): the timeline draws `plannedDurationMinutes`, which
                // the editor never wrote before, so a resize was invisible
                // on auto placements. The reflow pushes later auto
                // placements out of the way and never moves anchored ones.
                if let mins = draft.durationMinutes, mins > 0 {
                    TimelineReflow.durationChanged(task, to: mins, modelContext: modelContext)
                } else {
                    task.plannedDurationMinutes = nil
                }
            }
        }
    }


    /// The anchored item a picked duration would overlap, when the task
    /// is placed today and the reflow could not move its start earlier.
    private func pendingDurationConflict() -> TimelineReflow.AnchoredConflict? {
        guard case .edit(let task) = mode, !task.isInformationalEvent,
              draft.durationUserPicked, let mins = draft.durationMinutes, mins > 0,
              let start = task.plannedStartDate, Calendar.current.isDateInToday(start)
        else { return nil }
        return TimelineReflow.anchoredConflict(for: task, start: start, minutes: mins, pinStart: false, modelContext: modelContext)
    }

    private func populateDraftIfNeeded() {
        guard case .edit(let task) = mode else { return }
        draft = TaskDraft(
            title: task.title,
            priority: task.priority,
            dueDate: task.dueDate,
            specificTime: task.specificTime,
            durationMinutes: task.estimatedMinutes
        )
        // Tasks seed both clocks: the scheduled day + placement, and the
        // due date + time. `apply` writes each back only if touched.
        if !task.isInformationalEvent {
            draft.intendedDate = task.intendedDate
            draft.plannedStart = task.plannedStartDate
        }
        // Show the task's current stakes selected, WITHOUT marking it a fresh
        // user choice — only tapping a chip sets stakesUserPicked, so simply
        // opening + saving a row can't lock an automation-set value.
        draft.stakes = task.stakes
        // Explicit enrichment trigger. The `suggestedFirstStep` getter is
        // now a pure read (it used to kick off a refresh on cache miss);
        // opening the editor is the moment to (re)analyze so the suggestion
        // populates. refreshSoon is single-flight, so this is a no-op if a
        // refresh is already running or the cache is fresh enough that no
        // caller has invalidated it.
        NudgeIntelligence.shared.refreshSoon(for: task)
    }
}

// MARK: - Session Task Picker

struct SessionTaskPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let tasks: [NudgeTask]
    /// The Today-derived default (cycle 2026-08-04-01 item 2): the sheet
    /// opens on this one task with a Change button instead of the full
    /// list — fewer decisions at the moment of starting. Nil (Today empty,
    /// or the idle sheet's "pick something else") = full list straight
    /// away, the previous behaviour.
    let suggested: NudgeTask?
    let onPick: (NudgeTask) -> Void
    /// "Add your own" (Roman, Sep 25 2026): the typed line goes through the
    /// real capture path, so it becomes a task or an event by the same
    /// rules as a brain dump. A task starts the session at once; an event
    /// is added and the user picks a task to focus on.
    let onCreate: (String) async -> SessionCreateResult

    /// Flipped by the Change button — reveals the rest of the open tasks
    /// beneath the suggestion. Not persisted; every presentation starts
    /// collapsed.
    @State private var showAllTasks = false
    @State private var newSessionText = ""
    @State private var isCreating = false
    @State private var createNote: String?
    @FocusState private var newSessionFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tasks.isEmpty {
                        Text("What are you working on?")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                            .foregroundColor(NudgeTheme.textPrimary)
                            .padding(.bottom, 4)
                        VStack(spacing: 8) {
                            Text("No tasks to focus on")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                                .foregroundColor(NudgeTheme.textPrimary)
                            Text("Add a task first, then start a session.")
                                .font(.custom(NudgeTheme.fontBody, size: 13))
                                .foregroundColor(NudgeTheme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else if let suggested {
                        Text("Up next on Today")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                            .foregroundColor(NudgeTheme.textPrimary)
                            .padding(.bottom, 4)

                        Text("The session ends when you complete the task or stop the timer.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                            .padding(.bottom, 8)

                        suggestionCard(suggested)

                        if showAllTasks {
                            Text("Or pick something else")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                                .foregroundColor(NudgeTheme.textMuted)
                                .padding(.top, 8)
                            ForEach(tasks.filter { $0.id != suggested.id }, id: \.id) { task in
                                taskRow(task)
                            }
                        } else {
                            Button {
                                NudgeHaptics.light()
                                withAnimation(NudgeAnimation.standard) {
                                    showAllTasks = true
                                }
                            } label: {
                                Text("Change")
                                    .font(.custom(NudgeTheme.fontMedium, size: 14))
                                    .foregroundColor(NudgeTheme.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(NudgeTheme.surfaceAlt)
                                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("What are you working on?")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                            .foregroundColor(NudgeTheme.textPrimary)
                            .padding(.bottom, 4)

                        Text("Pick a task to focus on. The session ends when you complete it or stop the timer.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                            .padding(.bottom, 8)

                        ForEach(tasks, id: \.id) { task in
                            taskRow(task)
                        }
                    }

                    addYourOwn
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle("Start Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// One line in, one capture call, one session out. Shown under every
    /// branch, including the empty one, since "add a task first" was the
    /// friction this replaces.
    private var addYourOwn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or add your own")
                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
                .padding(.top, 12)
            HStack(spacing: 8) {
                TextField("What do you want to work on?", text: $newSessionText, axis: .vertical)
                    .font(.custom(NudgeTheme.fontBody, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .lineLimit(1...3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    .focused($newSessionFocused)
                    .submitLabel(.go)
                    .onSubmit { createAndStart() }
                    .disabled(isCreating)
                Button(action: createAndStart) {
                    Group {
                        if isCreating {
                            ProgressView().tint(.white)
                        } else {
                            Text("Start")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(width: 64, height: 44)
                    .background(newSessionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating
                                ? NudgeTheme.textPlaceholder : NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)
                .disabled(newSessionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
            if let createNote {
                Text(createNote)
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func createAndStart() {
        let text = newSessionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isCreating else { return }
        NudgeHaptics.medium()
        isCreating = true
        createNote = nil
        Task { @MainActor in
            let result = await onCreate(text)
            isCreating = false
            switch result {
            case .task(let task):
                newSessionText = ""
                onPick(task)
            case .event(let title):
                newSessionText = ""
                createNote = "Added \u{201C}\(title)\u{201D} as an event. Pick a task to focus on."
            case .nothing:
                createNote = "That didn\u{2019}t read as a task. Try saying what you\u{2019}ll do."
            case .failed:
                createNote = "That didn\u{2019}t go through, nothing was saved. Try again in a moment."
            }
        }
    }

    /// The single proposed task — same tap-to-start contract as the list
    /// rows, dressed in the timeline block's primary tint so "this is the
    /// plan" reads at a glance. The context line says WHY it's the one
    /// proposed (its timeline slot, or its place in the ordered plan).
    private func suggestionCard(_ task: NudgeTask) -> some View {
        Button {
            NudgeHaptics.medium()
            onPick(task)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 17))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Text(suggestionContext(task))
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                    Text(durationLabel(task))
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(NudgeTheme.primary)
            }
            .padding(18)
            .background(NudgeTheme.primary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.primary.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Why this task is the one proposed — the suggestion rule, stated to
    /// the user in its own terms.
    private func suggestionContext(_ task: NudgeTask) -> String {
        if let planned = task.plannedStartDate, Calendar.current.isDateInToday(planned) {
            return "On today's timeline at \(planned.formatted(date: .omitted, time: .shortened))"
        }
        if task.sequenceIndex != nil {
            return "Next in today's plan"
        }
        return "Next on your Today list"
    }

    private func taskRow(_ task: NudgeTask) -> some View {
        Button {
            NudgeHaptics.medium()
            onPick(task)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(priorityColor(task))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(durationLabel(task))
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NudgeTheme.primary)
            }
            .padding(16)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Leading importance dot — reads STAKES (not priority), matching
    /// TaskRowView so importance is one channel app-wide.
    private func priorityColor(_ task: NudgeTask) -> Color {
        switch task.stakes {
        case .high: return NudgeTheme.primary
        case .medium: return NudgeTheme.textMuted.opacity(0.6)
        case .low, .none: return NudgeTheme.textMuted
        }
    }

    private func durationLabel(_ task: NudgeTask) -> String {
        let minutes = task.estimatedMinutes ?? 60
        return "\(minutes) min session"
    }
}

// `WeeklyCompletedSheet` and the "Completed (N)" control were removed
// (cycle 2026-08-01-05): completed tasks are recorded and browsable in the
// Stats tab; the Tasks tab shows only what still needs doing.

// MARK: - Supporting Types

struct TaskDraft {
    var title = ""
    var priority = "medium"
    /// User-chosen stakes. Populated from the task on edit so the current
    /// value shows selected, but a save only writes it when the user
    /// actually tapped a chip (`stakesUserPicked`) — opening a row and
    /// saving without touching stakes must not lock an automation-set value.
    var stakes: TaskStakes? = nil
    var stakesUserPicked = false
    /// The DUE clock (the anchor). `dueDate` is the day; `specificTime` is
    /// the exact moment when a time was given; no time means 11:59 PM.
    var dueDate: Date? = nil
    var specificTime: Date? = nil
    /// The SCHEDULED clock (Roman, Sep 16 2026): the day the user means to
    /// work on it (`intendedDate`) and, when a time was picked, the manual
    /// placement (`plannedStartDate`).
    var intendedDate: Date? = nil
    var plannedStart: Date? = nil
    /// Which clocks the user touched in this sheet; `apply` writes only
    /// those, so open-and-save can't clobber an auto placement or a
    /// captured deadline.
    var scheduleTouched = false
    var dueTouched = false
    /// Length in minutes — `estimatedMinutes` on the task. Same pattern as
    /// stakes: populated on edit so the current value shows selected, but
    /// only written back when the user actually tapped a chip
    /// (`durationUserPicked`), so open-and-save can't overwrite an
    /// AI-captured length with a stale draft.
    var durationMinutes: Int? = nil
    var durationUserPicked = false

    var defaultDateForPicker: Date {
        specificTime ?? dueDate ?? Date()
    }

    var dueTimeLabel: String? {
        guard let dueDate else { return nil }
        if let specificTime {
            return specificTime.formatted(date: .omitted, time: .shortened)
        }
        return dueDate.formatted(date: .abbreviated, time: .omitted)
    }

    mutating func setDate(_ date: Date) {
        let startOfDay = Calendar.current.startOfDay(for: date)
        dueDate = startOfDay
        specificTime = nil
    }

    mutating func setSpecificTime(_ date: Date) {
        dueDate = Calendar.current.startOfDay(for: date)
        specificTime = date
    }

    mutating func clearDueDate() {
        dueDate = nil
        specificTime = nil
        dueTouched = true
    }

    // MARK: Due clock (tasks)

    var defaultDueTime: Date {
        let day = dueDate ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: day) ?? day
    }

    mutating func setDueDay(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        dueDate = day
        if let time = specificTime {
            // Keep the chosen clock time on the new day.
            let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
            specificTime = Calendar.current.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: day)
        }
        dueTouched = true
    }

    mutating func setDueTime(_ time: Date) {
        let day = dueDate ?? Calendar.current.startOfDay(for: time)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        dueDate = day
        specificTime = Calendar.current.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: day)
        dueTouched = true
    }

    mutating func clearDueTime() {
        specificTime = nil
        dueTouched = true
    }

    // MARK: Scheduled clock (tasks)

    var defaultScheduledTime: Date {
        let day = intendedDate ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }

    mutating func setScheduledDay(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        intendedDate = day
        if let start = plannedStart {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: start)
            plannedStart = Calendar.current.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: day)
        }
        scheduleTouched = true
    }

    mutating func setScheduledTime(_ time: Date) {
        let day = intendedDate ?? Calendar.current.startOfDay(for: time)
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        intendedDate = day
        plannedStart = Calendar.current.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: day)
        scheduleTouched = true
    }

    mutating func clearScheduledTime() {
        plannedStart = nil
        scheduleTouched = true
    }

    mutating func clearScheduled() {
        intendedDate = nil
        plannedStart = nil
        scheduleTouched = true
    }

    func cleaned() -> TaskDraft {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

enum TaskSheetDestination: Identifiable {
    case create
    case edit(taskID: UUID)
    /// Small window shown when a PLACED task's timeline block is tapped —
    /// holds the "Remove from timeline" button.
    case manageTimeline(taskID: UUID)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let taskID):
            return "edit-\(taskID.uuidString)"
        case .manageTimeline(let taskID):
            return "manage-\(taskID.uuidString)"
        }
    }
}

// `TaskSortComparator`, `sortDeadline`, and `isOverdue` moved to
// `Nudge/Models/NudgeTask.swift` (Jul 2026) — the widget was carrying its
// own private copies plus an inline plan-first sort, and every consumer
// hand-bolted the plan-first rule on top of the comparator. Plan-first is
// now built into the comparator itself.

// MARK: - Idle confirmation sheet

/// Shown when the user taps "Not yet" on the idle nudge. Surfaces ONE
/// pre-picked task so the user doesn't have to scan the list — the whole
/// point is to cut decision paralysis in half. They can confirm and start
/// a 10-minute session, or escape to the full picker.
struct IdleStartConfirmationSheet: View {
    let task: NudgeTask
    let onConfirm: () -> Void
    let onPickSomethingElse: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(NudgeTheme.border)
                .frame(width: 40, height: 4)
                .padding(.top, 8)

            VStack(spacing: 10) {
                Text("Let's start with")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)

                Text("\(task.title)")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("Just 10 minutes, that's it.")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            VStack(spacing: 10) {
                Button(action: {
                    NudgeHaptics.medium()
                    onConfirm()
                    dismiss()
                }) {
                    Text("Start")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(NudgeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)

                Button(action: {
                    NudgeHaptics.light()
                    onPickSomethingElse()
                    dismiss()
                }) {
                    Text("Pick something else")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NudgeTheme.background)
    }
}

extension NudgeTask {
    var subtitle: String {
        var parts: [String] = []

        if let dueLabel {
            parts.append(dueLabel)
        } else {
            parts.append("No due date")
        }

        parts.append(priority.capitalized)
        return parts.joined(separator: " • ")
    }

    var dueLabel: String? {
        if let specificTime {
            return specificTime.formatted(date: .abbreviated, time: .shortened)
        }

        if let dueDate {
            return dueDate.formatted(date: .abbreviated, time: .omitted)
        }

        return nil
    }

}

/// A session start held for the user's decision because it would overlap
/// an anchored item on the timeline.
struct SessionStartConflict: Identifiable {
    let id = UUID()
    let task: NudgeTask
    let conflict: TimelineReflow.AnchoredConflict
}

/// What "add your own" from the session picker produced.
enum SessionCreateResult {
    case task(NudgeTask)
    case event(title: String)
    case nothing
    case failed
}
