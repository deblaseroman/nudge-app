//
//  ExamPrepSweep.swift
//  Nudge
//
//  Turns exam-category calendar events into daily study tasks — the app's
//  defining feature (DESIGN.md "Study tasks from exam events"): the user
//  who most needs that scaffolding is least likely to build it by hand.
//
//  Runs on launch and day-change (called from `ContentView` beside
//  `PlacementRollover`, BEFORE the arbiter reevaluate, so freshly created
//  tasks are in the store when candidates are built). For each open
//  exam-category event whose day is within its prep-lead band of today:
//
//    • CREATE one study task per remaining day up to (not including) the
//      exam day — `source = "prep"`, titled plainly, linked to the exam,
//      stakes high, duration from the exam category prior.
//    • IDEMPOTENT — a (exam, day) pair that already has a prep task
//      creates nothing; running the sweep twice is a no-op.
//    • DEDUPE — if the user already made their own study task for that
//      exam (deterministic title matching, see `userStudyTaskMatch`),
//      create nothing for that exam at all. Duplicating the user's own
//      planning is worse than doing nothing.
//    • TOMBSTONES — a day the user deleted (recorded as `PrepTombstone`,
//      which survives the task's removal) is never recreated. The message
//      box asks once whether they still want study time for that exam.
//    • ANNOUNCE — silent creation is not acceptable: when tasks are
//      created, an announcement context is written for the Tasks message
//      box ("Your Stats exam is in 6 days — I've added study time each
//      day until then").
//
//  The decision core (`decide`) is a pure static function over value
//  inputs so the copy-harness technique can run fixture exams against the
//  exact shipped logic without SwiftData.
//
//  ── COMMITMENTS (cycle 2026-08-03-01) ────────────────────────────────
//  This sweep is also the general form of itself: a brain-dumped
//  commitment ("module 4 by Friday" = split work, "an hour a day until
//  Friday" = rate, "three applications a day" = quantity) expands here
//  into one `source == "commitment"` task per day, exactly the way an
//  exam expands into prep tasks. Shared with the exam half — the run
//  cadence, the (parent, day-stamp) idempotence via `missingStamps`, the
//  `PrepTombstone` model (its `examEventId`/`examTitle` fields read as
//  "parent id/title" for commitment rows — historical names, same
//  mechanism), and the announce-through-the-message-box rule. Not shared
//  — the parent source (a `NudgeCommitment` row converted from the
//  captured task, not a calendar event), the per-day math (split ÷ days
//  vs. one-per-day), and the window (deadline-bounded rolling horizon vs.
//  lead band). An exam is a commitment whose deadline is an event and
//  whose work is studying.
//

import Foundation
import SwiftData

// MARK: - Message-box contexts

/// "The sweep just created study tasks" — read by the Tasks message box.
/// Valid on the day it was created; once rendered, it stays for
/// `prepMessageFreshnessMinutes` and then yields (a passive display can't
/// know it was read, so time bounds it).
struct PrepAnnouncementContext: Equatable {
    let examTitle: String
    let daysUntil: Int
    let createdAt: Date
    let shownAt: Date?
}

/// "The user deleted a study task" — the one-time message-box note asking
/// whether they still want study time for that exam. Backed by
/// `PrepTombstone.noteShownAt`; per exam, never repeats. Commitments get
/// the same note with commitment copy (`isCommitment` — the tombstone's
/// parent ID matches a `NudgeCommitment` row instead of an exam event).
struct PrepNoteContext: Equatable {
    let examTitle: String
    let examEventId: String
    var isCommitment: Bool = false
}

/// "The sweep just expanded a commitment into daily tasks" — read by the
/// Tasks message box, same lifecycle as `PrepAnnouncementContext` (valid
/// on its creation day; freshness-windowed after first render).
struct CommitmentAnnouncementContext: Equatable {
    let title: String
    let shape: CommitmentShape
    /// Days from today through the commitment's last generated day.
    let daysUntilEnd: Int
    /// Per-day session length, when the shape has one.
    let dailyMinutes: Int?
    /// Per-day unit count, for quantity commitments.
    let dailyCount: Int?
    /// True when the first generated day is tomorrow (the user's answer,
    /// or the no-room-today default) — the copy says so.
    let startsTomorrow: Bool
    let createdAt: Date
    let shownAt: Date?
}

// MARK: - Sweep

@MainActor
final class ExamPrepSweep {

    static let shared = ExamPrepSweep()
    private init() {}

    // MARK: Lead band

    /// Tolerant read of a classifier-emitted lead value: only the coarse
    /// bands are valid, anything else is "the model didn't say".
    static func validLeadBand(_ value: Int?) -> Int? {
        guard let value, NudgeConfig.prepLeadBands.contains(value) else { return nil }
        return value
    }

    // MARK: Pure decision core

    /// Everything the sweep decides about one exam, computed from values —
    /// no SwiftData. `run` maps store rows into these inputs; the DEBUG
    /// fixture harness calls it directly.
    struct Decision {
        let examTitle: String
        let leadDays: Int
        let daysRemaining: Int
        /// False when the exam is today/past (no study days left) or still
        /// beyond its lead band (not yet the sweep's business).
        let inWindow: Bool
        /// The user's own study task that blocked creation, if any.
        let dedupeHit: String?
        /// Day stamps the user deleted — never recreated.
        let tombstonedStamps: [String]
        /// Day stamps that already have a prep task (idempotence).
        let existingStamps: [String]
        /// Day stamps the sweep should create tasks for.
        let createStamps: [String]
    }

