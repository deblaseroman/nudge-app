//
//  NudgeTask.swift
//  Nudge
//
//  Core task model. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

// MARK: - Event duration resolution
//
// THE one implementation of "how long does this event run?". Until Jul
// 2026 there were four: `BusyWindowResolver.resolveDurationMinutes` (the
// canonical one), a hand-maintained mirror in `TodayTimelineView`, and two
// TRUNCATED copies (`DayPlanRefiner`, the widget chart) that skipped the
// learned `EventDurationStats` row — so a three-hour lab with no explicit
// estimate read as 60 minutes to the AI planner and the widget chart while
// the busy gate correctly saw three hours.
//
// It lives HERE, not in a service, because the widget target compiles
// `Nudge/Models/*.swift` and nothing else — a service method couldn't be
// shared, and a NEW model file would need a hand edit to the widget's
// `membershipExceptions` list in project.pbxproj.
extension NudgeTask {
    /// Fallback when nothing explicit or learned exists. This is the
    /// single source of truth — `NudgeConfig.defaultEventDurationMinutes`
    /// forwards to it (NudgeConfig is invisible to the widget target, so
    /// the value itself must live in the model layer). Tune it here.
    static let fallbackEventDurationMinutes: Int = 60

    /// Resolved duration in minutes for an informational event:
    /// explicit `estimatedMinutes` (written by the calendar / screenshot
    /// import from the event's real end time) → learned per-title
    /// `EventDurationStats` row → the shared fallback.
    func eventDurationMinutes(modelContext: ModelContext) -> Int {
        if let explicit = estimatedMinutes, explicit > 0 { return explicit }
        let key = EventDurationStats.normalize(title)
        var descriptor = FetchDescriptor<EventDurationStats>(
            predicate: #Predicate<EventDurationStats> { $0.titleKey == key }
        )
        descriptor.fetchLimit = 1
        if let learned = (try? modelContext.fetch(descriptor))?.first {
            return learned.durationMinutes
        }
        return Self.fallbackEventDurationMinutes
    }

    /// Same resolution against an already-fetched stats array — for hot
    /// paths that hold a bounded `@Query` (the timeline re-reads on every
    /// 60s tick) and must not fetch per event per render.
    func eventDurationMinutes(in stats: [EventDurationStats]) -> Int {
        if let explicit = estimatedMinutes, explicit > 0 { return explicit }
        let key = EventDurationStats.normalize(title)
        if let learned = stats.first(where: { $0.titleKey == key }) {
            return learned.durationMinutes
        }
        return Self.fallbackEventDurationMinutes
    }
}

// MARK: - Display / pick ordering
//
// Shared by every "what order do tasks go in?" and "what should I start?"
// site in BOTH targets — the app list, the session pickers, the idle
// builder's target choice, the notification-tap target, and the widget
// rows. Lives here (Models) for the same reason `eventDurationMinutes`
// does: the widget compiles Models only.

extension NudgeTask {
    /// The instant used for deadline ordering: the explicit clock time
    /// when one exists, else the END of the due day (a bare due date means
    /// "by end of that day" — capture normalizes it to 23:59 for exactly
    /// this reason), else `.distantFuture` for floaters.
    var sortDeadline: Date {
        if let specificTime {
            return specificTime
        }
        if let dueDate {
            let start = Calendar.current.startOfDay(for: dueDate)
            return Calendar.current.date(byAdding: .day, value: 1, to: start) ?? dueDate
        }
        return .distantFuture
    }

    var isOverdue: Bool {
        guard !isComplete else { return false }
        return sortDeadline < Date()
    }

