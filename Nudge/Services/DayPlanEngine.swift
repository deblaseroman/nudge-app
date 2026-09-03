//
//  DayPlanEngine.swift
//  Nudge
//
//  The deterministic Plan-my-day engine, extracted from TasksTabView
//  (cycle 2026-08-02-02) so the morning auto-run can plan without the view.
//

import Foundation
import SwiftData
import WidgetKit

/// Places open tasks into today's free gaps. Deterministic — no AI, no
/// network (`DESIGN.md`: planning is arithmetic). Fills around events
/// (real durations + 1-hour pre-event buffers) and existing placements;
/// **never overwrites a manual placement**.
///
/// Two entry points: `planToday` (the Tasks-tab button — replans by
/// clearing today's AUTO placements first) and `autoPlanIfNewDay` (the
/// first foreground of a calendar day — runs once, never touches an
/// existing plan, announces itself through `PlanOutcomeContext`).
@MainActor
enum DayPlanEngine {

    enum Outcome {
        /// `displaced` names auto placements evicted to make room for a
        /// generated session (cycle 2026-08-03-01 item 4) — empty in the
        /// common case. A displaced task is back in Unscheduled and the
        /// announcement must say so; silently un-placing is the
        /// vanishing-task shape.
        case placed(count: Int, titles: [String], displaced: [String], outOfBand: [BandRefusal])
        /// Nothing open and unplaced — a correct refusal.
        case noCandidates
        /// Candidates exist but no free gap fits any of them.
        /// `contention` carries the generated session that a displacement
        /// WOULD have fit, except every helpful eviction was equal-or-
        /// higher stakes — the app proposes, the user decides, so the
        /// message box names the contention instead of evicting.
        case noRoom(contention: String?, outOfBand: [BandRefusal])
        /// No planning window (late night, or a sleep window shorter than
        /// its quiet buffers). Backstop — `DayWindow`'s wake anchor makes
        /// the all-day version impossible on sane profiles.
        case windowCollapsed
    }

    /// A candidate the pass refused because its appropriateness band had
    /// no usable free time today — either the band's hours are over (or
    /// it's a weekend for `businessHours`), or free gaps exist but only
    /// outside the band. The refusal itself is correct behaviour (cycle
    /// 2026-08-02-03: no "any gap will do"); what was wrong is that it was
    /// silent (cycle 2026-08-04-01 item 1) — the message box now names the
    /// task and the rule instead of letting it read as a dead button.
    struct BandRefusal {
        let title: String
        let band: TaskTimeWindow
    }

    /// Displacement ordering (higher = more consequential). Same
    /// convention as the morning prompt's `morningStakesRank`: nil —
    /// never classified — ranks ABOVE `.low`, because absence of
    /// evidence is not a statement that the item is minor.
    private static func stakesRank(_ stakes: TaskStakes?) -> Int {
        switch stakes {
        case .high:   return 3
        case .medium: return 2
        case nil:     return 1
        case .low:    return 0
        }
    }

    // MARK: - Core planning

