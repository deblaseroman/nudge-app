//
//  NudgeCopyService.swift
//  Nudge
//
//  AI-written notification copy, generated AHEAD of time and cached for the
//  arbiter to select from deterministically (cycle 2026-08-03-03).
//
//  iOS fixes a local notification's text at SCHEDULING time — hours or days
//  before it fires, while the app isn't running. So copy can't be generated
//  at delivery; it is generated in advance for the cases the arbiter might
//  need over the next `NudgeConfig.copyCacheDays` days, and the arbiter
//  swaps it in at scheduling time. The AI writes. The arbiter decides. iOS
//  delivers.
//
//  This does NOT put an API call in the arbiter's path (DESIGN.md): the
//  arbiter only ever READS the cache, synchronously. Generation runs on its
//  own triggers (new day, real data shifts), and every read falls back to
//  the deterministic template — no key, no network, a failed call, an empty
//  or stale cache all leave the app behaving exactly as it did before this
//  existed.
//
//  Since Oct 4 2026 (Roman: "the AI writes the notifications, the arbiter
//  decides") EVERY kind is generated: per-task lines for the kinds that
//  name a task or event (morningPrompt, prep, floater, eventBlock, dueSoon,
//  placementLead, placementMissed) and one kind-generic line for the ones
//  that don't (idle, comeBack, goalLapse). The writer never sees a clock
//  time or a day word: it writes PLACEHOLDERS — {task}, {time}, {day},
//  {name}, {goal} — and `NudgeCopyFill` substitutes them at scheduling from
//  the candidate's own facts, relative to its fire date. That is what lets
//  a line written yesterday say "tomorrow" correctly, and what lets a
//  placed block's line survive a replan. A line whose placeholder cannot be
//  filled falls back to the template, same as a stale one. Recent lines are
//  fed back to the writer so each pass reads new (`copyHistoryLimit`).
//
//  Storage is App Group UserDefaults (JSON blob), not a @Model — survives
//  cold launch without joining the three hand-synced schema lists.
//

import Foundation
import SwiftData

// MARK: - Cache entry

/// One cached body string for a (kind, task) pair. `taskID == nil` is
/// kind-generic copy (the idle line).
struct CachedNudgeCopy: Codable {
    let kindRaw: String
    let taskID: String?
    /// For the DEBUG dump only — lookups go by ID.
    let taskTitle: String?
    /// The task's effective deadline (`sortDeadline`) when the copy was
    /// written, nil for undated tasks. Validation at scheduling time
    /// requires the deadline to still stand: copy that says "due Friday"
    /// is wrong the moment the user moves the deadline, not just when the
    /// task completes.
    let dueAtGeneration: Date?
    let body: String
}

// MARK: - Store

/// The cache the arbiter reads at scheduling time. All reads validate:
/// entry age, the named task still open and unfinished, and the deadline
/// unchanged and still ahead of the fire date. Anything off → nil, and the
/// caller uses its deterministic template.
@MainActor
enum NudgeCopyStore {

    static let payloadKey = "nudge.copy.cache"
    static let generatedAtKey = "nudge.copy.generatedAt"
    /// Day stamp (yyyyMMdd) + count backing the DEBUG "how many
    /// generations ran today" printout and the per-day safety cap.
    static let countDayKey = "nudge.copy.countDay"
    static let countKey = "nudge.copy.count"

