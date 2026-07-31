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
        case placed(count: Int, titles: [String])
        /// Nothing open and unplaced — a correct refusal.
        case noCandidates
        /// Candidates exist but no free gap fits any of them.
        case noRoom
        /// No planning window (late night, or a sleep window shorter than
        /// its quiet buffers). Backstop — `DayWindow`'s wake anchor makes
        /// the all-day version impossible on sane profiles.
        case windowCollapsed
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

        for task in tasks where task.isInformationalEvent == false {
            guard let p = task.plannedStartDate, cal.isDateInToday(p) else { continue }
            let mins = task.plannedDurationMinutes ?? planningMinutes(for: task)
            busy.append((p, p.addingTimeInterval(Double(mins) * 60)))
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
        let openUnplaced = tasks.filter {
            !$0.isComplete && !$0.isInformationalEvent && $0.plannedStartDate == nil
        }
        let planCandidates = openUnplaced
            .filter { $0.sequenceIndex != nil }
            .sorted { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }
        let scoredCandidates = openUnplaced
            .filter { $0.sequenceIndex == nil }
            .sorted { planScore(for: $0, modelContext: modelContext) > planScore(for: $1, modelContext: modelContext) }
        let candidates = planCandidates + scoredCandidates

        #if DEBUG
        print("   candidates (open, non-event, unplaced) — \(candidates.count):")
        for task in planCandidates {
            print("      • \(task.title) — plan #\(task.sequenceIndex ?? 0), \(planningMinutes(for: task))m")
        }
        for task in scoredCandidates {
            let score = String(format: "%.2f", planScore(for: task, modelContext: modelContext))
            let prep = task.source == "prep" ? " [prep]" : ""
            print("      • \(task.title) — score \(score), \(planningMinutes(for: task))m\(prep)")
        }
        for task in tasks where !task.isInformationalEvent && !candidates.contains(where: { $0.id == task.id }) {
            let reason: String
            if task.isComplete {
                reason = "complete"
            } else if let p = task.plannedStartDate {
                reason = "already placed \(p.formatted(date: .abbreviated, time: .shortened)) (\(task.plannedIsAuto ? "auto" : "manual"))"
            } else {
                reason = "unexpected — open, unplaced, yet not a candidate"
            }
            print("      ◦ excluded: \(task.title) — \(reason)")
        }
        #endif

        let spacing: TimeInterval = 15 * 60
        var placedCount = 0
        var prepPlacedCount = 0
        var placedTitles: [String] = []

        for task in candidates {
            guard placedCount < NudgeConfig.planMaxPlacementsPerRun else {
                #if DEBUG
                print("   cap reached (\(NudgeConfig.planMaxPlacementsPerRun) placed) — remaining candidates not attempted")
                #endif
                break
            }
            // Prep cap: study blocks may claim at most
            // `planMaxPrepPlacementsPerRun` of the run's slots, so a week
            // of prep tasks can't turn the whole proposed day into a
            // monoculture. Caps placement only — the tasks stay listed.
            let isPrep = task.source == "prep"
            if isPrep, prepPlacedCount >= NudgeConfig.planMaxPrepPlacementsPerRun {
                #if DEBUG
                print("   ✗ \(task.title) — prep cap (\(NudgeConfig.planMaxPrepPlacementsPerRun)) reached, not placed")
                #endif
                continue
            }
            let duration = TimeInterval(planningMinutes(for: task) * 60)
            guard let start = earliestGapStart(
                fitting: duration,
                busy: busy,
                from: scanStart,
                to: dayEnd
            ) else {
                #if DEBUG
                print("   ✗ \(task.title) (\(Int(duration / 60))m) — no gap fits")
                #endif
                continue
            }

            #if DEBUG
            print("   ✓ \(task.title) (\(Int(duration / 60))m) → placed \(traceTime(start))")
            #endif
            task.plannedStartDate = start
            task.plannedDurationMinutes = planningMinutes(for: task)
            task.plannedIsAuto = true
            if isPrep { prepPlacedCount += 1 }
            placedTitles.append(task.title)
            // Occupy this slot + 15 min spacing for the next placement.
            busy.append((start, start.addingTimeInterval(duration + spacing)))
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
            print("   result: placed 0 of \(candidates.count) candidate(s) → \(kind)")
            #endif
            return candidates.isEmpty ? .noCandidates : .noRoom
        }
        #if DEBUG
        print("   result: placed \(placedCount) of \(candidates.count) candidate(s)")
        #endif
        return .placed(count: placedCount, titles: placedTitles)
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
        if case .placed(let count, let titles) = outcome {
            PlanOutcomeContext.write(
                kind: .planned,
                placedCount: count,
                placedTitles: titles,
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
