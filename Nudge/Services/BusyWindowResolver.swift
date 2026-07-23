//
//  BusyWindowResolver.swift
//  Nudge
//
//  Computes the user's BUSY windows for a given day from informational
//  events in the task store. Back-to-back events whose gap is ≤
//  `NudgeConfig.interEventGapToleranceMinutes` merge into a single window
//  (the cramped commute between class blocks counts as busy time, not as
//  a notification opportunity). Each final window picks up the
//  `NudgeConfig.postEventBufferMinutes` tail buffer.
//
//  Nothing here makes scheduling decisions — it just answers "is the user
//  busy at this Date?" for callers like `NudgeArbiter`'s gate.
//
//  Duration resolution per event, in order:
//    1. `task.estimatedMinutes` if set (calendar/screenshot import wrote
//       a real end time).
//    2. `EventDurationStats` row keyed by normalized title — populated
//       once the user confirms the duration of an event they added
//       without one (capture flow, step 6).
//    3. `NudgeConfig.defaultEventDurationMinutes` (60) as a safety net.
//

import Foundation
import SwiftData

struct BusyWindow {
    let start: Date
    let end: Date
}

/// Aggregate commitment load for one day's awake window — the reusable
/// answer to "how full is this day already?". Previously this math existed
/// only implicitly inside `TasksTabView.planMyDay()` and (privately) in
/// `DayPlanRefiner.freeGaps` — neither exported a number a gate could
/// consume, which is why this lives here now instead of a third copy.
struct DayLoad {
    let windowStart: Date
    let windowEnd: Date
    /// Minutes of the window covered by merged event busy windows
    /// (including their tail buffers and cramped-gap merges). Placed
    /// tasks deliberately do NOT count — the question is about fixed
    /// commitments, not the plan the user drew on top of them.
    let busyMinutes: Int

    var windowMinutes: Int {
        max(Int(windowEnd.timeIntervalSince(windowStart) / 60), 0)
    }

    /// 0 = completely free day, 1 = fully committed.
    var busyFraction: Double {
        let total = windowMinutes
        guard total > 0 else { return 1 }
        return min(Double(busyMinutes) / Double(total), 1)
    }
}

@MainActor
final class BusyWindowResolver {

    static let shared = BusyWindowResolver()
    private init() {}