    static func save(entries: [CachedNudgeCopy], now: Date = Date()) {
        let defaults = SharedModelContainer.appGroupDefaults
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: payloadKey)
            defaults.set(now, forKey: generatedAtKey)
        }
    }

    static func clear() {
        let defaults = SharedModelContainer.appGroupDefaults
        defaults.removeObject(forKey: payloadKey)
        defaults.removeObject(forKey: generatedAtKey)
    }

    static func generatedAt() -> Date? {
        SharedModelContainer.appGroupDefaults.object(forKey: generatedAtKey) as? Date
    }

    static func entries() -> [CachedNudgeCopy] {
        guard let data = SharedModelContainer.appGroupDefaults.data(forKey: payloadKey),
              let entries = try? JSONDecoder().decode([CachedNudgeCopy].self, from: data)
        else { return [] }
        return entries
    }

    /// Today's generation count (rolls over by day stamp).
    static func generationCountToday(now: Date = Date()) -> Int {
        let defaults = SharedModelContainer.appGroupDefaults
        guard defaults.string(forKey: countDayKey) == dayStamp(now) else { return 0 }
        return defaults.integer(forKey: countKey)
    }

    static func recordGeneration(now: Date = Date()) {
        let defaults = SharedModelContainer.appGroupDefaults
        let count = generationCountToday(now: now) + 1
        defaults.set(dayStamp(now), forKey: countDayKey)
        defaults.set(count, forKey: countKey)
    }

    /// Lines the writer has produced before, newest last, capped — shown
    /// back to it as "do not echo these".
    static let historyKey = "nudge.copy.history"

    static func history() -> [String] {
        SharedModelContainer.appGroupDefaults.stringArray(forKey: historyKey) ?? []
    }

    static func appendHistory(_ bodies: [String]) {
        var list = history() + bodies
        if list.count > NudgeConfig.copyHistoryLimit {
            list.removeFirst(list.count - NudgeConfig.copyHistoryLimit)
        }
        SharedModelContainer.appGroupDefaults.set(list, forKey: historyKey)
    }

    /// The validated body for a candidate, or nil → use the template.
    ///
    /// Lookup prefers an exact (kind, task) entry, then a kind-generic one
    /// (`taskID == nil`). Task-keyed entries are only served while the
    /// named task is still open, unfinished, and carrying the exact
    /// deadline the copy was written against (still ahead of the fire
    /// date) — a three-day-old nudge naming something finished yesterday,
    /// or a "due Friday" for a deadline moved to Monday, is worse than a
    /// generic one. Stale → nil → template.
    static func validBody(
        kind: NudgeOutcomeKind,
        taskID: UUID?,
        fireDate: Date,
        modelContext: ModelContext,
        now: Date = Date()
    ) -> String? {
        guard let generatedAt = generatedAt(),
              now.timeIntervalSince(generatedAt)
                <= Double(NudgeConfig.copyCacheDays) * 24 * 60 * 60,
              generatedAt <= now
        else { return nil }

        let all = entries().filter { $0.kindRaw == kind.rawValue }
        let entry = all.first { $0.taskID != nil && $0.taskID == taskID?.uuidString }
            ?? all.first { $0.taskID == nil }
        guard let entry else { return nil }

        // Kind-generic copy names nothing, so nothing can go stale on it.
        guard let idString = entry.taskID, let id = UUID(uuidString: idString) else {
            return entry.body
        }

        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let task = (try? modelContext.fetch(descriptor))?.first,
              !task.isComplete
        else { return nil }

        // The same effective-deadline instant generation used: an event's
        // start time, else a dated task's end-of-day deadline.
        let currentDue = task.specificTime
            ?? (task.dueDate != nil ? task.sortDeadline : nil)
        if let writtenDue = entry.dueAtGeneration {
            // Same deadline (to the minute), and it hasn't passed by the
            // time this notification fires.
            guard let currentDue,
                  abs(currentDue.timeIntervalSince(writtenDue)) < 60,
                  currentDue > fireDate
            else { return nil }
        } else {
            // Copy written for an undated task ("no deadline" phrasing);
            // a deadline added since makes it wrong.
            guard currentDue == nil else { return nil }
        }
        return entry.body
    }

    static func dayStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    #if DEBUG
    static func debugDump(now: Date = Date()) {
        let stampText = generatedAt().map { "\($0)" } ?? "never"
        print("[NudgeCopyStore] generations today: \(generationCountToday(now: now)) — cache generated \(stampText):")
        let all = entries()
        if all.isEmpty {
            print("  (empty — every nudge uses its deterministic template)")
        }
        for entry in all {
            let task = entry.taskTitle ?? "(kind-generic)"
            print("  • \(entry.kindRaw) / \(task): \"\(entry.body)\"")
        }
    }
    #endif
}