    // MARK: - The day model (cycle 2026-09-30-01)
    //
    // Two facts per task, everything else derived:
    //   • the ANCHOR — when it is owed (`dueDate` / `specificTime`); for an
    //     event, when it happens (`specificTime`). Optional on tasks.
    //   • the PLAN — the day the user will work on it (`intendedDate`, read
    //     as `planDay`) and optionally the time (`plannedStartDate`,
    //     `plannedDurationMinutes`, `plannedIsAuto`).
    // Invariants: I1 a day without a time is legal, a time without a day is
    // not; I2 events never carry a plan; I3 a plan is today-or-later at all
    // times (the rollover moves or clears anything earlier).
    // Rules, all of which live HERE because the widget compiles Models only:
    //   R1 a task belongs to day D if its plan day is D or its anchor day
    //      is D; an event belongs to its anchor day only.
    //   R2 overdue = an open task whose anchor passed. No stakes filter.
    //   R3 unscheduled = an open task with no plan day that is not on
    //      today's list. Overlap with Overdue is allowed; hiding is not.
    //   R4 kind is decided once at capture; no downstream rule branches on
    //      it silently.
    //   R5 the planner is the only automatic writer of plans; user writes
    //      are manual; capture and import write the stated day.

    /// The day the anchor falls on: an event's start, else a task's due day.
    var anchorDay: Date? {
        if let specificTime { return Calendar.current.startOfDay(for: specificTime) }
        if let dueDate { return Calendar.current.startOfDay(for: dueDate) }
        return nil
    }

    /// The day this task is planned for — `intendedDate` at day granularity.
    var planDay: Date? {
        intendedDate.map { Calendar.current.startOfDay(for: $0) }
    }

    /// Days this task sat on a plan day and was not finished, counted by the
    /// rollover. A row label and the one-retry rule read it; nothing hides
    /// on it (R3).
    var slipCount: Int { skipCount }

    /// Whether the rollover counts a slip for this row: any open task except
    /// the generated rows with their own rules (`prep` sessions are counted
    /// as missed and removed; `commitment` dailies carry over).
    var countsSlips: Bool {
        !isInformationalEvent && source != "prep" && source != "commitment"
    }

    /// R1.
    func belongs(to day: Date) -> Bool {
        let cal = Calendar.current
        if isInformationalEvent {
            return anchorDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
        }
        if let p = planDay, cal.isDate(p, inSameDayAs: day) { return true }
        if let a = anchorDay, cal.isDate(a, inSameDayAs: day) { return true }
        return false
    }

    /// R3: open, no plan day, and not on today's list (a task owed today
    /// belongs to today by R1 and is not "unscheduled" in any useful
    /// sense). May overlap Overdue; never hides.
    var isUnscheduled: Bool {
        !isInformationalEvent && !isComplete && planDay == nil
            && !belongs(to: Calendar.current.startOfDay(for: Date()))
    }

    /// The Tasks tab's lists. `today` is the day lens for the reference day.
    enum TaskList: String, Hashable, Comparable {
        case today, unscheduled, overdue
        static func < (lhs: TaskList, rhs: TaskList) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// THE membership function: which lists this row appears in on `today`.
    /// The Tasks tab, the widget, the calendar and the eval harness read
    /// this and nothing else; a row is never in zero lists while open unless
    /// it belongs to another day (then it is in that day's lens).
    func lists(on today: Date, now: Date = Date()) -> Set<TaskList> {
        var out = Set<TaskList>()
        guard !isInformationalEvent else { return out }
        if belongs(to: today) { out.insert(.today) }
        guard !isComplete else { return out }
        if planDay == nil, !out.contains(.today) { out.insert(.unscheduled) }
        if sortDeadline < now { out.insert(.overdue) }
        return out
    }

    // MARK: Plan writers (I1, I2) — the only way to write a plan.

    /// Plans the task for a day with no time. A placement on another day is
    /// released; one on the same day is kept.
    func setPlanDay(_ day: Date) {
        assert(!isInformationalEvent, "events never carry a plan (I2)")
        guard !isInformationalEvent else { return }
        let cal = Calendar.current
        intendedDate = cal.startOfDay(for: day)
        planDayIsAuto = false
        if let p = plannedStartDate, !cal.isDate(p, inSameDayAs: day) {
            clearPlanTime()
        }
    }