    /// Returns the merged busy windows that overlap [from, to]. Windows
    /// outside the range are excluded for efficiency. Result is sorted
    /// by `start`. Empty if no informational events fall in the range.
    func busyWindows(
        from: Date,
        to: Date,
        modelContext: ModelContext
    ) -> [BusyWindow] {
        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.isInformationalEvent }
        )
        let events = (try? modelContext.fetch(descriptor)) ?? []

        // Build raw windows (start + end before any merging or buffer).
        var rawWindows: [BusyWindow] = events.compactMap { event in
            guard let start = event.specificTime else { return nil }
            let durationMin = resolveDurationMinutes(for: event, modelContext: modelContext)
            let end = start.addingTimeInterval(Double(durationMin) * 60)
            // Range filter — keep events whose window overlaps [from, to].
            if end < from || start > to { return nil }
            return BusyWindow(start: start, end: end)
        }
        rawWindows.sort { $0.start < $1.start }

        return merge(rawWindows)
    }

    /// Convenience for the common "does this fire date land in a busy
    /// window?" check. The lookup window is widened by the tail buffer +
    /// gap tolerance so an event ending shortly before `fireDate` still
    /// counts.
    func isBusy(at fireDate: Date, modelContext: ModelContext) -> Bool {
        let pad = Double(NudgeConfig.interEventGapToleranceMinutes
                       + NudgeConfig.postEventBufferMinutes) * 60
        let windows = busyWindows(
            from: fireDate.addingTimeInterval(-pad),
            to: fireDate.addingTimeInterval(pad),
            modelContext: modelContext
        )
        return windows.contains { fireDate >= $0.start && fireDate <= $0.end }
    }

    // MARK: - Day load

    /// Commitment load for `day`'s awake window: wake + postWakeQuietMinutes
    /// → bedtime − preBedtimeQuietMinutes, the same window the planners use
    /// (their inline wake+30 / bed−60 literals mirror these constants).
    /// `wake`/`bedtime` are clock-time Dates from `UserProfile`; only their
    /// hour/minute components are read, so any `day` — today or a future
    /// fire day — can be assessed. Returns nil when the window is invalid
    /// (e.g. a past-midnight bedtime collapses it) — callers should fail
    /// OPEN on nil rather than suppress.
    func dayLoad(
        on day: Date,
        wake: Date,
        bedtime: Date,
        modelContext: ModelContext
    ) -> DayLoad? {
        let calendar = Calendar.current
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        let bedComps = calendar.dateComponents([.hour, .minute], from: bedtime)
        var dayComps = calendar.dateComponents([.year, .month, .day], from: day)

        dayComps.hour = wakeComps.hour
        dayComps.minute = wakeComps.minute
        guard let wakeOnDay = calendar.date(from: dayComps) else { return nil }
        dayComps.hour = bedComps.hour
        dayComps.minute = bedComps.minute
        guard let bedOnDay = calendar.date(from: dayComps) else { return nil }

        let start = wakeOnDay.addingTimeInterval(Double(NudgeConfig.postWakeQuietMinutes) * 60)
        let end = bedOnDay.addingTimeInterval(-Double(NudgeConfig.preBedtimeQuietMinutes) * 60)
        guard end > start else { return nil }

        let windows = busyWindows(from: start, to: end, modelContext: modelContext)
        let busySeconds = windows.reduce(0.0) { total, window in
            let overlapStart = max(window.start, start)
            let overlapEnd = min(window.end, end)
            return total + max(overlapEnd.timeIntervalSince(overlapStart), 0)
        }
        return DayLoad(
            windowStart: start,
            windowEnd: end,
            busyMinutes: Int(busySeconds / 60)
        )
    }

    // MARK: - Duration resolution

    private func resolveDurationMinutes(
        for event: NudgeTask,
        modelContext: ModelContext
    ) -> Int {
        if let explicit = event.estimatedMinutes, explicit > 0 {
            return explicit
        }
        let key = EventDurationStats.normalize(event.title)
        let descriptor = FetchDescriptor<EventDurationStats>(
            predicate: #Predicate<EventDurationStats> { $0.titleKey == key }
        )
        if let learned = (try? modelContext.fetch(descriptor))?.first {
            return learned.durationMinutes
        }
        return NudgeConfig.defaultEventDurationMinutes
    }

    // MARK: - Merge logic
    //
    // Walk the sorted list once. While the next event starts within
    // `interEventGapToleranceMinutes` of the current window's end,
    // absorb it (the gap counts as busy). Once the gap is too wide,
    // close the current window with the `postEventBufferMinutes` tail
    // buffer and start a new one.

    private func merge(_ windows: [BusyWindow]) -> [BusyWindow] {
        guard !windows.isEmpty else { return [] }
        let gapTolerance = Double(NudgeConfig.interEventGapToleranceMinutes) * 60
        let tailBuffer  = Double(NudgeConfig.postEventBufferMinutes) * 60

        var merged: [BusyWindow] = []
        var i = 0
        while i < windows.count {
            let currentStart = windows[i].start
            var currentEnd   = windows[i].end

            while i + 1 < windows.count {
                let next = windows[i + 1]
                if next.start.timeIntervalSince(currentEnd) <= gapTolerance {
                    // Merge through — gap is too cramped to be a free slot.
                    currentEnd = max(currentEnd, next.end)
                    i += 1
                } else {
                    break
                }
            }

            merged.append(BusyWindow(
                start: currentStart,
                end: currentEnd.addingTimeInterval(tailBuffer)
            ))
            i += 1
        }
        return merged
    }

    // MARK: - Learning hook
    //
    // Called by the capture flow (step 6) once the user confirms how long
    // an event lasts. Replaces (not averages) — class durations don't
    // drift; the user just corrects an initial bad guess.

    func recordDuration(
        title: String,
        durationMinutes: Int,
        modelContext: ModelContext
    ) {
        guard durationMinutes > 0 else { return }
        let key = EventDurationStats.normalize(title)
        let descriptor = FetchDescriptor<EventDurationStats>(
            predicate: #Predicate<EventDurationStats> { $0.titleKey == key }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.durationMinutes = durationMinutes
            existing.sampleCount += 1
            existing.updatedAt = Date()
        } else {
            let stats = EventDurationStats(title: title, durationMinutes: durationMinutes)
            modelContext.insert(stats)
        }
        try? modelContext.save()
    }
}
