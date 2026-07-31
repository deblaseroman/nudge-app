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

    /// How many days ahead of this EXAM EVENT study tasks should start —
    /// the coarse prep-lead band (3, 7, or 14) the capture/import
    /// classifier read off the exam title (Aug 2026). Course level and
    /// subject carry the signal; there is deliberately no web search and
    /// no finer precision — a confident "start 11 days out" would invent
    /// an authority the app doesn't have (`DESIGN.md`). Nil = the
    /// classifier didn't say (deterministic calendar imports never can);
    /// `ExamPrepSweep` reads nil as `NudgeConfig.defaultPrepLeadDays`.
    /// Only meaningful on exam-category informational events; inert
    /// everywhere else.
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