// MARK: - Generator

/// Decides WHEN to regenerate and builds the one batched request. Never
/// called from the arbiter — triggers are the new-day hook in `ContentView`
/// and real data shifts (`ExamPrepSweep` creating work, a calendar import).
@MainActor
final class NudgeCopyGenerator {

    static let shared = NudgeCopyGenerator()
    private init() {}

    /// Why a generation pass is being requested. `newDay` is the once-a-day
    /// baseline; the others are real shifts in what the day is about.
    enum Trigger: String {
        case newDay
        case generatedWork   // ExamPrepSweep created study/commitment tasks
        case calendarImport  // new events entered the store
    }

    /// Day marker for the once-per-day baseline run — same idiom as
    /// `DayPlanEngine`'s `nudge.autoPlan.lastRunDay`.
    static let lastRunDayKey = "nudge.copyGen.lastRunDay"
    /// Last attempt (success or failure), for the min-interval throttle —
    /// collapses duplicate triggers in one launch sequence and stops a
    /// flaky network from turning every foreground into an API call.
    static let lastAttemptKey = "nudge.copyGen.lastAttempt"
    #if DEBUG
    private static var forcedThisLaunch = false
    #endif

    /// Runs a generation pass if the trigger warrants one. Returns true if
    /// new copy was cached (callers should reevaluate the arbiter so it
    /// gets scheduled).
    func generateIfNeeded(
        trigger: Trigger,
        modelContext: ModelContext,
        now: Date = Date()
    ) async -> Bool {
        let defaults = SharedModelContainer.appGroupDefaults
        let today = NudgeCopyStore.dayStamp(now)

        #if DEBUG
        // `-nudge-regenerate-copy`: one forced pass this launch, for
        // reading a prompt change on the phone the same day.
        let forced = ProcessInfo.processInfo.arguments.contains("-nudge-regenerate-copy")
            && !Self.forcedThisLaunch
        if forced { Self.forcedThisLaunch = true }
        #else
        let forced = false
        #endif
        if trigger == .newDay, !forced,
           defaults.string(forKey: Self.lastRunDayKey) == today {
            return false
        }
        if !forced,
           let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date,
           now.timeIntervalSince(lastAttempt)
            < Double(NudgeConfig.copyGenMinMinutesBetween) * 60,
           now >= lastAttempt {
            #if DEBUG
            print("[NudgeCopyGenerator] SKIP (\(trigger.rawValue)) — last attempt \(Int(now.timeIntervalSince(lastAttempt) / 60))m ago, min interval \(NudgeConfig.copyGenMinMinutesBetween)m.")
            #endif
            return false
        }
        // Safety cap — the DEBUG printout is the real watchdog ("more than
        // a few times a day means the triggers are too loose"); this stops
        // a runaway trigger from becoming a bill before anyone reads it.
        guard NudgeCopyStore.generationCountToday(now: now)
                < NudgeConfig.copyGenMaxPerDay else {
            #if DEBUG
            print("[NudgeCopyGenerator] SKIP (\(trigger.rawValue)) — daily cap of \(NudgeConfig.copyGenMaxPerDay) generations reached. If this happens the triggers are too loose.")
            #endif
            return false
        }

        let requests = Self.buildRequests(modelContext: modelContext, now: now)
        guard !requests.isEmpty else {
            // Nothing worth writing about (empty list). Stamp the day so
            // the baseline doesn't retry all day against the same nothing.
            defaults.set(today, forKey: Self.lastRunDayKey)
            return false
        }

        defaults.set(now, forKey: Self.lastAttemptKey)
        let firstName = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first?.name
            .split(separator: " ").first.map(String.init)
        do {
            let bodies = try await ClaudeService.shared.generateNudgeCopy(
                requests: requests,
                userName: firstName,
                recentBodies: NudgeCopyStore.history()
            )
            let entries = requests.compactMap { request -> CachedNudgeCopy? in
                guard let body = bodies[request.index] else { return nil }
                return CachedNudgeCopy(
                    kindRaw: request.kind.rawValue,
                    taskID: request.taskID?.uuidString,
                    taskTitle: request.taskTitle,
                    dueAtGeneration: request.dueAtGeneration,
                    body: body
                )
            }
            NudgeCopyStore.save(entries: entries, now: now)
            NudgeCopyStore.recordGeneration(now: now)
            NudgeCopyStore.appendHistory(entries.map(\.body))
            defaults.set(today, forKey: Self.lastRunDayKey)
            #if DEBUG
            print("[NudgeCopyGenerator] Generated \(entries.count) entr(y/ies) for trigger \(trigger.rawValue).")
            NudgeCopyStore.debugDump(now: now)
            #endif
            return true
        } catch {
            // Copy is an enhancement, never a dependency — a failed pass
            // leaves whatever cache exists (or none) and the templates
            // cover everything. The attempt stamp above throttles retries.
            #if DEBUG
            print("[NudgeCopyGenerator] Generation failed (\(trigger.rawValue)): \(error). Templates cover everything.")
            #endif
            return false
        }
    }