    /// Places the task at a start time; the plan day follows the time.
    /// `auto` marks a planner placement (the undo and the reflow treat it
    /// as movable); a user's own time is anchored.
    func setPlanStart(_ start: Date, durationMinutes: Int? = nil, auto: Bool) {
        assert(!isInformationalEvent, "events never carry a plan (I2)")
        guard !isInformationalEvent else { return }
        let cal = Calendar.current
        let day = cal.startOfDay(for: start)
        if intendedDate.map({ !cal.isDate($0, inSameDayAs: day) }) ?? true {
            // The day is new: it came from whoever is placing.
            planDayIsAuto = auto
        }
        intendedDate = day
        plannedStartDate = start
        if let durationMinutes { plannedDurationMinutes = durationMinutes }
        plannedIsAuto = auto
    }

    /// Drops the time, keeps the day.
    func clearPlanTime() {
        plannedStartDate = nil
        plannedDurationMinutes = nil
        plannedIsAuto = false
    }

    /// Drops the day and the time: the task is unscheduled again.
    func clearPlan() {
        clearPlanTime()
        intendedDate = nil
        planDayIsAuto = false
    }

    /// A planner taking back what it wrote: the time always, the day only
    /// when the planner set it. A user's day survives.
    func releaseAutoPlan() {
        clearPlanTime()
        if planDayIsAuto {
            intendedDate = nil
            planDayIsAuto = false
        }
    }

    /// The rollover's one-retry threshold (Roman, Sep 16 2026): a task
    /// whose plan day slips is re-planned for today once; at this count it
    /// is released to Unscheduled with its slip count showing. Lives on the
    /// model because the widget compiles this file without `NudgeConfig`
    /// (which forwards here).
    static let skipsBeforeSkippedSection: Int = 2

    /// True when this task is actually OWED at a moment — the deadline half
    /// of the deadline-vs-intention split (cycle 2026-09-03-01). Read sites
    /// that mean "does time pressure exist here" should ask this, not
    /// re-derive it from the fields, so the split stays one rule.
    var hasDeadline: Bool {
        dueDate != nil || specificTime != nil
    }

    /// The DAY-INTEGRITY invariant, task half (cycle 2026-09-13-01): a task
    /// glued to a day still ahead is invisible to every "what should I do
    /// NOW" path — planner candidates, morning naming, idle targeting,
    /// session suggestions — until that day arrives. The user already chose
    /// the day; those paths honor decisions, they don't re-make them.
    /// Deadline tasks are deliberately NOT glued: working ahead of a due
    /// date is the point of planning. A PAST intent day returns false — a
    /// slipped intention is fair game again. Ask this helper, never
    /// re-derive; one rule, every site.
    func intentIsFuture(asOf reference: Date = Date()) -> Bool {
        guard let intendedDate else { return false }
        return intendedDate > Calendar.current.startOfDay(for: reference)
    }

    /// Alias of `planDay`, kept for the eval observable and older call
    /// sites. Membership itself is `belongs(to:)` (R1), never this alone.
    var scheduledDay: Date? { planDay }

    // MARK: - The day lens (one rule, two readers)

    /// The ordered plan section of a day: plan tasks (`sequenceIndex`) that
    /// belong to `day` (capture gives a dateless plan item today's plan
    /// day, so no read-side exception remains); open first, in stated
    /// order. Hoisted here Sep 23 2026 so the widget shows exactly the
    /// Tasks tab's Today lens (it had its own all-tasks list and showed
    /// tomorrow's rows over today's).
    static func planTasks(among tasks: [NudgeTask], on day: Date, now: Date = Date()) -> [NudgeTask] {
        return tasks
            .filter { !$0.isInformationalEvent && $0.sequenceIndex != nil && $0.belongs(to: day) }
            .sorted { lhs, rhs in
                if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
                return (lhs.sequenceIndex ?? .max) < (rhs.sequenceIndex ?? .max)
            }
    }