    /// Runs one planning pass over today. `clearAutoFirst` makes the pass a
    /// REPLAN: today's auto placements are released back into the candidate
    /// pool before placing (manual placements are never released). Saves on
    /// any mutation; reloads the widget on placement. Callers own haptics,
    /// messaging, and the arbiter reevaluate.
    @discardableResult
    static func planToday(
        profile: UserProfile,
        modelContext: ModelContext,
        clearAutoFirst: Bool = false
    ) -> Outcome {
        let cal = Calendar.current
        let tasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>())) ?? []

        // Day window: one shared derivation (`DayWindow`) — wake-anchored,
        // so a past-midnight bedtime extends today instead of collapsing
        // the window into yesterday.
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        #if DEBUG
        print("🧭 [PlanMyDay] invoked \(traceTime(Date()))\(clearAutoFirst ? " (replan)" : "")")
        #endif
        guard let window = DayWindow.resolve(on: Date(), wake: wake, bedtime: profile.bedtime) else {
            #if DEBUG
            print("   ❌ WINDOW UNRESOLVABLE — sleep window shorter than its quiet buffers (misconfigured profile). Nothing placed.")
            #endif
            return .windowCollapsed
        }
        let dayStart = window.start
        let dayEnd = window.end
        // Don't place in the past.
        let scanStart = max(dayStart, Date())
        #if DEBUG
        print("   window: wake+30 \(traceTime(dayStart)) → bed−60 \(traceTime(dayEnd)), scan from \(traceTime(scanStart))")
        #endif
        guard dayEnd > scanStart else {
            #if DEBUG
            print("   ❌ DAY ALREADY OVER — now is past bed−60; nothing left to place today. (Backstop guard;")
            print("      with the wake-anchored window this happens only late at night, never all day.)")
            #endif
            return .windowCollapsed
        }

        // Replan: release today's AUTO placements back into the pool. Done
        // AFTER the window guards so a late-night tap can't strip a day's
        // plan and then place nothing.
        if clearAutoFirst {
            var released = 0
            for task in tasks {
                guard task.plannedIsAuto, let p = task.plannedStartDate,
                      cal.isDateInToday(p) else { continue }
                task.plannedStartDate = nil
                task.plannedDurationMinutes = nil
                task.plannedIsAuto = false
                released += 1
            }
            #if DEBUG
            if released > 0 { print("   replan: released \(released) auto placement(s) back into the pool") }
            #endif
        }

        // Occupied intervals: event busy windows (already include 15-min tail
        // + merges) plus any existing placements (auto or manual) so we fill
        // around them and never overwrite.
        var busy: [(start: Date, end: Date)] = BusyWindowResolver.shared
            .busyWindows(from: dayStart, to: dayEnd, modelContext: modelContext)
            .map { ($0.start, $0.end) }

        // AUTO placements' intervals, tracked by task so displacement (item
        // 4, cycle 2026-08-03-01) can simulate an eviction by removing
        // exactly the interval it added. Manual placements and events are
        // deliberately never tracked — they are never displaced.
        var autoPlacedIntervals: [UUID: (start: Date, end: Date)] = [:]

        for task in tasks where task.isInformationalEvent == false {
            guard let p = task.plannedStartDate, cal.isDateInToday(p) else { continue }
            let mins = task.plannedDurationMinutes ?? planningMinutes(for: task)
            let interval = (p, p.addingTimeInterval(Double(mins) * 60))
            busy.append(interval)
            if task.plannedIsAuto {
                autoPlacedIntervals[task.id] = interval
            }
        }

        // "Get ready" buffer: block the hour BEFORE each event. We can't know
        // how long the user needs to prep/travel, so leave the hour before an
        // event free rather than scheduling work right up against it.
        let preEventBuffer: TimeInterval = 60 * 60
        for event in tasks where event.isInformationalEvent {
            guard let start = event.specificTime, cal.isDateInToday(start) else { continue }
            busy.append((start.addingTimeInterval(-preEventBuffer), start))
        }

        #if DEBUG
        debugPrintBusyAndGaps(busy: busy, scanStart: scanStart, dayEnd: dayEnd)
        #endif

        // Candidates: open, non-event, not already placed. Ranked by score.
        // Plan tasks go first, in the user's stated sequenceIndex order
        // (their order outranks Eisenhower score); non-plan tasks follow,
        // by score. A placed plan task keeps its number in Today's plan AND
        // shows on the timeline.
        //
        // A generated daily task — exam prep (cycle 2026-08-02-03) or a
        // commitment daily (cycle 2026-08-03-01) — is a candidate ONLY on
        // its own day: the sweep already spread the work across days, and
        // letting tomorrow's block win today's gaps un-spreads it. These
        // are the sources whose dates ARE the plan; ordinary dated tasks
        // stay eligible early on purpose — working ahead of a deadline is
        // the point of planning.
        let openUnplaced = tasks.filter { task in
            guard !task.isComplete, !task.isInformationalEvent,
                  task.plannedStartDate == nil else { return false }
            if task.source == "prep" || task.source == "commitment" {
                guard let due = task.dueDate, cal.isDateInToday(due) else { return false }
            }
            return true
        }
        let planCandidates = openUnplaced
            .filter { $0.sequenceIndex != nil }
            .sorted { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }
        // Tasks the user said they'd do TODAY (intendedDate, cycle
        // 2026-09-03-01) outrank score — the user already decided the day;
        // the planner's job is placing it, not re-deciding it. After plan
        // tasks (a stated order is the stronger claim), before score-ranked
        // fill. Oldest first within the group — no better signal exists,
        // and score would re-litigate the decision this group exists to
        // honor.
        let intentCandidates = openUnplaced
            .filter { task in
                task.sequenceIndex == nil
                    && (task.intendedDate.map { cal.isDateInToday($0) } ?? false)
            }
            .sorted { $0.createdAt < $1.createdAt }
        let intentIDs = Set(intentCandidates.map(\.id))
        let scoredCandidates = openUnplaced
            .filter { $0.sequenceIndex == nil && !intentIDs.contains($0.id) }
            .sorted { planScore(for: $0, modelContext: modelContext) > planScore(for: $1, modelContext: modelContext) }
        let candidates = planCandidates + intentCandidates + scoredCandidates

        #if DEBUG
        print("   candidates (open, non-event, unplaced) — \(candidates.count):")
        for task in planCandidates {
            print("      • \(task.title) — plan #\(task.sequenceIndex ?? 0), \(planningMinutes(for: task))m [\(task.effectiveTimeWindow.rawValue)]")
        }
        for task in intentCandidates {
            print("      • \(task.title) — intended today, \(planningMinutes(for: task))m [\(task.effectiveTimeWindow.rawValue)]")
        }
        for task in scoredCandidates {
            let score = String(format: "%.2f", planScore(for: task, modelContext: modelContext))
            let prep = task.source == "prep" ? " [prep]" : ""
            print("      • \(task.title) — score \(score), \(planningMinutes(for: task))m\(prep) [\(task.effectiveTimeWindow.rawValue)]")
        }
        for task in tasks where !task.isInformationalEvent && !candidates.contains(where: { $0.id == task.id }) {
            let reason: String
            if task.isComplete {
                reason = "complete"
            } else if let p = task.plannedStartDate {
                reason = "already placed \(p.formatted(date: .abbreviated, time: .shortened)) (\(task.plannedIsAuto ? "auto" : "manual"))"
            } else if task.source == "prep" || task.source == "commitment" {
                let day = task.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? "undated"
                reason = "generated for another day (due \(day)) — places only on its own day"
            } else {
                reason = "unexpected — open, unplaced, yet not a candidate"
            }
            print("      ◦ excluded: \(task.title) — \(reason)")
        }
        #endif

        // Placement bounds for a task's appropriateness band, intersected
        // with today's scan window. Nil = the band has no time left today
        // (or none at all — businessHours on a weekend); the task is left
        // UNPLACED rather than placed at a time that makes it undoable.
        func bandBounds(for band: TaskTimeWindow) -> (from: Date, to: Date)? {
            func todayAt(_ hour: Int) -> Date? {
                cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
            }
            switch band {
            case .anytime:
                return (scanStart, dayEnd)
            case .daytime:
                guard let s = todayAt(NudgeConfig.daytimeStartHour),
                      let e = todayAt(NudgeConfig.daytimeEndHour) else { return (scanStart, dayEnd) }
                let from = max(scanStart, s), to = min(dayEnd, e)
                return from < to ? (from, to) : nil
            case .businessHours:
                guard !cal.isDateInWeekend(Date()) else { return nil }
                guard let s = todayAt(NudgeConfig.businessHoursStartHour),
                      let e = todayAt(NudgeConfig.businessHoursEndHour) else { return (scanStart, dayEnd) }
                let from = max(scanStart, s), to = min(dayEnd, e)
                return from < to ? (from, to) : nil
            }
        }

        let spacing: TimeInterval = 15 * 60
        var placedCount = 0
        var prepPlacedCount = 0
        var placedTitles: [String] = []
        var displacedTitles: [String] = []
        var bandRefusals: [BandRefusal] = []
        var contentionTitle: String?
        // At most ONE displacement per run — a planner that reshuffles the
        // whole day to wedge everything in stops reading as a proposal.
        var displacementUsed = false

        // Displacement (item 4): a generated session found no in-band gap.
        // Evict an AUTO placement only when that actually helps — removing
        // it must open a gap the session genuinely fits (two 45-minute
        // gaps around a small task don't become a 2-hour slot), and it
        // must be STRICTLY lower stakes than the session. Helpful-but-
        // equal candidates displace nothing; the contention is reported so
        // the user decides. Returns the new start and the evicted task.
        func attemptDisplacement(
            for session: NudgeTask,
            duration: TimeInterval,
            bounds: (from: Date, to: Date)
        ) -> (start: Date, evicted: NudgeTask)? {
            let sessionRank = stakesRank(session.stakes)
            var helpful: [(task: NudgeTask, interval: (start: Date, end: Date))] = []
            for (id, interval) in autoPlacedIntervals {
                guard let candidate = tasks.first(where: { $0.id == id }),
                      candidate.plannedIsAuto,
                      candidate.plannedStartDate != nil,
                      candidate.id != session.id else { continue }
                let busyWithout = busy.filter {
                    $0.start != interval.start || $0.end != interval.end
                }
                if earliestGapStart(
                    fitting: duration, busy: busyWithout,
                    from: bounds.from, to: bounds.to
                ) != nil {
                    helpful.append((candidate, interval))
                }
            }
            #if DEBUG
            if !helpful.isEmpty {
                print("   displacement check for \(session.title) (stakes rank \(sessionRank)):")
                for entry in helpful {
                    print("      · evicting \"\(entry.task.title)\" (rank \(stakesRank(entry.task.stakes))) would fit it")
                }
            }
            #endif
            let lower = helpful.filter { stakesRank($0.task.stakes) < sessionRank }
            guard let evict = lower.min(by: { lhs, rhs in
                let lr = stakesRank(lhs.task.stakes), rr = stakesRank(rhs.task.stakes)
                if lr != rr { return lr < rr }
                // Same rank: disturb the later part of the day.
                return (lhs.task.plannedStartDate ?? .distantPast)
                     > (rhs.task.plannedStartDate ?? .distantPast)
            }) else {
                if !helpful.isEmpty, contentionTitle == nil {
                    // Equal-stakes contention: displace nothing, say so.
                    contentionTitle = session.title
                }
                return nil
            }

            // A displaced task returns to Unscheduled — visible and
            // re-placeable, never silently moved to another day.
            evict.task.plannedStartDate = nil
            evict.task.plannedDurationMinutes = nil
            evict.task.plannedIsAuto = false
            busy.removeAll {
                $0.start == evict.interval.start && $0.end == evict.interval.end
            }
            autoPlacedIntervals.removeValue(forKey: evict.task.id)
            // If the evictee was placed by THIS run, unwind its counters.
            if let index = placedTitles.firstIndex(of: evict.task.title) {
                placedTitles.remove(at: index)
                placedCount -= 1
                if evict.task.source == "prep" || evict.task.source == "commitment" {
                    prepPlacedCount -= 1
                }
            }
            displacedTitles.append(evict.task.title)
            displacementUsed = true

            guard let start = earliestGapStart(
                fitting: duration, busy: busy, from: bounds.from, to: bounds.to
            ) else {
                // Can't happen — the helpful test just verified the fit
                // against the same intervals — but never leave an eviction
                // unexplained if it somehow does.
                return nil
            }
            return (start, evict.task)
        }

        for task in candidates {
            guard placedCount < NudgeConfig.planMaxPlacementsPerRun else {
                #if DEBUG
                print("   cap reached (\(NudgeConfig.planMaxPlacementsPerRun) placed) — remaining candidates not attempted")
                #endif
                break
            }
            // Generated-task cap: study blocks and commitment sessions may
            // claim at most `planMaxPrepPlacementsPerRun` of the run's
            // slots, so generated dailies can't turn the whole proposed
            // day into a monoculture. Caps placement only — the tasks
            // stay listed.
            let isPrep = task.source == "prep" || task.source == "commitment"
            if isPrep, prepPlacedCount >= NudgeConfig.planMaxPrepPlacementsPerRun {
                #if DEBUG
                print("   ✗ \(task.title) — prep cap (\(NudgeConfig.planMaxPrepPlacementsPerRun)) reached, not placed")
                #endif
                continue
            }
            let duration = TimeInterval(planningMinutes(for: task) * 60)
            // Appropriateness band (cycle 2026-08-02-03): placement is
            // constrained to the band's hours; no in-band gap ⇒ unplaced,
            // never "any gap will do" — that's how Call Grandma landed at
            // 10:30 PM.
            let band = task.effectiveTimeWindow
            guard let bounds = bandBounds(for: band) else {
                // Only restricted bands can land here — `.anytime`'s
                // bounds are never nil — so every entry is a real rule
                // refusal worth narrating.
                bandRefusals.append(BandRefusal(title: task.title, band: band))
                #if DEBUG
                print("   ✗ \(task.title) [\(band.rawValue)] — band has no time left today; left unplaced")
                #endif
                continue
            }
            var start = earliestGapStart(
                fitting: duration,
                busy: busy,
                from: bounds.from,
                to: bounds.to
            )
            var displacedFor: NudgeTask?
            // Only a GENERATED session may displace: its date IS its slot
            // — today is the one day it exists for — where an ordinary
            // task can simply wait for tomorrow's gaps.
            if start == nil, isPrep, !displacementUsed,
               let result = attemptDisplacement(for: task, duration: duration, bounds: bounds) {
                start = result.start
                displacedFor = result.evicted
            }
            guard let start else {
                // "The day is full" vs "only out-of-band room remains" —
                // formerly a DEBUG-only distinction; the second kind now
                // feeds the message box, because to the user it looks
                // identical to a bug ("there's free space right there and
                // it won't use it") until the rule is named.
                if band != .anytime,
                   earliestGapStart(fitting: duration, busy: busy, from: scanStart, to: dayEnd) != nil {
                    bandRefusals.append(BandRefusal(title: task.title, band: band))
                    #if DEBUG
                    print("   ✗ \(task.title) (\(Int(duration / 60))m) [\(band.rawValue)] — gaps exist but only OUT-OF-BAND; left unplaced")
                    #endif
                } else {
                    #if DEBUG
                    print("   ✗ \(task.title) (\(Int(duration / 60))m) [\(band.rawValue)] — no gap fits")
                    #endif
                }
                continue
            }

            #if DEBUG
            if let displacedFor {
                print("   ✓ \(task.title) (\(Int(duration / 60))m) [\(band.rawValue)] → placed \(traceTime(start)) "
                    + "by DISPLACING \"\(displacedFor.title)\" back to Unscheduled")
            } else {
                print("   ✓ \(task.title) (\(Int(duration / 60))m) [\(band.rawValue)] → placed \(traceTime(start))")
            }
            #endif
            task.plannedStartDate = start
            task.plannedDurationMinutes = planningMinutes(for: task)
            task.plannedIsAuto = true
            if isPrep { prepPlacedCount += 1 }
            placedTitles.append(task.title)
            // Occupy this slot + 15 min spacing for the next placement.
            let interval = (start, start.addingTimeInterval(duration + spacing))
            busy.append(interval)
            autoPlacedIntervals[task.id] = interval
            placedCount += 1
        }

        // A replan may have released placements even when nothing new fit —
        // persist any mutation.
        if clearAutoFirst || placedCount > 0 {
            try? modelContext.save()
            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        }

        guard placedCount > 0 else {
            #if DEBUG
            let kind = candidates.isEmpty ? "no candidates" : "no room"
            print("   result: placed 0 of \(candidates.count) candidate(s) → \(kind)"
                + (contentionTitle.map { " (equal-stakes contention over \"\($0)\")" } ?? ""))
            #endif
            return candidates.isEmpty
                ? .noCandidates
                : .noRoom(contention: contentionTitle, outOfBand: bandRefusals)
        }
        #if DEBUG
        print("   result: placed \(placedCount) of \(candidates.count) candidate(s)"
            + (displacedTitles.isEmpty ? "" : ", displaced \(displacedTitles.count)")
            + (bandRefusals.isEmpty ? "" : ", band-refused \(bandRefusals.count)"))
        #endif
        return .placed(
            count: placedCount, titles: placedTitles,
            displaced: displacedTitles, outOfBand: bandRefusals
        )
    }

    // MARK: - Morning auto-run

    /// Day the auto-plan last ran (App Group; start-of-day Date).
    static let autoPlanLastRunDayKey = "nudge.autoPlan.lastRunDay"

    /// Plans the day automatically on the FIRST foreground of a calendar
    /// day. iOS won't reliably run a suspended app at a chosen hour, so the
    /// hook is foregrounding — the morning prompt (wake+30) brings the user
    /// in, and the plan is ready by the time they look.
    ///
    /// Guards, in order: once per day (App Group day marker, stamped even
    /// when nothing places — one attempt per day, not one success); never
    /// replaces an existing plan (any auto placement already on today means
    /// a plan exists — do nothing, the user can replan by hand); never
    /// touches manual placements (`clearAutoFirst: false`, and the engine
    /// plans around them). A placement announces itself through
    /// `PlanOutcomeContext` (`.planned`, isAuto) — an unrequested change to
    /// the user's day must explain itself; a refusal writes nothing,
    /// because narrating "I did nothing" every quiet morning is noise.
    ///
    /// Returns the outcome when a pass actually ran, nil when skipped.
    @discardableResult
    static func autoPlanIfNewDay(
        profile: UserProfile,
        modelContext: ModelContext,
        now: Date = Date()
    ) -> Outcome? {
        let defaults = SharedModelContainer.appGroupDefaults
        if let lastRun = defaults.object(forKey: autoPlanLastRunDayKey) as? Date,
           Calendar.current.isDate(lastRun, inSameDayAs: now) {
            return nil
        }

        let tasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>())) ?? []
        let hasAutoPlanToday = tasks.contains { task in
            task.plannedIsAuto && (task.plannedStartDate.map { Calendar.current.isDateInToday($0) } ?? false)
        }
        if hasAutoPlanToday {
            #if DEBUG
            print("🧭 [AutoPlan] skipped — today already has auto placements (never replace an existing plan)")
            #endif
            defaults.set(Calendar.current.startOfDay(for: now), forKey: autoPlanLastRunDayKey)
            return nil
        }

        #if DEBUG
        print("🧭 [AutoPlan] first foreground of \(now.formatted(date: .abbreviated, time: .omitted)) — planning")
        #endif
        defaults.set(Calendar.current.startOfDay(for: now), forKey: autoPlanLastRunDayKey)

        let outcome = planToday(profile: profile, modelContext: modelContext, clearAutoFirst: false)
        if case .placed(let count, let titles, let displaced, let outOfBand) = outcome {
            PlanOutcomeContext.write(
                kind: .planned,
                placedCount: count,
                placedTitles: titles,
                displacedTitles: displaced,
                outOfBandTitles: outOfBand.map(\.title),
                outOfBandBands: outOfBand.map(\.band.rawValue),
                isAuto: true
            )
        }
        return outcome
    }

    // MARK: - Scoring helpers

    /// Effort minutes used for planning: explicit estimate, else the
    /// per-category prior, else 30.
    static func planningMinutes(for task: NudgeTask) -> Int {
        if let e = task.estimatedMinutes, e > 0 { return e }
        if let c = task.taskCategory { return NudgeConfig.categoryEffortPriors[c] ?? 30 }
        return 30
    }

    /// Deterministic Eisenhower score for ranking candidates. Reads only
    /// cached intelligence (no API).
    private static func planScore(for task: NudgeTask, modelContext: ModelContext) -> Double {
        let est = planningMinutes(for: task)
        let signals = NudgeIntelligence.shared.cachedIntelligence(for: task, modelContext: modelContext)
        let isDeep = StartByPlanner.isDeepWork(category: task.taskCategory, effortMinutes: est)
        let importance = EisenhowerScorer.importance(
            category: task.taskCategory,
            isDeepWork: isDeep,
            statedUrgency: signals.statedUrgency,
            hasDependencies: task.dependsOnTaskId != nil
        )
        let urgency: Double
        if let deadline = task.specificTime ?? task.dueDate {
            urgency = EisenhowerScorer.urgency(
                hoursUntilDue: deadline.timeIntervalSince(Date()) / 3600,
                effortHoursRemaining: Double(est) / 60.0
            )
        } else {
            urgency = 0.6
        }
        return EisenhowerScorer.score(urgency: urgency, importance: importance)
    }

    /// Earliest start ≥ `from` where `duration` fits before the next busy
    /// interval (or `to`). Snaps to the next 15-min boundary when it still
    /// fits. Returns nil if nothing fits.
    private static func earliestGapStart(
        fitting duration: TimeInterval,
        busy: [(start: Date, end: Date)],
        from: Date,
        to: Date
    ) -> Date? {
        let sorted = busy.sorted { $0.start < $1.start }
        var cursor = from
        func snapped(_ d: Date) -> Date {
            let ti = d.timeIntervalSinceReferenceDate
            return Date(timeIntervalSinceReferenceDate: (ti / 900).rounded(.up) * 900)
        }
        for interval in sorted {
            if interval.start > cursor {
                let candidate = snapped(cursor)
                if candidate.addingTimeInterval(duration) <= interval.start {
                    return candidate
                }
            }
            cursor = max(cursor, interval.end)
        }
        let candidate = snapped(cursor)
        if candidate.addingTimeInterval(duration) <= to {
            return candidate
        }
        return nil
    }

    // MARK: - DEBUG trace

    #if DEBUG
    /// Diagnosis trace (cycle 2026-08-02-01, read-only). Dates included
    /// deliberately: the trace line that exposed the window bug read
    /// "11:30 PM" and the entire question was WHICH DAY that was.
    private nonisolated static func traceTime(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    /// Prints the merged busy intervals and the free gaps the pass will
    /// scan, so a zero-placement run shows WHY. Merge logic mirrors the
    /// resolver's overlap rule but exists only for this printout.
    private static func debugPrintBusyAndGaps(
        busy: [(start: Date, end: Date)],
        scanStart: Date,
        dayEnd: Date
    ) {
        let sorted = busy.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        print("   busy — \(busy.count) raw interval(s) (event durations + placements + 1h pre-event buffers), \(merged.count) merged:")
        for w in merged {
            print("      • \(traceTime(w.start))–\(traceTime(w.end))")
        }
        var gaps: [(start: Date, end: Date)] = []
        var cursor = scanStart
        for w in merged {
            if w.start > cursor { gaps.append((cursor, min(w.start, dayEnd))) }
            cursor = max(cursor, w.end)
            if cursor >= dayEnd { break }
        }
        if cursor < dayEnd { gaps.append((cursor, dayEnd)) }
        let real = gaps.filter { $0.end > $0.start }
        print("   free gaps in scan window:")
        if real.isEmpty { print("      (none — nothing can place regardless of candidates)") }
        for g in real {
            print("      • \(traceTime(g.start))–\(traceTime(g.end)) (\(Int(g.end.timeIntervalSince(g.start) / 60))m)")
        }
    }
    #endif
}