    /// Fire-and-forget shift entry point for synchronous call sites
    /// (`ExamPrepSweep`). Spawns the async pass and reevaluates the arbiter
    /// if new copy landed.
    func noteShift(_ trigger: Trigger, modelContext: ModelContext) {
        Task { @MainActor in
            let generated = await generateIfNeeded(trigger: trigger, modelContext: modelContext)
            guard generated,
                  let profile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first
            else { return }
            NudgeArbiter.shared.reevaluate(
                reason: .taskCreatedOrEdited,
                profile: profile,
                modelContext: modelContext
            )
        }
    }

    // MARK: Request building

    struct NudgeCopyRequest {
        let index: Int
        let kind: NudgeOutcomeKind
        let taskID: UUID?
        let taskTitle: String?
        /// Absolute phrasing for the prompt ("due Friday, Aug 7 at 5:00 PM")
        /// — context only; the writer uses {day}/{time} placeholders.
        let dueDescription: String?
        let dueAtGeneration: Date?
        /// Which placeholders are fillable for this item ("{task} {time}
        /// {day}"), so the writer never reaches for one the fill cannot
        /// resolve.
        let placeholders: String
    }

    /// What gets written each pass: per-task lines for the kinds that name
    /// a task or event, capped at `NudgeConfig.copyGenTasksPerKind` each
    /// (spacing caps a day at ~10 nudges across ALL kinds), and one
    /// kind-generic line for the kinds that name nothing.
    static func buildRequests(
        modelContext: ModelContext,
        now: Date = Date()
    ) -> [NudgeCopyRequest] {
        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete }
        )
        descriptor.fetchLimit = 80
        let all = (try? modelContext.fetch(descriptor)) ?? []
        let open = all.filter { !$0.isInformationalEvent }
        let events = all.filter { $0.isInformationalEvent }
        let cap = NudgeConfig.copyGenTasksPerKind
        let calendar = Calendar.current
        let horizon = calendar.date(byAdding: .day, value: NudgeConfig.copyCacheDays + 2, to: now) ?? now

        var requests: [NudgeCopyRequest] = []
        func add(kind: NudgeOutcomeKind, task: NudgeTask?, placeholders: String) {
            requests.append(NudgeCopyRequest(
                index: requests.count,
                kind: kind,
                taskID: task?.id,
                taskTitle: task?.title,
                dueDescription: task.flatMap { dueDescription(for: $0, now: now) },
                // The effective-deadline instant `validBody` re-checks at
                // scheduling: event start time, else end-of-day deadline.
                dueAtGeneration: task.flatMap {
                    $0.specificTime ?? ($0.dueDate != nil ? $0.sortDeadline : nil)
                },
                placeholders: placeholders
            ))
        }
        func dated(_ t: NudgeTask) -> Bool { t.dueDate != nil || t.specificTime != nil }
        func datedPlaceholders(_ t: NudgeTask) -> String {
            dated(t) ? "{task} {day} {time}" : "{task}"
        }

        // Morning prompt: stakes-first, the arbiter's own ranking order
        // (high > medium > never-classified > low), ties to the nearer
        // deadline. Top N covers the no-repeat rotation.
        func stakesRank(_ stakes: TaskStakes?) -> Int {
            switch stakes {
            case .high: return 3
            case .medium: return 2
            case nil: return 1
            case .low: return 0
            }
        }
        let byStakes = open.sorted {
            let (a, b) = (stakesRank($0.stakes), stakesRank($1.stakes))
            if a != b { return a > b }
            return $0.sortDeadline < $1.sortDeadline
        }
        for task in byStakes.prefix(cap) {
            add(kind: .morningPrompt, task: task, placeholders: datedPlaceholders(task))
        }

        // Prep and due-soon: dated tasks whose deadline is still ahead and
        // lands inside the cache window (+ a margin — prep can fire up to
        // the due day).
        let datedAhead = open
            .filter { dated($0) && $0.sortDeadline > now && $0.sortDeadline < horizon }
            .sorted { $0.sortDeadline < $1.sortDeadline }
        for task in datedAhead.prefix(cap) {
            add(kind: .prep, task: task, placeholders: "{task} {day} {time}")
        }
        for task in datedAhead.prefix(cap) {
            add(kind: .dueSoon, task: task, placeholders: "{task} {day} {time}")
        }

        // Events inside the window: the hour-before heads-up.
        let upcomingEvents = events
            .filter { ($0.specificTime ?? .distantPast) > now && ($0.specificTime ?? .distantFuture) < horizon }
            .sorted { ($0.specificTime ?? .distantFuture) < ($1.specificTime ?? .distantFuture) }
        for event in upcomingEvents.prefix(cap) {
            add(kind: .eventBlock, task: event, placeholders: "{task} {day} {time}")
        }

        // Placed blocks: the heads-up before a slot and the follow-up after
        // one passes. {time} is the slot at delivery, so a replan does not
        // date the line.
        let placed = open
            .filter { $0.plannedStartDate != nil }
            .sorted { ($0.plannedStartDate ?? .distantFuture) < ($1.plannedStartDate ?? .distantFuture) }
        for task in placed.prefix(cap) {
            add(kind: .placementLead, task: task, placeholders: "{task} {time}")
        }
        for task in placed.prefix(cap) {
            add(kind: .placementMissed, task: task, placeholders: "{task} {time}")
        }

        // Floater: open undated tasks, the app's one comparator order
        // (plan-first). The builder collapses to the plan's next item when
        // a plan exists; the comparator puts plan tasks first, so the top
        // of this list contains whatever the builder will pick.
        let comparator = TaskSortComparator()
        let floaters = open
            .filter { !dated($0) }
            .sorted { comparator.compare($0, $1) }
        for task in floaters.prefix(cap) {
            add(kind: .floater, task: task, placeholders: "{task}")
        }

        // Kind-generic lines: the question that names no task, the
        // come-back, and the goal bait ({goal} is filled per goal).
        add(kind: .idle, task: nil, placeholders: "{name}")
        add(kind: .comeBack, task: nil, placeholders: "{name}")
        add(kind: .goalLapse, task: nil, placeholders: "{goal} {name}")

        return requests
    }

    /// Absolute due-phrase for the generation prompt. Weekday inside a
    /// week, month-day beyond; clock time only when the task carries one
    /// (a bare dueDate is a day — rendering its 23:59 would invent
    /// precision, same rule as `morningDeadlinePhrase`).
    private static func dueDescription(for task: NudgeTask, now: Date) -> String? {
        guard let deadline = task.specificTime ?? task.dueDate else {
            return "no deadline"
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: deadline)
        ).day ?? 0

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = days > 6 ? "MMM d" : "EEEE, MMM d"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        var text = "due \(dayFmt.string(from: deadline))"
        if let time = task.specificTime {
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "h:mm a"
            timeFmt.locale = Locale(identifier: "en_US_POSIX")
            text += " at \(timeFmt.string(from: time))"
        }
        return text
    }
}