    static func decide(
        examTitle: String,
        examDay: Date,
        prepLeadDays: Int?,
        today: Date,
        userTaskTitles: [String],
        existingPrepDayStamps: Set<String>,
        tombstonedDayStamps: Set<String>,
        calendar: Calendar = .current
    ) -> Decision {
        let lead = validLeadBand(prepLeadDays) ?? NudgeConfig.defaultPrepLeadDays
        let start = calendar.startOfDay(for: today)
        let exam = calendar.startOfDay(for: examDay)
        let daysRemaining = calendar.dateComponents([.day], from: start, to: exam).day ?? 0

        // Exam today or past: no study days left. Beyond the band: not yet.
        guard daysRemaining >= 1, daysRemaining <= lead else {
            return Decision(
                examTitle: examTitle, leadDays: lead, daysRemaining: daysRemaining,
                inWindow: false, dedupeHit: nil,
                tombstonedStamps: tombstonedDayStamps.sorted(),
                existingStamps: existingPrepDayStamps.sorted(), createStamps: []
            )
        }

        if let hit = userStudyTaskMatch(examTitle: examTitle, taskTitles: userTaskTitles) {
            return Decision(
                examTitle: examTitle, leadDays: lead, daysRemaining: daysRemaining,
                inWindow: true, dedupeHit: hit,
                tombstonedStamps: tombstonedDayStamps.sorted(),
                existingStamps: existingPrepDayStamps.sorted(), createStamps: []
            )
        }

        // One task per remaining day, today through the day BEFORE the
        // exam: 3 days out → 3 tasks. Capped by construction — daysRemaining
        // ≤ lead ≤ 14 — and by the stamp dedupe (one per exam per day).
        let create = Self.missingStamps(
            from: start,
            dayOffsets: 0..<daysRemaining,
            existing: existingPrepDayStamps,
            tombstoned: tombstonedDayStamps,
            calendar: calendar
        )

        return Decision(
            examTitle: examTitle, leadDays: lead, daysRemaining: daysRemaining,
            inWindow: true, dedupeHit: nil,
            tombstonedStamps: tombstonedDayStamps.sorted(),
            existingStamps: existingPrepDayStamps.sorted(), createStamps: create
        )
    }

    /// The one day-window walk both halves of the sweep share: which of
    /// these day offsets still need a generated task — not already
    /// created (idempotence) and not deleted by the user (tombstones,
    /// never recreated).
    static func missingStamps(
        from start: Date,
        dayOffsets: Range<Int>,
        existing: Set<String>,
        tombstoned: Set<String>,
        calendar: Calendar
    ) -> [String] {
        var create: [String] = []
        for offset in dayOffsets {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let stamp = Self.stamp(day)
            guard !existing.contains(stamp), !tombstoned.contains(stamp) else { continue }
            create.append(stamp)
        }
        return create
    }

    // MARK: Split-work session math (pure)

    /// How a split-work total divides across the days available: session
    /// length rounds UP to half-hour blocks (eight hours across four days
    /// is four two-hour sessions, not eight fragments), floored and
    /// capped by `NudgeConfig`, and the session count then shrinks below
    /// the day count when the total doesn't need every day (one hour
    /// across five days is two half-hour sessions, not five slivers).
    /// When the total exceeds cap × days, the schedule honestly covers
    /// less than the stated total rather than producing day-swallowing
    /// blocks.
    static func splitWorkPlan(
        totalMinutes: Int,
        daysAvailable: Int
    ) -> (sessionMinutes: Int, sessions: Int) {
        guard totalMinutes > 0, daysAvailable > 0 else { return (0, 0) }
        let block = NudgeConfig.commitmentSessionBlockMinutes
        let perDay = (totalMinutes + daysAvailable - 1) / daysAvailable
        let rounded = ((perDay + block - 1) / block) * block
        let session = min(
            max(rounded, NudgeConfig.commitmentMinSessionMinutes),
            NudgeConfig.commitmentMaxSessionMinutes
        )
        let sessions = min((totalMinutes + session - 1) / session, daysAvailable)
        return (session, sessions)
    }

    // MARK: Commitment readiness + start day (pure over inputs)

    /// Whether a captured commitment parent has the numbers expansion
    /// needs — nil when a question is still outstanding (or the deadline
    /// leaves no room). Shared by `commitmentPhase` and `HomeTabView`'s
    /// start-day follow-up so the two can't disagree on "ready".
    static func expansionReadiness(
        _ parent: NudgeTask,
        today: Date,
        calendar: Calendar = .current
    ) -> CommitmentShape? {
        guard let shape = parent.commitmentShape,
              !parent.isComplete, !parent.isInformationalEvent,
              let due = parent.dueDate else { return nil }
        let endDay = calendar.startOfDay(for: due)
        switch shape {
        case .splitWork:
            guard let total = parent.estimatedMinutes, total > 0,
                  (calendar.dateComponents([.day], from: today, to: endDay).day ?? 0) >= 1
            else { return nil }
        case .rate:
            guard endDay >= today else { return nil }
        case .quantity:
            guard let count = parent.commitmentDailyCount, count > 0,
                  endDay >= today else { return nil }
        }
        return shape
    }

    /// Whether starting today is a genuine choice (cycle 2026-08-03-02
    /// item 3). This flow is capped at two questions for a reason, so the
    /// question is asked only when both answers are truly available.
    enum StartDayDecision {
        /// Today has no room for the first session — a question with one
        /// answer is noise; start tomorrow silently.
        case tomorrowOnly
        /// Dropping today would force the remaining sessions longer
        /// (split work arithmetic) — no choice to offer; state what's
        /// happening instead of asking.
        case todayForced
        /// Both work: ask.
        case choice
    }

