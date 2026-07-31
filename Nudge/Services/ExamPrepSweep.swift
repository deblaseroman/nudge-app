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
/// `PrepTombstone.noteShownAt`; per exam, never repeats.
struct PrepNoteContext: Equatable {
    let examTitle: String
    let examEventId: String
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
        var create: [String] = []
        for offset in 0..<daysRemaining {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let stamp = Self.stamp(day)
            guard !existingPrepDayStamps.contains(stamp),
                  !tombstonedDayStamps.contains(stamp) else { continue }
            create.append(stamp)
        }

        return Decision(
            examTitle: examTitle, leadDays: lead, daysRemaining: daysRemaining,
            inWindow: true, dedupeHit: nil,
            tombstonedStamps: tombstonedDayStamps.sorted(),
            existingStamps: existingPrepDayStamps.sorted(), createStamps: create
        )
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

    // MARK: The sweep

    /// Finds exam events in their prep window and creates the missing study
    /// tasks. Idempotent; safe on every launch/foreground. Returns the
    /// number of tasks created.
    @discardableResult
    func run(modelContext: ModelContext, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

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

        // One fetch each for the sweep's three cross-checks.
        let prepSource = "prep"
        let allPrep = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.source == prepSource }
        ))) ?? []
        let tombstones = (try? modelContext.fetch(FetchDescriptor<PrepTombstone>())) ?? []
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
                    // A bare due DAY, stored the way calendar imports store
                    // theirs (start of day) — `sortDeadline` reads it as
                    // end-of-day, so the task is "due" that evening without
                    // inventing a clock time.
                    dueDate: calendar.startOfDay(for: day),
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

        if createdTotal > 0 {
            try? modelContext.save()
        }
        return createdTotal
    }

    // MARK: Deletion tombstone

    /// Records the deletion of a prep task. Call BEFORE deleting the task —
    /// the tombstone is what survives it. No-op for anything that isn't a
    /// linked prep task.
    ///
    /// The message-box note is per-EXAM and never repeats: if any earlier
    /// tombstone for this exam has already shown its note, the new row is
    /// inserted pre-stamped.
    static func recordDeletionIfPrep(_ task: NudgeTask, modelContext: ModelContext) {
        guard task.source == "prep", let examID = task.linkedEventId,
              let dueDate = task.dueDate else { return }
        let dayStamp = stamp(Calendar.current.startOfDay(for: dueDate))

        let existing = (try? modelContext.fetch(FetchDescriptor<PrepTombstone>(
            predicate: #Predicate<PrepTombstone> { $0.examEventId == examID }
        ))) ?? []
        guard !existing.contains(where: { $0.dayStamp == dayStamp }) else { return }

        // Prefer the live exam's title; fall back to stripping the study
        // task's own prefix if the event is already gone.
        let examUUID = UUID(uuidString: examID)
        let examTitle: String = {
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
}