// MARK: - Placeholder fill (at scheduling, from the candidate's facts)

/// Turns a written line into the delivered one. The writer never sees a
/// clock or a day word; it writes {task}, {time}, {day}, {name}, {goal}
/// and this fills them from the candidate at scheduling time — {day} is
/// relative to the candidate's FIRE date, which is why a line written
/// yesterday says "tomorrow" correctly. A placeholder that cannot be
/// resolved (no anchor, no goal, no name) returns nil → the template.
@MainActor
enum NudgeCopyFill {
    static func fill(
        _ body: String,
        candidate: NudgeCandidate,
        modelContext: ModelContext
    ) -> String? {
        var out = body
        let task = (candidate.namedTaskID ?? candidate.taskID).flatMap { fetchTask($0, modelContext) }

        if out.contains("{task}") {
            guard let task else { return nil }
            out = out.replacingOccurrences(of: "{task}", with: task.title)
        }
        if out.contains("{goal}") {
            guard let goalID = candidate.goalID, let goal = fetchGoal(goalID, modelContext) else { return nil }
            out = out.replacingOccurrences(of: "{goal}", with: goal.title)
        }
        if out.contains("{name}") {
            let name = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first?.name
                .split(separator: " ").first.map(String.init) ?? ""
            guard !name.isEmpty else { return nil }
            out = out.replacingOccurrences(of: "{name}", with: name)
        }
        if out.contains("{time}") || out.contains("{day}") {
            guard let task, let anchor = anchor(for: candidate.kind, task: task) else { return nil }
            out = out.replacingOccurrences(of: "{day}", with: relativeDay(anchor, fireDate: candidate.fireDate))
            out = out.replacingOccurrences(of: "{time}", with: clock(anchor, task: task, kind: candidate.kind))
        }
        // Anything the writer invented is a line we do not send.
        if out.range(of: "\\{[A-Za-z_]+\\}", options: .regularExpression) != nil { return nil }
        return out
    }

