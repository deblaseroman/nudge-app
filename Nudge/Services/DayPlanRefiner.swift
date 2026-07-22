//
//  DayPlanRefiner.swift
//  Nudge
//
//  AI layer over the deterministic Plan-my-day. Builds a JSON summary of
//  today (events, free gaps, top open tasks), sends ONE Haiku call through
//  ClaudeService.refineDayPlan, then applies the returned placements the
//  same way the deterministic planner does — only sets plannedStartDate /
//  plannedDurationMinutes / plannedIsAuto. It NEVER schedules notifications;
//  the arbiter reevaluates from data as usual.
//
//  Gated behind isPro || isInTrial. Cached once per day (app-group defaults)
//  — at most one refine call per day unless the caller forces it (an explicit
//  user ask, e.g. a "plan my day" chat message).
//

import Foundation
import SwiftData
import WidgetKit

@MainActor
final class DayPlanRefiner {
    static let shared = DayPlanRefiner()
    private init() {}

    // App-group keys so the rationale/cache survive across tabs and launches.
    private let rationaleKey = "nudge.dayplan.rationale"
    private let rationaleDateKey = "nudge.dayplan.rationaleDate"
    private let refinedDateKey = "nudge.dayplan.refinedDate"

    enum Outcome {
        case success(rationale: String)
        case cached(rationale: String)
        case notEntitled
        case noTasks
        case failed(String)
    }

    /// Today's cached rationale, if one was produced today. Read by the
    /// timeline to show the rationale line.
    func todaysRationale() -> String? {
        let defaults = SharedModelContainer.appGroupDefaults
        guard defaults.string(forKey: rationaleDateKey) == Self.dayKey() else { return nil }
        return defaults.string(forKey: rationaleKey)
    }