    /// Non-plan tasks belonging to `day` (R1: plan day or anchor day).
    /// Open rows in start-time order so the list reads like the timeline;
    /// unplaced rows follow; completed rows sink.
    static func dayTasks(among tasks: [NudgeTask], on day: Date) -> [NudgeTask] {
        return tasks
            .filter { task in
                !task.isInformationalEvent && task.sequenceIndex == nil && task.belongs(to: day)
            }
            .sorted { lhs, rhs in
                if lhs.isComplete != rhs.isComplete { return !lhs.isComplete }
                let l = lhs.plannedStartDate ?? .distantFuture
                let r = rhs.plannedStartDate ?? .distantFuture
                if l != r { return l < r }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// The whole lens for a day: the plan section, then the day's tasks.
    static func dayLens(among tasks: [NudgeTask], on day: Date, now: Date = Date()) -> [NudgeTask] {
        planTasks(among: tasks, on: day, now: now) + dayTasks(among: tasks, on: day)
    }

    /// The one task to recommend when the user says they have not started:
    /// open, not an event, not glued to a future day, ranked by the shared
    /// comparator (plan-first, then deadline buckets). One rule for the
    /// check-in's "Not yet" action and the message box's recommendation.
    static func topOpenTask(among tasks: [NudgeTask], now: Date = Date()) -> NudgeTask? {
        let open = tasks.filter { !$0.isInformationalEvent && !$0.isComplete && !$0.intentIsFuture(asOf: now) }
        let comparator = TaskSortComparator()
        return open.min { comparator.compare($0, $1) }
    }
}

/// The one task ordering, with **plan-first built in** (Jul 2026 — before
/// this, every site that consumed the comparator hand-bolted the "ordered
/// plan outranks score" rule on top of it, or forgot to). Buckets:
///
///   0. plan tasks (`sequenceIndex != nil`), in stated order — the user's
///      declared sequence outranks every deadline heuristic below
///      (Cross-cutting invariant 1 in ARCHITECTURE.md)
///   1. overdue, oldest deadline first
///   2. dated, soonest deadline first
///   3. floaters, oldest created first
///   4. completed, newest completion first
///
/// Callers that must EXCLUDE plan tasks (the app's Unscheduled/Scheduled
/// sections render them in their own numbered section) filter
/// `sequenceIndex == nil` before sorting, same as before.
struct TaskSortComparator {
    func compare(_ lhs: NudgeTask, _ rhs: NudgeTask) -> Bool {
        let leftBucket = sortBucket(for: lhs)
        let rightBucket = sortBucket(for: rhs)

        if leftBucket != rightBucket {
            return leftBucket < rightBucket
        }

        switch leftBucket {
        case 0:
            if let l = lhs.sequenceIndex, let r = rhs.sequenceIndex, l != r {
                return l < r
            }
            return lhs.sortDeadline < rhs.sortDeadline
        case 1, 2:
            return lhs.sortDeadline < rhs.sortDeadline
        case 3:
            return lhs.createdAt < rhs.createdAt
        default:
            return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
    }

    private func sortBucket(for task: NudgeTask) -> Int {
        if task.isComplete {
            return 4
        }
        if task.sequenceIndex != nil {
            return 0
        }
        if task.isOverdue {
            return 1
        }
        if task.sortDeadline != .distantFuture {
            return 2
        }
        return 3
    }
}

@Model
final class NudgeTask {
    var id: UUID
    var title: String
    var dueDate: Date?
    var dueTime: String?            // "morning" | "afternoon" | "evening" | "specific"
    var specificTime: Date?
    var priority: String            // "high" | "medium" | "low"
    var category: String?           // "school" | "health" | "personal" | "work"
    var isComplete: Bool
    var completedAt: Date?
    var nudgeInsight: String?       // cached once, never regenerated
    var insightGeneratedAt: Date?
    var createdAt: Date
    var source: String              // "manual" | "capture" | "calendar" | "screenshot"
    var estimatedMinutes: Int?      // AI-estimated duration for time blocking
    var recurrence: String?         // "daily" | "weekly" | "monthly" — nil means one-off
    var linkedEventId: String?      // links to a calendar event that spawned this task
    var dependsOnTaskId: UUID?      // optional dependency — this task blocked by another
    var isInformationalEvent: Bool

    /// Where the user has PLACED this task on today's horizontal timeline.
    /// Independent of `dueDate`/`specificTime` (which represent the deadline
    /// and must not change when a task is placed). Nil = unscheduled.
    var plannedStartDate: Date?
    /// How long the placed block should span on the timeline, in minutes.
    /// Nil falls back to `estimatedMinutes`, then a default.
    var plannedDurationMinutes: Int?
    /// True when the placement was created by "Plan my day" (auto), false
    /// when the user placed it manually. Lets "Clear plan" remove only the
    /// auto placements and keep manual ones.
    var plannedIsAuto: Bool = false

    /// Position (1-based) in an ordered "Today's plan" captured from the
    /// brain dump ("first X, then Y…"). Nil means the task is NOT part of an
    /// ordered plan. Independent of the timeline — a plan is a numbered,
    /// reorderable list, not a placement.
    var sequenceIndex: Int?

    /// The PLAN DAY (read as `planDay`; column name kept — never rename
    /// existing fields): the day this task is currently planned for, today
    /// or later (I3). Introduced as an "intent day" in cycle 2026-09-03-01
    /// so a stated day would never be mistaken for a deadline; since cycle
    /// 2026-09-30-01 it is the plan's day, written only through the plan
    /// helpers, and a day that passes is re-planned or released by the
    /// rollover instead of surviving as history (`skipCount` keeps the
    /// history). Never set on informational events; an event's time is
    /// its time.
    var intendedDate: Date? = nil

    /// How many days this task sat on a plan day and was not finished
    /// (Roman, Sep 16 2026), counted by `PlacementRollover` for every open
    /// task except generated rows; reset to 0 whenever the user places or
    /// dates the task again. Read as `slipCount`. A row label and the
    /// one-retry rule use it; nothing hides on it (R3).
    var skipCount: Int = 0

    /// True while the plan day was written by a planner rather than the
    /// user, capture or import — so releasing an automatic placement
    /// (replan, displacement, Clear plan) can take the day back too, and
    /// a day the user chose survives the same release. Additive,
    /// property-level default; no migration.
    var planDayIsAuto: Bool = false

    /// DEPRECATED tombstone column (Sep 2026). Held the exam study-lead
    /// band (3, 7, or 14) the old silent exam sweep read; the plan reader
    /// decides sessions itself now and nothing reads or writes this. Kept
    /// so existing stores open without a migration.
    var prepLeadDays: Int? = nil

    /// Canonical consequence signal — raw storage for `TaskStakes`
    /// ("high" | "medium" | "low"). Nil = never classified, which is what
    /// a later backfill pass keys on. Read through `stakes`; unknown
    /// strings read as nil, never crash. Deliberately NOT part of the
    /// memberwise init: every automated writer must go through
    /// `setStakesFromAutomation` so the user-override guard below cannot
    /// be bypassed.
    var stakesRaw: String? = nil
    /// True once the user has set stakes by hand (manual editor — not
    /// built yet). While set, `setStakesFromAutomation` is a no-op, so no
    /// AI or import pass can clobber the user's choice. Only user-driven
    /// UI may write `stakes` directly, and it must set this flag too.
    var stakesIsUserSet: Bool = false

    /// Commitment shape detected at capture — raw storage for
    /// `CommitmentShape` ("splitwork" | "rate" | "quantity"), set on the
    /// PARENT task a brain dump like "an hour a day until Friday"
    /// produces (cycle 2026-08-03-01). Non-nil marks the task as a
    /// commitment awaiting expansion: once its numbers are known
    /// (`estimatedMinutes` = total effort for splitWork / per-day
    /// duration for rate; `dueDate` = the end; `commitmentDailyCount`
    /// for quantity), `ExamPrepSweep` converts it into a
    /// `NudgeCommitment` row plus daily `source == "commitment"` tasks
    /// and deletes this parent. Nil = an ordinary task; additive,
    /// property-level default, so existing stores open unchanged.
    var commitmentShapeRaw: String? = nil
    /// Quantity shape only: units per day ("three applications a day"
    /// → 3), carried until expansion stamps it onto
    /// `NudgeCommitment.dailyCount`. Inert on every other task.
    var commitmentDailyCount: Int? = nil
    /// The AI's second name from capture: a SHORT session name for the
    /// generated dailies ("Python course"), while this task's own
    /// `title` keeps the goal phrasing with the dump's specific scope
    /// ("Complete module 4 of Python course" — the known-sizes memory
    /// matches on that string). Carried onto
    /// `NudgeCommitment.sessionTitle` at expansion; nil (legacy
    /// captures, AI omission) means dailies fall back to the goal name.
    /// Inert on every non-commitment task.
    var commitmentSessionTitle: String? = nil
    /// The personal goal this task serves (`NudgeGoal.id`), linked
    /// conservatively at capture — the AI matches against the user's
    /// active goals riding the one capture call, and when in doubt leaves
    /// it nil (a wrong link corrupts the goal's activity record; a missed
    /// one just means an elapsed-time nudge fires slightly early). Soft
    /// reference: a removed goal leaves this dangling and every reader
    /// treats that as unlinked. Additive, property-level default.
    var goalID: UUID? = nil
    /// The chosen/derived first day of the commitment (start-of-day).
    /// Set by the user's "today or tomorrow" answer, or by the app when
    /// only one answer is possible (captured at 10pm → tomorrow). Nil =
    /// undecided; expansion falls back to a viability default. (Cycle
    /// 2026-08-03-02 item 3.)
    var commitmentStartDate: Date? = nil
    /// When the app asked "start today or tomorrow?" in chat. While this
    /// is TODAY and `commitmentStartDate` is nil the question is
    /// outstanding and expansion waits; a stale ask (yesterday's) expires
    /// and expansion proceeds on the default — the question was about a
    /// day that no longer exists.
    var commitmentStartAskedAt: Date? = nil

    /// Quantity-per-day fields (cycle 2026-08-03-01, item 3). "Three
    /// applications a day" is ONE task with a count, not three tasks —
    /// the model has no notion of partial completion, so the count
    /// carries it. All nil on a normal task; additive, property-level
    /// defaults.
    ///
    /// The day's base target in units. Set by the commitment sweep on
    /// quantity dailies (from `NudgeCommitment.dailyCount`).
    var targetCount: Int? = nil
    /// Units done so far today. Nil reads as 0. The task completes only
    /// when this reaches `effectiveTargetCount`.
    var completedCount: Int? = nil
    /// Capped carry from missed prior days, stamped onto TODAY's task by
    /// the sweep (the durable accumulator is `NudgeCommitment.carryUnits`;
    /// this is its display copy, so the number the row shows is always
    /// the capped one). Never exceeds
    /// `commitmentCarryCapDays × targetCount`.
    var carriedCount: Int? = nil

    /// Coarse "when is this task appropriate" band — raw storage for
    /// `TaskTimeWindow` ("anytime" | "daytime" | "businesshours"),
    /// assigned by the capture classification (cycle 2026-08-02-03).
    /// Nil = never classified → the planner falls back to the
    /// deterministic inference via `effectiveTimeWindow`. Additive,
    /// property-level default: existing stores open unchanged and their
    /// rows behave exactly as before (inference default is `.anytime`).
    var timeWindowRaw: String? = nil

    init(
        id: UUID = UUID(),
        title: String,
        dueDate: Date? = nil,
        dueTime: String? = nil,
        specificTime: Date? = nil,
        priority: String = "medium",
        category: String? = nil,
        isComplete: Bool = false,
        completedAt: Date? = nil,
        nudgeInsight: String? = nil,
        insightGeneratedAt: Date? = nil,
        createdAt: Date = Date(),
        source: String = "manual",
        estimatedMinutes: Int? = nil,
        recurrence: String? = nil,
        linkedEventId: String? = nil,
        dependsOnTaskId: UUID? = nil,
        isInformationalEvent: Bool = false,
        plannedStartDate: Date? = nil,
        plannedDurationMinutes: Int? = nil,
        plannedIsAuto: Bool = false,
        sequenceIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.specificTime = specificTime
        self.priority = priority
        self.category = category
        self.isComplete = isComplete
        self.completedAt = completedAt
        self.nudgeInsight = nudgeInsight
        self.insightGeneratedAt = insightGeneratedAt
        self.createdAt = createdAt
        self.source = source
        self.estimatedMinutes = estimatedMinutes
        self.recurrence = recurrence
        self.linkedEventId = linkedEventId
        self.dependsOnTaskId = dependsOnTaskId
        self.isInformationalEvent = isInformationalEvent
        self.plannedStartDate = plannedStartDate
        self.plannedDurationMinutes = plannedDurationMinutes
        self.plannedIsAuto = plannedIsAuto
        self.sequenceIndex = sequenceIndex
    }

    /// Typed view of `category` for scoring code. Reads the underlying
    /// free-text string, lowercases it, and maps via `TaskCategory.rawValue`.
    /// Unknown strings → `.other`. `nil` category → `nil`.
    ///
    /// Writes round-trip back to the underlying String storage so existing
    /// SwiftData rows continue to behave as-is. Use this accessor whenever
    /// downstream code needs to switch on category — `category` itself stays
    /// as the canonical write field for compatibility with older call sites.
    var taskCategory: TaskCategory? {
        get {
            guard let key = category?.lowercased(), !key.isEmpty else { return nil }
            return TaskCategory(rawValue: key) ?? .other
        }
        set { category = newValue?.rawValue }
    }

    /// Typed view of `stakesRaw`. Unknown or empty strings → nil (unlike
    /// `taskCategory`, there is no catch-all case — nil means "never
    /// classified" and later passes rely on that). The setter is for
    /// user-driven editors only; automated writers use
    /// `setStakesFromAutomation`.
    var stakes: TaskStakes? {
        get { TaskStakes.parse(stakesRaw) }
        set { stakesRaw = newValue?.rawValue }
    }

    /// The single write path for every NON-USER stakes writer — the
    /// brain-dump classifier, the screenshot import, the deterministic
    /// calendar-import fallback, and any future backfill/upgrade pass.
    /// Refuses to overwrite a hand-set value (`stakesIsUserSet`), and
    /// treats nil as "the classifier didn't say" (keeps the current
    /// value) rather than a clear.
    func setStakesFromAutomation(_ newValue: TaskStakes?) {
        guard !stakesIsUserSet else { return }
        guard let newValue else { return }
        stakesRaw = newValue.rawValue
    }

    /// The number the row displays and completion requires: the base
    /// target plus the (already-capped) carry. Nil for non-count tasks.
    var effectiveTargetCount: Int? {
        guard let targetCount else { return nil }
        return targetCount + (carriedCount ?? 0)
    }

    /// Typed view of `commitmentShapeRaw`. Unknown or empty strings → nil
    /// (an unrecognized shape from a drifting AI response reads as "not a
    /// commitment", the safe default — the task stays an ordinary task).
    var commitmentShape: CommitmentShape? {
        get { CommitmentShape.parse(commitmentShapeRaw) }
        set { commitmentShapeRaw = newValue?.rawValue }
    }

    /// Typed view of `timeWindowRaw`. Unknown or empty strings → nil.
    var timeWindow: TaskTimeWindow? {
        get { TaskTimeWindow.parse(timeWindowRaw) }
        set { timeWindowRaw = newValue?.rawValue }
    }

    /// The band the planner actually uses: the classification when one
    /// exists, else the deterministic keyword inference (whose own default
    /// is `.anytime`). Resolved at READ time rather than stamped into the
    /// store — the stored value stays exclusively "what the classifier
    /// said", so a later, better classification pass can tell classified
    /// rows from fallback rows.
    var effectiveTimeWindow: TaskTimeWindow {
        timeWindow ?? TaskTimeWindow.infer(title: title, category: taskCategory)
    }
}