    /// Minutes left in today's plannable window (wake+30 → bed−60, via
    /// `DayWindow`). Nil = unknown (no profile / degenerate window) —
    /// callers fail OPEN (assume room), matching `dayLoad`'s convention.
    static func plannableMinutesRemainingToday(now: Date, profile: UserProfile?) -> Int? {
        guard let profile else { return nil }
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        guard let window = DayWindow.resolve(on: now, wake: wake, bedtime: profile.bedtime)
        else { return nil }
        let remaining = window.end.timeIntervalSince(max(now, window.start))
        return max(0, Int(remaining / 60))
    }

    /// The first session's length, for the room-today check. Split work
    /// uses the real session plan; a rate uses its stated (or prior)
    /// duration; a quantity day has no duration model — 30 minutes is the
    /// conservative stand-in.
    static func firstSessionMinutes(
        shape: CommitmentShape,
        totalMinutes: Int?,
        dailyMinutes: Int?,
        category: TaskCategory?,
        daysFromTodayToDeadline: Int
    ) -> Int {
        switch shape {
        case .splitWork:
            guard let total = totalMinutes, total > 0 else {
                return NudgeConfig.commitmentMinSessionMinutes
            }
            let days = min(max(daysFromTodayToDeadline, 1), NudgeConfig.commitmentHorizonDays)
            return splitWorkPlan(totalMinutes: total, daysAvailable: days).sessionMinutes
        case .rate:
            if let daily = dailyMinutes, daily > 0 { return daily }
            if let category { return NudgeConfig.categoryEffortPriors[category] ?? 30 }
            return 30
        case .quantity:
            return 30
        }
    }

    static func startDayDecision(
        shape: CommitmentShape,
        totalMinutes: Int?,
        dailyMinutes: Int?,
        category: TaskCategory?,
        endDay: Date,
        now: Date,
        profile: UserProfile?,
        calendar: Calendar = .current
    ) -> StartDayDecision {
        let today = calendar.startOfDay(for: now)
        let daysToDeadline = max(calendar.dateComponents([.day], from: today, to: endDay).day ?? 0, 0)
        let session = firstSessionMinutes(
            shape: shape, totalMinutes: totalMinutes, dailyMinutes: dailyMinutes,
            category: category, daysFromTodayToDeadline: daysToDeadline
        )
        if let remaining = plannableMinutesRemainingToday(now: now, profile: profile),
           remaining < session {
            return .tomorrowOnly
        }
        // Growth check — split work only: a rate/quantity that skips today
        // just starts tomorrow; nothing grows.
        if shape == .splitWork, let total = totalMinutes, total > 0 {
            let daysToday = min(max(daysToDeadline, 1), NudgeConfig.commitmentHorizonDays)
            let daysTomorrow = daysToDeadline - 1
            guard daysTomorrow >= 1 else { return .todayForced }
            let fromToday = splitWorkPlan(totalMinutes: total, daysAvailable: daysToday).sessionMinutes
            let fromTomorrow = splitWorkPlan(
                totalMinutes: total,
                daysAvailable: min(daysTomorrow, NudgeConfig.commitmentHorizonDays)
            ).sessionMinutes
            if fromTomorrow > fromToday { return .todayForced }
        }
        return .choice
    }

    // MARK: Dedupe matching (deterministic v1)

    /// Whether one of the user's own open tasks already covers studying
    /// for this exam. Deterministic on purpose — AI matching is a later
    /// cycle. A task matches when its normalized title
    ///   • contains the exam's course token ("chem 101", "bio 220" — an
    ///     adjacent word+number pair from the exam title), OR
    ///   • contains a study word (study/review/prep/practice/revise/cram)
    ///     AND shares a subject token with the exam title.
    /// Known misses, accepted for v1: nicknames ("orgo" for Organic
    /// Chemistry), synonyms without a study word ("go over chem notes"
    /// matches via "chem"; "go over notes" alone doesn't), misspellings.
    static func userStudyTaskMatch(examTitle: String, taskTitles: [String]) -> String? {
        let subject = subjectTokens(examTitle)
        let phrases = coursePhrases(examTitle)
        let studyWords = ["study", "review", "prep", "practice", "revise", "cram"]

        for title in taskTitles {
            let lower = normalize(title)
            if phrases.contains(where: { lower.contains($0) }) { return title }
            let tokens = tokenSet(lower)
            let hasStudyWord = studyWords.contains { lower.contains($0) }
            if hasStudyWord && !subject.isDisjoint(with: tokens) { return title }
        }
        return nil
    }

    /// Exam-title words that carry subject identity — everything minus the
    /// exam-shaped and glue words.
    static func subjectTokens(_ examTitle: String) -> Set<String> {
        let stop: Set<String> = [
            "exam", "exams", "midterm", "final", "finals", "test", "quiz",
            "the", "a", "an", "of", "for", "on", "in", "my", "and", "to", "at"
        ]
        return tokenSet(normalize(examTitle)).subtracting(stop)
    }

    /// Adjacent word+number pairs in the exam title — "chem 101",
    /// "bio 220" — the strongest deterministic identity a course has.
    static func coursePhrases(_ examTitle: String) -> [String] {
        let tokens = normalize(examTitle)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var phrases: [String] = []
        for i in 0..<max(tokens.count, 1) where i + 1 < tokens.count {
            let second = tokens[i + 1]
            if Int(second) != nil, Int(tokens[i]) == nil {
                phrases.append("\(tokens[i]) \(second)")
            }
        }
        return phrases
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tokenSet(_ normalized: String) -> Set<String> {
        Set(normalized.components(separatedBy: " ").filter { $0.count >= 2 })
    }

    static func stamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    /// The due date a generated daily task carries: the END of its own day
    /// (23:59), matching capture's bare-date convention (cycle
    /// 2026-08-03-02 item 1). The generators used to store start-of-day —
    /// fine for `sortDeadline` (which reads a bare date as end-of-day)
    /// but the row subtitle feeds the RAW dueDate to
    /// `CountdownState.remainingLine`, whose overdue rule always wins, so
    /// today's session was born reading "20 hours ago". A session is due
    /// tonight, not this morning. Day-stamp idempotence is unaffected:
    /// every stamp read normalizes through `startOfDay` first.
    static func sessionDueDate(on day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: start) ?? start
    }