    /// The instant a kind's {time}/{day} refer to.
    static func anchor(for kind: NudgeOutcomeKind, task: NudgeTask) -> Date? {
        switch kind {
        case .eventBlock:
            return task.specificTime
        case .dueSoon, .prep, .morningPrompt:
            return task.specificTime ?? (task.dueDate != nil ? task.sortDeadline : nil)
        case .placementLead, .placementMissed:
            return task.plannedStartDate
        default:
            return nil
        }
    }

    static func relativeDay(_ anchor: Date, fireDate: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: fireDate), to: cal.startOfDay(for: anchor)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6:
            let f = DateFormatter(); f.dateFormat = "EEEE"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: anchor)
        default:
            let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: anchor)
        }
    }

    /// A bare due date has no clock of its own (the store's 23:59 is a
    /// convention), so its {time} reads as the end of the day.
    static func clock(_ anchor: Date, task: NudgeTask, kind: NudgeOutcomeKind) -> String {
        let deadlineKind = kind == .dueSoon || kind == .prep || kind == .morningPrompt
        if deadlineKind, task.specificTime == nil { return "the end of the day" }
        let f = DateFormatter(); f.dateFormat = "h:mm a"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: anchor)
    }

    private static func fetchTask(_ id: UUID, _ context: ModelContext) -> NudgeTask? {
        var d = FetchDescriptor<NudgeTask>(predicate: #Predicate<NudgeTask> { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private static func fetchGoal(_ id: UUID, _ context: ModelContext) -> NudgeGoal? {
        var d = FetchDescriptor<NudgeGoal>(predicate: #Predicate<NudgeGoal> { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