    /// Runs the AI refine. `force == false` returns the cached rationale if
    /// we already refined today (no API call). `force == true` (explicit user
    /// ask) always calls.
    func refine(profile: UserProfile, modelContext: ModelContext, force: Bool) async -> Outcome {
        guard profile.isPro || profile.isInTrial else { return .notEntitled }

        let defaults = SharedModelContainer.appGroupDefaults
        if !force,
           defaults.string(forKey: refinedDateKey) == Self.dayKey(),
           let cached = todaysRationale() {
            return .cached(rationale: cached)
        }

        // ── Build the day window ──────────────────────────────────────────
        let cal = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = cal.dateComponents([.hour, .minute], from: wake)
        let bedComps = cal.dateComponents([.hour, .minute], from: profile.bedtime)
        var dayComps = cal.dateComponents([.year, .month, .day], from: Date())
        dayComps.hour = wakeComps.hour; dayComps.minute = wakeComps.minute
        guard let wakeToday = cal.date(from: dayComps) else { return .failed("bad wake time") }
        dayComps.hour = bedComps.hour; dayComps.minute = bedComps.minute
        guard let bedToday = cal.date(from: dayComps) else { return .failed("bad bedtime") }

        let dayStart = wakeToday.addingTimeInterval(30 * 60)
        let dayEnd = bedToday.addingTimeInterval(-60 * 60)
        let scanStart = max(dayStart, Date())
        guard dayEnd > scanStart else { return .noTasks }

        let allTasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>())) ?? []

        // ── Occupancy: events (+15m tail via resolver) + pre-event 1h buffer
        //    + existing placements ─────────────────────────────────────────
        var busy: [(start: Date, end: Date)] = BusyWindowResolver.shared
            .busyWindows(from: dayStart, to: dayEnd, modelContext: modelContext)
            .map { ($0.start, $0.end) }

        let preEventBuffer: TimeInterval = 60 * 60
        var eventDTOs: [DayPlanInput.EventDTO] = []
        for event in allTasks where event.isInformationalEvent {
            guard let start = event.specificTime, cal.isDateInToday(start) else { continue }
            let mins = event.estimatedMinutes ?? NudgeConfig.defaultEventDurationMinutes
            busy.append((start.addingTimeInterval(-preEventBuffer), start))
            eventDTOs.append(.init(title: event.title, start: Self.iso(start), durationMinutes: mins))
        }
        for task in allTasks where !task.isInformationalEvent {
            guard let p = task.plannedStartDate, cal.isDateInToday(p) else { continue }
            let mins = task.plannedDurationMinutes ?? planningMinutes(for: task, modelContext: modelContext)
            busy.append((p, p.addingTimeInterval(Double(mins) * 60)))
        }

        // ── Free gaps within [scanStart, dayEnd] ──────────────────────────
        let gaps = freeGaps(busy: busy, from: scanStart, to: dayEnd)
        guard !gaps.isEmpty else { return .noTasks }
        let gapDTOs = gaps.map { DayPlanInput.GapDTO(start: Self.iso($0.start), end: Self.iso($0.end)) }

        // ── Top ~8 open, unplaced tasks by Eisenhower score ───────────────
        // Plan tasks first, in the user's stated sequenceIndex order (their
        // order outranks score); non-plan tasks follow, by score. Cap at ~8.
        let openUnplaced = allTasks.filter {
            !$0.isComplete && !$0.isInformationalEvent && $0.plannedStartDate == nil
        }
        let planCandidates = openUnplaced
            .filter { $0.sequenceIndex != nil }
            .sorted { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }
        let scoredCandidates = openUnplaced
            .filter { $0.sequenceIndex == nil }
            .sorted { planScore(for: $0, modelContext: modelContext) > planScore(for: $1, modelContext: modelContext) }
        let candidates = (planCandidates + scoredCandidates).prefix(8)

        guard !candidates.isEmpty else { return .noTasks }

        let dueFmt = DateFormatter()
        dueFmt.dateFormat = "yyyy-MM-dd"
        dueFmt.locale = Locale(identifier: "en_US_POSIX")

        let taskDTOs: [DayPlanInput.TaskDTO] = candidates.map { task in
            .init(
                taskID: task.id.uuidString,
                title: task.title,
                category: task.category,
                estimatedMinutes: planningMinutes(for: task, modelContext: modelContext),
                dueDate: (task.specificTime ?? task.dueDate).map { dueFmt.string(from: $0) },
                score: planScore(for: task, modelContext: modelContext),
                sequenceIndex: task.sequenceIndex
            )
        }

        let input = DayPlanInput(
            now: Self.iso(Date()),
            bedtime: Self.iso(bedToday),
            events: eventDTOs,
            freeGaps: gapDTOs,
            tasks: taskDTOs
        )

        // ── Call the model + apply ────────────────────────────────────────
        do {
            let result = try await ClaudeService.shared.refineDayPlan(input: input)
            applyPlacements(result.placements, allTasks: allTasks, gaps: gaps, modelContext: modelContext)
            try? modelContext.save()
            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
            if let planProfile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first {
                NudgeArbiter.shared.reevaluate(
                    reason: .taskCreatedOrEdited,
                    profile: planProfile,
                    modelContext: modelContext
                )
            }
            NudgeHaptics.success()

            defaults.set(result.rationale, forKey: rationaleKey)
            defaults.set(Self.dayKey(), forKey: rationaleDateKey)
            defaults.set(Self.dayKey(), forKey: refinedDateKey)
            return .success(rationale: result.rationale)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Apply

    private func applyPlacements(
        _ placements: [DayPlanResult.Placement],
        allTasks: [NudgeTask],
        gaps: [(start: Date, end: Date)],
        modelContext: ModelContext
    ) {
        for placement in placements {
            guard let uuid = UUID(uuidString: placement.taskID),
                  let task = allTasks.first(where: { $0.id == uuid }),
                  !task.isComplete, !task.isInformationalEvent,
                  task.plannedStartDate == nil,
                  let start = Self.parseISO(placement.startTime)
            else { continue }

            let duration = TimeInterval(max(placement.durationMinutes, 5) * 60)
            let end = start.addingTimeInterval(duration)

            // Defensive: the placement must fall entirely inside one of the
            // free gaps we handed the model. If the model drifted outside a
            // gap (into an event/buffer), drop that placement.
            let fits = gaps.contains { start >= $0.start && end <= $0.end }
            guard fits else { continue }

            task.plannedStartDate = start
            task.plannedDurationMinutes = placement.durationMinutes
            task.plannedIsAuto = true
        }
    }

    // MARK: - Gaps

    private func freeGaps(
        busy: [(start: Date, end: Date)],
        from: Date,
        to: Date
    ) -> [(start: Date, end: Date)] {
        let sorted = busy.sorted { $0.start < $1.start }
        var gaps: [(start: Date, end: Date)] = []
        var cursor = from
        for interval in sorted {
            if interval.start > cursor {
                gaps.append((cursor, min(interval.start, to)))
            }
            cursor = max(cursor, interval.end)
            if cursor >= to { break }
        }
        if cursor < to { gaps.append((cursor, to)) }
        // Drop slivers under 15 minutes — nothing useful fits.
        return gaps.filter { $0.end.timeIntervalSince($0.start) >= 15 * 60 }
    }

    // MARK: - Scoring (mirrors the deterministic planner)

    private func planningMinutes(for task: NudgeTask, modelContext: ModelContext) -> Int {
        if let e = task.estimatedMinutes, e > 0 { return e }
        if let c = task.taskCategory { return NudgeConfig.categoryEffortPriors[c] ?? 30 }
        return 30
    }

    private func planScore(for task: NudgeTask, modelContext: ModelContext) -> Double {
        let est = planningMinutes(for: task, modelContext: modelContext)
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

    // MARK: - Formatting

    /// Local "YYYY-MM-DDTHH:MM:SS" (no timezone) — matches the schema the
    /// model is told to emit, so round-tripping is symmetric.
    private static func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func parseISO(_ string: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        // No timezone in the string → interpret in the device's local zone.
        return f.date(from: string)
    }

    private static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