    // MARK: The sweep

    /// Finds exam events in their prep window and commitments in their
    /// generation window, and creates the missing daily tasks for both.
    /// Idempotent; safe on every launch/foreground. Returns the number of
    /// tasks created.
    @discardableResult
    func run(modelContext: ModelContext, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tombstones = (try? modelContext.fetch(FetchDescriptor<PrepTombstone>())) ?? []

        let created = examPhase(
            modelContext: modelContext, tombstones: tombstones,
            today: today, now: now, calendar: calendar
        ) + commitmentPhase(
            modelContext: modelContext, tombstones: tombstones,
            today: today, now: now, calendar: calendar
        )

        if created > 0 {
            try? modelContext.save()
            // The day's shape just changed — study days materialized or a
            // commitment expanded into dailies. That's a real shift in
            // what the next days are about, so the AI nudge-copy cache
            // regenerates (throttled inside; cycle 2026-08-03-03). Both
            // trigger paths land here: an exam entering its lead window
            // and a captured commitment whose numbers just completed.
            NudgeCopyGenerator.shared.noteShift(.generatedWork, modelContext: modelContext)
        }
        return created
    }

    // MARK: Exam phase

    private func examPhase(
        modelContext: ModelContext,
        tombstones: [PrepTombstone],
        today: Date,
        now: Date,
        calendar: Calendar
    ) -> Int {
        let events = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.isInformationalEvent && !$0.isComplete }
        ))) ?? []
        let exams = events
            .filter { $0.taskCategory == .exam }
            .compactMap { exam -> (NudgeTask, Date)? in
                guard let day = exam.specificTime ?? exam.dueDate else { return nil }
                return (exam, day)
            }
            .sorted { $0.1 < $1.1 }
        guard !exams.isEmpty else { return 0 }

        // One fetch each for the sweep's cross-checks.
        let prepSource = "prep"
        let allPrep = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.source == prepSource }
        ))) ?? []
        let openUserTasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> {
                !$0.isComplete && !$0.isInformationalEvent && $0.source != prepSource
            }
        ))) ?? []
        let userTitles = openUserTasks.map(\.title)

        var createdTotal = 0
        var announced = false

        for (exam, examDay) in exams {
            let examID = exam.id.uuidString
            let existingStamps = Set(
                allPrep
                    .filter { $0.linkedEventId == examID }
                    .compactMap { $0.dueDate.map { Self.stamp(calendar.startOfDay(for: $0)) } }
            )
            let tombstonedStamps = Set(
                tombstones.filter { $0.examEventId == examID }.map(\.dayStamp)
            )

            let decision = Self.decide(
                examTitle: exam.title,
                examDay: examDay,
                prepLeadDays: exam.prepLeadDays,
                today: today,
                userTaskTitles: userTitles,
                existingPrepDayStamps: existingStamps,
                tombstonedDayStamps: tombstonedStamps,
                calendar: calendar
            )

            #if DEBUG
            // The per-exam dump work-order item 5 asks for: lead band, days
            // remaining, dedupe verdict, tombstone state, created days.
            print("[ExamPrepSweep] \"\(exam.title)\" lead=\(decision.leadDays)d "
                + "remaining=\(decision.daysRemaining)d "
                + (decision.inWindow ? "IN WINDOW" : "out of window")
                + " dedupe=\(decision.dedupeHit.map { "user task \"\($0)\"" } ?? "none")"
                + " tombstoned=\(decision.tombstonedStamps.isEmpty ? "—" : decision.tombstonedStamps.joined(separator: ","))"
                + " existing=\(decision.existingStamps.count)"
                + " create=\(decision.createStamps.isEmpty ? "—" : decision.createStamps.joined(separator: ","))")
            #endif

            guard !decision.createStamps.isEmpty else { continue }

            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            for stamp in decision.createStamps {
                guard let day = fmt.date(from: stamp) else { continue }
                let task = NudgeTask(
                    title: "Study for \(exam.title)",
                    // Due at the END of its own day (23:59, capture's
                    // bare-date convention) — start-of-day made today's
                    // study task read "N hours ago" from birth (cycle
                    // 2026-08-03-02 item 1).
                    dueDate: Self.sessionDueDate(on: day, calendar: calendar),
                    priority: "medium",
                    category: TaskCategory.exam.rawValue,
                    source: "prep",
                    // The category prior, stated explicitly so the task
                    // shows a duration the user can see and edit. Learning
                    // prep effort from history is out of scope for v1.
                    estimatedMinutes: NudgeConfig.categoryEffortPriors[.exam]
                        ?? NudgeConfig.defaultEffortPriorMinutes,
                    linkedEventId: examID
                )
                // "Stakes inherited high": an exam's misses are consequential
                // by definition (the import path stamps the event high the
                // same way). Through the guarded automation path, never the
                // init.
                task.setStakesFromAutomation(.high)
                modelContext.insert(task)
                createdTotal += 1
            }
            #if DEBUG
            if !decision.createStamps.isEmpty {
                print("   ↳ \(decision.createStamps.count) study task(s) created, "
                    + "each due 23:59 of its own day (was start-of-day before 2026-08-03-02)")
            }
            #endif

            // Announce the SOONEST exam that got tasks this run — silent
            // creation is not acceptable (DESIGN.md). Exams are processed in
            // date order, so the first is the soonest.
            if !announced {
                Self.writeAnnouncement(
                    examTitle: exam.title,
                    daysUntil: decision.daysRemaining,
                    now: now
                )
                announced = true
            }
        }

        return createdTotal
    }

    // MARK: Commitment phase

    /// Two steps, mirroring the exam phase's shape. First, every captured
    /// commitment whose numbers are now known (the questions answered, or
    /// never needed) is EXPANDED: a `NudgeCommitment` row takes over as
    /// the durable parent and the capture task is deleted — its daily
    /// tasks replace it in the list, and listing both would show the same
    /// work twice. Second, every commitment still in its window gets its
    /// missing daily tasks: split work generates once (the whole session
    /// plan, front-loaded from today); a rate generates on a rolling
    /// `commitmentHorizonDays` window topped up each run.
    private func commitmentPhase(
        modelContext: ModelContext,
        tombstones: [PrepTombstone],
        today: Date,
        now: Date,
        calendar: Calendar
    ) -> Int {
        // ── Step 1: expand ready parents ────────────────────────────────
        let profile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first
        let parents = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> {
                $0.commitmentShapeRaw != nil && !$0.isComplete && !$0.isInformationalEvent
            }
        ))) ?? []
        for parent in parents {
            // Readiness (shared with HomeTabView's follow-up logic): a
            // missing number means a question is outstanding; a same-day
            // or past split-work deadline stays an ordinary task
            // (overdue handling covers it) rather than expanding into
            // nothing.
            guard let shape = Self.expansionReadiness(parent, today: today, calendar: calendar),
                  let due = parent.dueDate else { continue }
            let endDay = calendar.startOfDay(for: due)

            // The start-today-or-tomorrow question is outstanding: asked
            // today, not yet answered. Wait — an ask from a PAST day has
            // expired (the day it asked about no longer exists) and falls
            // through to the viability default below.
            if parent.commitmentStartDate == nil,
               let asked = parent.commitmentStartAskedAt,
               calendar.isDate(asked, inSameDayAs: now) {
                #if DEBUG
                print("[ExamPrepSweep] \"\(parent.title)\" waiting on start-day answer — not expanded")
                #endif
                continue
            }

            // First day: the chosen answer when one exists, else the
            // viability default — captured at 10pm, tomorrow is the only
            // possible answer, so no question was needed.
            var startDay = today
            if let chosen = parent.commitmentStartDate {
                startDay = max(today, calendar.startOfDay(for: chosen))
            } else if Self.startDayDecision(
                shape: shape,
                totalMinutes: shape == .splitWork ? parent.estimatedMinutes : nil,
                dailyMinutes: shape == .rate ? parent.estimatedMinutes : nil,
                category: parent.taskCategory,
                endDay: endDay,
                now: now,
                profile: profile,
                calendar: calendar
            ) == .tomorrowOnly,
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) {
                startDay = tomorrow
            }
            // A forced start day is ACTED ON, not just un-asked (cycle
            // 2026-08-03-04 item 1). The old rule here — "split work needs
            // a day before the deadline; deadline pressure beats bedtime" —
            // snapped a tomorrowOnly start back to today, so a commitment
            // captured at 10:30pm due tomorrow silently generated a session
            // for the remainder of tonight. The rule now: tomorrowOnly
            // means tomorrow, and when tomorrow IS the deadline day the
            // one-day schedule lands on the deadline day itself — a bare
            // due date resolves to 23:59, so a session that day still
            // precedes it (the generation step below counts that day as
            // available). Only a start strictly past the end day (a
            // rate/quantity ending today, captured after the window) still
            // falls back to today: its end date is inclusive, so today is
            // the commitment's real last day.
            if startDay > endDay { startDay = today }

            let commitment = NudgeCommitment(
                title: parent.title,
                sessionTitle: parent.commitmentSessionTitle,
                shape: shape,
                endDate: endDay,
                startDate: startDay > today ? startDay : nil,
                totalMinutes: shape == .splitWork ? parent.estimatedMinutes : nil,
                dailyMinutes: shape == .rate ? parent.estimatedMinutes : nil,
                dailyCount: shape == .quantity ? parent.commitmentDailyCount : nil,
                stakesRaw: parent.stakesRaw,
                category: parent.category,
                timeWindowRaw: parent.timeWindowRaw,
                createdAt: now,
                sourceTaskId: parent.id
            )
            modelContext.insert(commitment)
            modelContext.delete(parent)
            #if DEBUG
            print("[ExamPrepSweep] expanded commitment \"\(commitment.title)\" (\(shape.rawValue)) "
                + "sessions titled \"\(commitment.sessionTitle ?? commitment.title)\" "
                + "start=\(Self.stamp(startDay)) end=\(Self.stamp(endDay)) "
                + "total=\(commitment.totalMinutes.map(String.init) ?? "—")m "
                + "daily=\(commitment.dailyMinutes.map(String.init) ?? "—")m")
            #endif
        }

        // ── Step 2: generate missing dailies ────────────────────────────
        let commitments = (try? modelContext.fetch(FetchDescriptor<NudgeCommitment>())) ?? []
        guard !commitments.isEmpty else { return 0 }
        let commitmentSource = "commitment"
        let allDailies = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.source == commitmentSource }
        ))) ?? []

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var created = 0
        var announced = false

        for commitment in commitments.sorted(by: { $0.endDate < $1.endDate }) {
            guard let shape = commitment.shape else { continue }
            let parentID = commitment.id.uuidString
            let existingStamps = Set(
                allDailies
                    .filter { $0.linkedEventId == parentID }
                    .compactMap { $0.dueDate.map { Self.stamp(calendar.startOfDay(for: $0)) } }
            )
            let tombstonedStamps = Set(
                tombstones.filter { $0.examEventId == parentID }.map(\.dayStamp)
            )

            // Generation begins on the commitment's start day (the
            // today-or-tomorrow answer / viability default), which decays
            // to plain "today" once that day arrives.
            let genStart: Date = {
                guard let start = commitment.startDate else { return today }
                return max(today, calendar.startOfDay(for: start))
            }()
            let startOffset = calendar.dateComponents([.day], from: today, to: genStart).day ?? 0

            let stamps: [String]
            let lastDayOffset: Int
            switch shape {
            case .splitWork:
                // One-shot: the session plan is computed once, against the
                // days available at expansion, and never re-divided — a
                // later run re-planning over fewer remaining days would
                // quietly inflate the sessions the user already saw. Any
                // existing daily or tombstone means the plan was laid.
                guard existingStamps.isEmpty, tombstonedStamps.isEmpty,
                      let total = commitment.totalMinutes, total > 0 else { continue }
                let gapDays = calendar.dateComponents(
                    [.day], from: genStart, to: commitment.endDate
                ).day ?? 0
                // Sessions normally occupy the days BEFORE the deadline day.
                // When the start day IS the deadline day (a tomorrowOnly
                // start with the deadline tomorrow — cycle 2026-08-03-04
                // item 1), that day is the one remaining work day: a bare
                // due date resolves to 23:59, so a session there still
                // precedes it. Without this, the guard below regressed the
                // forced-tomorrow start into "expanded into nothing".
                let daysRemaining = gapDays >= 1
                    ? gapDays
                    : (genStart <= commitment.endDate ? 1 : 0)
                guard daysRemaining >= 1 else { continue }
                let daysAvailable = min(daysRemaining, NudgeConfig.commitmentHorizonDays)
                let plan = Self.splitWorkPlan(totalMinutes: total, daysAvailable: daysAvailable)
                guard plan.sessions > 0 else { continue }
                commitment.dailyMinutes = plan.sessionMinutes
                stamps = Self.missingStamps(
                    from: genStart, dayOffsets: 0..<plan.sessions,
                    existing: [], tombstoned: [], calendar: calendar
                )
                lastDayOffset = startOffset + plan.sessions - 1
            case .rate, .quantity:
                // Rolling: one task per day, the start day through the end
                // date INCLUSIVE ("an hour a day until Friday" includes
                // Friday), capped at the horizon and topped up each run.
                let daysToEnd = calendar.dateComponents(
                    [.day], from: genStart, to: commitment.endDate
                ).day ?? -1
                guard daysToEnd >= 0 else { continue }   // expired; row stays as memory
                let lastLocalOffset = min(daysToEnd, NudgeConfig.commitmentHorizonDays - 1)
                stamps = Self.missingStamps(
                    from: genStart, dayOffsets: 0..<(lastLocalOffset + 1),
                    existing: existingStamps, tombstoned: tombstonedStamps, calendar: calendar
                )
                lastDayOffset = startOffset + lastLocalOffset
            }

            #if DEBUG
            print("[ExamPrepSweep] commitment \"\(commitment.title)\" (\(shape.rawValue)) "
                + "end=\(Self.stamp(commitment.endDate)) "
                + "daily=\(commitment.dailyMinutes.map { "\($0)m" } ?? "—") "
                + "existing=\(existingStamps.count) "
                + "tombstoned=\(tombstonedStamps.isEmpty ? "—" : tombstonedStamps.sorted().joined(separator: ","))"
                + " create=\(stamps.isEmpty ? "—" : stamps.joined(separator: ","))")
            #endif

            guard !stamps.isEmpty else { continue }

            for stampValue in stamps {
                guard let day = fmt.date(from: stampValue) else { continue }
                let task = NudgeTask(
                    // Dailies carry the short session name; the day-label
                    // subtitle distinguishes them. Fallback to the goal
                    // name covers pre-sessionTitle rows and AI omission.
                    title: commitment.sessionTitle ?? commitment.title,
                    // Due at the END of its own day — see `sessionDueDate`.
                    dueDate: Self.sessionDueDate(on: day, calendar: calendar),
                    priority: "medium",
                    category: commitment.category,
                    source: "commitment",
                    estimatedMinutes: commitment.dailyMinutes,
                    linkedEventId: parentID
                )
                // Stakes inherited from the parent commitment, through the
                // guarded automation path, never the init.
                task.setStakesFromAutomation(commitment.stakes)
                task.timeWindow = commitment.timeWindow
                // Quantity: one task with a count, never N tasks. The
                // carry stamp comes later, in the carry walk.
                if shape == .quantity, let count = commitment.dailyCount, count > 0 {
                    task.targetCount = count
                    task.completedCount = 0
                }
                modelContext.insert(task)
                created += 1
            }
            #if DEBUG
            print("   ↳ \(stamps.count) daily task(s) created for \"\(commitment.title)\" "
                + "(\(shape.rawValue)), each due 23:59 of its own day")
            #endif

            // Announce the soonest-ending commitment that got tasks this
            // run — silent creation is not acceptable (DESIGN.md).
            if !announced {
                Self.writeCommitmentAnnouncement(
                    title: commitment.title,
                    shape: shape,
                    daysUntilEnd: lastDayOffset,
                    dailyMinutes: commitment.dailyMinutes,
                    dailyCount: commitment.dailyCount,
                    startsTomorrow: startOffset > 0,
                    now: now
                )
                announced = true
            }
        }

        // ── Step 3: quantity carry-over ─────────────────────────────────
        applyQuantityCarry(
            commitments: commitments, modelContext: modelContext,
            today: today, calendar: calendar
        )

        return created
    }

    /// Rolls missed quantity units forward, capped at
    /// `commitmentCarryCapDays` days' worth — a week of misses shows the
    /// same number as three days of misses, because an uncapped carry is
    /// a number the user cannot hit, and a number you cannot hit is the
    /// reason not to start (`DESIGN.md`: never show an impossible target).
    ///
    /// Mechanics: `NudgeCommitment.carryUnits` is the durable accumulator.
    /// Each PAST daily is consumed exactly once, in date order — its
    /// shortfall (base + carry-in − done, floored at 0, capped) becomes
    /// the new carry, and the row is then deleted: the carry IS the
    /// reschedule (a missed day moves forward, it doesn't sit red in
    /// Overdue — rescheduled with more urgency, not punishment), completed
    /// history lives in `CompletedTaskRecord`, and consuming the row is
    /// what makes re-running the walk a no-op. A user-deleted (tombstoned)
    /// day simply never appears — no task, no target, carry passes
    /// through unchanged. Today's task then gets the accumulator stamped
    /// as `carriedCount`, so the displayed number is always the capped one.
    private func applyQuantityCarry(
        commitments: [NudgeCommitment],
        modelContext: ModelContext,
        today: Date,
        calendar: Calendar
    ) {
        var mutated = false
        for commitment in commitments {
            guard commitment.shape == .quantity,
                  let base = commitment.dailyCount, base > 0 else { continue }
            let cap = base * NudgeConfig.commitmentCarryCapDays
            let parentID = commitment.id.uuidString
            let commitmentSource = "commitment"
            let dailies = ((try? modelContext.fetch(FetchDescriptor<NudgeTask>(
                predicate: #Predicate<NudgeTask> {
                    $0.source == commitmentSource && $0.linkedEventId == parentID
                }
            ))) ?? []).sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }

            for task in dailies {
                guard let due = task.dueDate,
                      calendar.startOfDay(for: due) < today else { continue }
                let effective = base + commitment.carryUnits
                let done = task.isComplete
                    ? effective
                    : min(task.completedCount ?? 0, effective)
                commitment.carryUnits = min(cap, max(0, effective - done))
                modelContext.delete(task)
                mutated = true
                #if DEBUG
                print("[ExamPrepSweep] \"\(commitment.title)\" consumed \(Self.stamp(due)): "
                    + "did \(done)/\(effective) → carry \(commitment.carryUnits) (cap \(cap))")
                #endif
            }

            if let todayTask = dailies.first(where: { task in
                guard let due = task.dueDate else { return false }
                return calendar.isDate(due, inSameDayAs: today)
            }) {
                let stamped = commitment.carryUnits > 0 ? commitment.carryUnits : nil
                if todayTask.carriedCount != stamped {
                    todayTask.carriedCount = stamped
                    mutated = true
                }
            }
        }
        if mutated {
            try? modelContext.save()
        }
    }

    // MARK: Deletion tombstone

    /// Records the deletion of a generated daily task — prep or commitment.
    /// Call BEFORE deleting the task — the tombstone is what survives it.
    /// No-op for anything that isn't a linked generated task.
    ///
    /// The message-box note is per-PARENT and never repeats: if any earlier
    /// tombstone for this parent has already shown its note, the new row is
    /// inserted pre-stamped. (`PrepTombstone.examEventId`/`examTitle` read
    /// as "parent id/title" for commitment rows — historical names, one
    /// mechanism.)
    static func recordDeletionIfGenerated(_ task: NudgeTask, modelContext: ModelContext) {
        guard task.source == "prep" || task.source == "commitment",
              let examID = task.linkedEventId,
              // Sweep-made rows carry a per-day due date; plan sessions
              // (cycle 2026-09-16-01) are scheduled, not due, so their day
              // is the intended day. Either way, the day is the stamp.
              let day = task.dueDate ?? task.intendedDate else { return }
        let dayStamp = stamp(Calendar.current.startOfDay(for: day))

        let existing = (try? modelContext.fetch(FetchDescriptor<PrepTombstone>(
            predicate: #Predicate<PrepTombstone> { $0.examEventId == examID }
        ))) ?? []
        guard !existing.contains(where: { $0.dayStamp == dayStamp }) else { return }

        let examUUID = UUID(uuidString: examID)
        let examTitle: String = {
            // Commitment daily: the parent row's title (the daily carries
            // it verbatim, so the task title is its own fallback).
            if task.source == "commitment" {
                if let examUUID,
                   let row = try? modelContext.fetch(FetchDescriptor<NudgeCommitment>(
                       predicate: #Predicate<NudgeCommitment> { $0.id == examUUID }
                   )).first {
                    return row.title
                }
                return task.title
            }
            // Prep: prefer the live exam's title; fall back to stripping
            // the study task's own prefix if the event is already gone.
            if let examUUID,
               let exam = try? modelContext.fetch(FetchDescriptor<NudgeTask>(
                   predicate: #Predicate<NudgeTask> { $0.id == examUUID }
               )).first {
                return exam.title
            }
            let title = task.title
            return title.hasPrefix("Study for ")
                ? String(title.dropFirst("Study for ".count))
                : title
        }()

        let alreadyNoted = existing.contains { $0.noteShownAt != nil }
        modelContext.insert(PrepTombstone(
            examEventId: examID,
            examTitle: examTitle,
            dayStamp: dayStamp,
            noteShownAt: alreadyNoted ? Date() : nil
        ))
        // Caller saves alongside the deletion.
    }

    // MARK: Announcement storage (App Group)

    static let announcementTitleKey = "nudge.prepAnnouncement.examTitle"
    static let announcementDaysKey = "nudge.prepAnnouncement.daysUntil"
    static let announcementCreatedAtKey = "nudge.prepAnnouncement.createdAt"
    static let announcementShownAtKey = "nudge.prepAnnouncement.shownAt"

    private static func writeAnnouncement(examTitle: String, daysUntil: Int, now: Date) {
        let defaults = SharedModelContainer.appGroupDefaults
        defaults.set(examTitle, forKey: announcementTitleKey)
        defaults.set(daysUntil, forKey: announcementDaysKey)
        defaults.set(now, forKey: announcementCreatedAtKey)
        defaults.removeObject(forKey: announcementShownAtKey)
    }

    /// The announcement the message box should show right now, if any:
    /// created today, and either not yet rendered or rendered within the
    /// freshness window.
    static func currentAnnouncement(now: Date = Date()) -> PrepAnnouncementContext? {
        let defaults = SharedModelContainer.appGroupDefaults
        guard
            let title = defaults.string(forKey: announcementTitleKey),
            let createdAt = defaults.object(forKey: announcementCreatedAtKey) as? Date,
            Calendar.current.isDate(createdAt, inSameDayAs: now)
        else { return nil }
        let shownAt = defaults.object(forKey: announcementShownAtKey) as? Date
        if let shownAt {
            let ageMinutes = now.timeIntervalSince(shownAt) / 60
            guard ageMinutes <= Double(NudgeConfig.prepMessageFreshnessMinutes) else { return nil }
        }
        return PrepAnnouncementContext(
            examTitle: title,
            daysUntil: defaults.integer(forKey: announcementDaysKey),
            createdAt: createdAt,
            shownAt: shownAt
        )
    }

    /// Stamps the announcement as rendered (first render only — the stamp
    /// is what starts the freshness countdown).
    static func markAnnouncementShown(now: Date = Date()) {
        let defaults = SharedModelContainer.appGroupDefaults
        guard defaults.object(forKey: announcementShownAtKey) == nil else { return }
        defaults.set(now, forKey: announcementShownAtKey)
    }

    // MARK: Commitment announcement storage (App Group)
    //
    // The prep announcement's mechanism verbatim — single slot, valid on
    // its creation day, freshness-windowed after first render — with its
    // own keys because the two can coexist (an exam sweep and a
    // commitment expansion on the same morning must not overwrite each
    // other's news).

    static let commitmentAnnouncementTitleKey = "nudge.commitmentAnnouncement.title"
    static let commitmentAnnouncementStartsTomorrowKey = "nudge.commitmentAnnouncement.startsTomorrow"
    static let commitmentAnnouncementShapeKey = "nudge.commitmentAnnouncement.shape"
    static let commitmentAnnouncementDaysKey = "nudge.commitmentAnnouncement.daysUntilEnd"
    static let commitmentAnnouncementMinutesKey = "nudge.commitmentAnnouncement.dailyMinutes"
    static let commitmentAnnouncementCountKey = "nudge.commitmentAnnouncement.dailyCount"
    static let commitmentAnnouncementCreatedAtKey = "nudge.commitmentAnnouncement.createdAt"
    static let commitmentAnnouncementShownAtKey = "nudge.commitmentAnnouncement.shownAt"

    private static func writeCommitmentAnnouncement(
        title: String,
        shape: CommitmentShape,
        daysUntilEnd: Int,
        dailyMinutes: Int?,
        dailyCount: Int?,
        startsTomorrow: Bool,
        now: Date
    ) {
        let defaults = SharedModelContainer.appGroupDefaults
        defaults.set(title, forKey: commitmentAnnouncementTitleKey)
        defaults.set(startsTomorrow, forKey: commitmentAnnouncementStartsTomorrowKey)
        defaults.set(shape.rawValue, forKey: commitmentAnnouncementShapeKey)
        defaults.set(daysUntilEnd, forKey: commitmentAnnouncementDaysKey)
        defaults.set(dailyMinutes ?? 0, forKey: commitmentAnnouncementMinutesKey)
        defaults.set(dailyCount ?? 0, forKey: commitmentAnnouncementCountKey)
        defaults.set(now, forKey: commitmentAnnouncementCreatedAtKey)
        defaults.removeObject(forKey: commitmentAnnouncementShownAtKey)
    }

    /// The commitment announcement the message box should show right now,
    /// if any — same rules as `currentAnnouncement`.
    static func currentCommitmentAnnouncement(now: Date = Date()) -> CommitmentAnnouncementContext? {
        let defaults = SharedModelContainer.appGroupDefaults
        guard
            let title = defaults.string(forKey: commitmentAnnouncementTitleKey),
            let shape = CommitmentShape.parse(defaults.string(forKey: commitmentAnnouncementShapeKey)),
            let createdAt = defaults.object(forKey: commitmentAnnouncementCreatedAtKey) as? Date,
            Calendar.current.isDate(createdAt, inSameDayAs: now)
        else { return nil }
        let shownAt = defaults.object(forKey: commitmentAnnouncementShownAtKey) as? Date
        if let shownAt {
            let ageMinutes = now.timeIntervalSince(shownAt) / 60
            guard ageMinutes <= Double(NudgeConfig.prepMessageFreshnessMinutes) else { return nil }
        }
        let minutes = defaults.integer(forKey: commitmentAnnouncementMinutesKey)
        let count = defaults.integer(forKey: commitmentAnnouncementCountKey)
        return CommitmentAnnouncementContext(
            title: title,
            shape: shape,
            daysUntilEnd: defaults.integer(forKey: commitmentAnnouncementDaysKey),
            dailyMinutes: minutes > 0 ? minutes : nil,
            dailyCount: count > 0 ? count : nil,
            startsTomorrow: defaults.bool(forKey: commitmentAnnouncementStartsTomorrowKey),
            createdAt: createdAt,
            shownAt: shownAt
        )
    }

    /// First-render stamp for the commitment announcement.
    static func markCommitmentAnnouncementShown(now: Date = Date()) {
        let defaults = SharedModelContainer.appGroupDefaults
        guard defaults.object(forKey: commitmentAnnouncementShownAtKey) == nil else { return }
        defaults.set(now, forKey: commitmentAnnouncementShownAtKey)
    }
}
