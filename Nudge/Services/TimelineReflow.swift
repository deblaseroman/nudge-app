//
//  TimelineReflow.swift
//  Nudge
//
//  One block on today's timeline grew or moved; the rest of the day answers
//  (Roman's rules, Sep 23 2026):
//
//    • The changed block keeps its start and grows to its new length.
//    • Later AUTO placements that it now collides with are pushed later,
//      each keeping the gap it had to whatever came before it (a task at
//      10:00 for 1h with the next at 11:15 becomes 1h30 → the next lands at
//      11:45). Pushing cascades.
//    • ANCHORED items never move: events, and tasks the user placed by hand
//      (`plannedIsAuto == false`, the same rule the arbiter's quiet-hours
//      exemption uses). If the grown block would run into an anchored item,
//      its START moves earlier instead of its end moving later.
//    • A started focus session is pinned at now: it cannot move earlier, so
//      an anchored collision there is left alone and reported.
//    • A pushed item that no longer fits before the day window ends goes
//      back to Unscheduled (the planner's own convention), never off-screen.
//
//  Two callers: the editor's Duration chips, and a focus-session start.
//  Saves and reloads the widget; the arbiter reevaluate stays with the
//  caller, which already does it.
//

import Foundation
import SwiftData
import WidgetKit

@MainActor
enum TimelineReflow {

    /// What happened, for the caller's console line.
    struct Result {
        var pushed: [(title: String, from: Date, to: Date)] = []
        var unscheduled: [String] = []
        var startMovedEarlierTo: Date? = nil
        var unresolvedAnchorOverlap: String? = nil
    }

    private static let snapMinutes = 15
    private static let fallbackTaskMinutes = 30

    /// An anchored item the change would run into with no way around it
    /// (Roman, Sep 23 2026: warn, name it, and let the user decide).
    struct AnchoredConflict: Identifiable {
        let id = UUID()
        let title: String
        let start: Date
        let isEvent: Bool
        var timeLabel: String { TimelineReflow.clock(start) }
    }

    /// Dry run of the subject's own settlement: nil when the change fits or
    /// can be resolved by moving the start earlier; the offending item when
    /// it cannot (or when the start is pinned, as for a session at now).
    static func anchoredConflict(for subject: NudgeTask, start: Date, minutes: Int, pinStart: Bool, modelContext: ModelContext) -> AnchoredConflict? {
        let day = Calendar.current.startOfDay(for: start)
        let anchored = titledAnchored(on: day, excluding: subject.id, modelContext: modelContext)
        let end = start.addingTimeInterval(Double(minutes) * 60)
        guard let hit = anchored.first(where: { $0.interval.start < end && start < $0.interval.end }) else { return nil }
        if pinStart { return hit.conflict }
        let floorStart = anchored.map(\.interval).filter { $0.end <= start }.map(\.end).max()
            ?? dayWindow(on: day, modelContext: modelContext)?.start ?? day
        let earlier = max(floorStart, hit.interval.start.addingTimeInterval(-Double(minutes) * 60))
        return earlier.addingTimeInterval(Double(minutes) * 60) <= hit.interval.start ? nil : hit.conflict
    }

    private struct Anchored {
        let interval: Interval
        let conflict: AnchoredConflict
    }

    /// Events (real length, no buffer) and manual placements on `day`.
    private static func titledAnchored(on day: Date, excluding subjectID: UUID, modelContext: ModelContext) -> [Anchored] {
        let all = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete }
        ))) ?? []
        return all.filter { $0.id != subjectID && isOnDay($0, day) && isAnchored($0) }.compactMap { t in
            let start: Date? = t.isInformationalEvent ? t.specificTime : t.plannedStartDate
            guard let s = start else { return nil }
            let mins = t.isInformationalEvent ? t.eventDurationMinutes(modelContext: modelContext) : taskMinutes(t)
            let interval = Interval(start: s, end: s.addingTimeInterval(Double(mins) * 60))
            return Anchored(interval: interval, conflict: AnchoredConflict(title: t.title, start: s, isEvent: t.isInformationalEvent))
        }.sorted { $0.interval.start < $1.interval.start }
    }

    private static func dayWindow(on day: Date, modelContext: ModelContext) -> DayWindow? {
        guard let profile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first else { return nil }
        return DayWindow.resolve(on: day, wake: profile.wakeTime ?? profile.morningCheckInTime, bedtime: profile.bedtime)
    }

    /// Anchored ⇔ an event, or a placement the user made by hand.
    static func isAnchored(_ task: NudgeTask) -> Bool {
        task.isInformationalEvent || (task.plannedStartDate != nil && !task.plannedIsAuto)
    }

    // MARK: - Entry points

    /// The editor changed `subject`'s length. Writes `plannedDurationMinutes`
    /// (the value the timeline draws) and reflows around the block.
    @discardableResult
    static func durationChanged(_ subject: NudgeTask, to minutes: Int, modelContext: ModelContext) -> Result {
        guard let start = subject.plannedStartDate, Calendar.current.isDateInToday(start) else {
            subject.plannedDurationMinutes = minutes
            return Result()
        }
        subject.plannedDurationMinutes = minutes
        return reflow(subject: subject, start: start, minutes: minutes, pinStart: false, modelContext: modelContext)
    }

    /// A focus session started for `subject` at `now`: the block moves to
    /// now (a manual placement, since the user chose it), today's intent is
    /// set, and whatever the session now covers is pushed later.
    @discardableResult
    static func sessionStarted(_ subject: NudgeTask, at now: Date, minutes: Int, modelContext: ModelContext) -> Result {
        guard !subject.isInformationalEvent else { return Result() }
        let start = floorToMinute(now)
        subject.plannedStartDate = start
        subject.plannedDurationMinutes = minutes
        subject.plannedIsAuto = false
        subject.intendedDate = Calendar.current.startOfDay(for: start)
        return reflow(subject: subject, start: start, minutes: minutes, pinStart: true, modelContext: modelContext)
    }

    // MARK: - The reflow

    private struct Interval {
        let start: Date
        let end: Date
        func overlaps(_ other: Interval) -> Bool { start < other.end && other.start < end }
    }

    private static func reflow(subject: NudgeTask, start: Date, minutes: Int, pinStart: Bool, modelContext: ModelContext) -> Result {
        var result = Result()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: start)
        let profile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()))?.first
        let window = profile.flatMap {
            DayWindow.resolve(on: day, wake: $0.wakeTime ?? $0.morningCheckInTime, bedtime: $0.bedtime)
        }
        let dayEnd = window?.end ?? calendar.date(byAdding: .day, value: 1, to: day) ?? start
        let dayStart = window?.start ?? day

        let all = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete }
        ))) ?? []
        let todays = all.filter { $0.id != subject.id && isOnDay($0, day) }

        // Anchored intervals: events (with the resolver's post-event buffer)
        // and manual placements. Never moved; only avoided.
        var anchored: [Interval] = BusyWindowResolver.shared
            .busyWindows(from: day, to: dayEnd, modelContext: modelContext)
            .map { Interval(start: $0.start, end: $0.end) }
        anchored += todays
            .filter { !$0.isInformationalEvent && isAnchored($0) }
            .compactMap { t in t.plannedStartDate.map { Interval(start: $0, end: $0.addingTimeInterval(Double(taskMinutes(t)) * 60)) } }
        anchored.sort { $0.start < $1.start }

        // 1. Settle the subject's own interval.
        var subjectStart = start
        var subjectEnd = start.addingTimeInterval(Double(minutes) * 60)
        if let hit = anchored.first(where: { $0.start >= subjectStart && $0.start < subjectEnd }) {
            if pinStart {
                result.unresolvedAnchorOverlap = "anchored item at \(clock(hit.start)) overlaps the session; session stays at now"
            } else {
                // Start moves earlier instead of the end moving later.
                let floorStart = anchored.filter { $0.end <= start }.map(\.end).max() ?? dayStart
                let earlier = max(floorStart, hit.start.addingTimeInterval(-Double(minutes) * 60))
                if earlier.addingTimeInterval(Double(minutes) * 60) <= hit.start {
                    subjectStart = earlier
                    subjectEnd = earlier.addingTimeInterval(Double(minutes) * 60)
                    subject.plannedStartDate = subjectStart
                    result.startMovedEarlierTo = subjectStart
                } else {
                    result.unresolvedAnchorOverlap = "no room before the anchored item at \(clock(hit.start)); block left overlapping"
                }
            }
        }

        // 2. Push the movable placements that follow.
        let movable = todays
            .filter { !$0.isInformationalEvent && !isAnchored($0) && $0.plannedStartDate != nil }
            .sorted { ($0.plannedStartDate ?? .distantPast) < ($1.plannedStartDate ?? .distantPast) }

        // Each item's gap to whatever preceded it in the ORIGINAL layout, so
        // the user's spacing survives the push.
        var originalGaps: [UUID: TimeInterval] = [:]
        var previousEnd: Date = .distantPast
        let originalOrder = (movable + [subject]).sorted { ($0.plannedStartDate ?? .distantPast) < ($1.plannedStartDate ?? .distantPast) }
        for t in originalOrder {
            guard let s = t.plannedStartDate else { continue }
            let e = s.addingTimeInterval(Double(t.id == subject.id ? minutes : taskMinutes(t)) * 60)
            originalGaps[t.id] = previousEnd == .distantPast ? 0 : max(0, s.timeIntervalSince(previousEnd))
            previousEnd = max(previousEnd, e)
        }

        var cursor = subjectEnd
        for t in movable {
            guard let s = t.plannedStartDate else { continue }
            let len = Double(taskMinutes(t)) * 60
            let mine = Interval(start: s, end: s.addingTimeInterval(len))
            guard mine.end > subjectStart else { continue }          // wholly before the subject
            guard mine.start < cursor else {                          // no collision; it stays
                cursor = max(cursor, mine.end)
                continue
            }
            var candidate = snapUp(cursor.addingTimeInterval(originalGaps[t.id] ?? 0))
            // Hop over anchored intervals.
            var guardCount = 0
            while let hit = anchored.first(where: { Interval(start: candidate, end: candidate.addingTimeInterval(len)).overlaps($0) }), guardCount < 20 {
                candidate = snapUp(hit.end)
                guardCount += 1
            }
            if candidate.addingTimeInterval(len) > dayEnd {
                t.plannedStartDate = nil
                t.plannedDurationMinutes = nil
                t.plannedIsAuto = false
                result.unscheduled.append(t.title)
                continue
            }
            result.pushed.append((t.title, s, candidate))
            t.plannedStartDate = candidate
            cursor = candidate.addingTimeInterval(len)
        }

        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        #if DEBUG
        var line = "[TimelineReflow] \"\(subject.title)\" \(clock(subjectStart))–\(clock(subjectEnd))"
        if let m = result.startMovedEarlierTo { line += " (start moved earlier to \(clock(m)))" }
        for p in result.pushed { line += "; pushed \"\(p.title)\" \(clock(p.from)) → \(clock(p.to))" }
        for u in result.unscheduled { line += "; unscheduled \"\(u)\" (no room before day end)" }
        if let o = result.unresolvedAnchorOverlap { line += "; \(o)" }
        print(line)
        #endif
        return result
    }

    // MARK: - Helpers

    private static func isOnDay(_ task: NudgeTask, _ day: Date) -> Bool {
        let cal = Calendar.current
        if task.isInformationalEvent { return task.specificTime.map { cal.isDate($0, inSameDayAs: day) } ?? false }
        return task.plannedStartDate.map { cal.isDate($0, inSameDayAs: day) } ?? false
    }

    private static func taskMinutes(_ task: NudgeTask) -> Int {
        task.plannedDurationMinutes ?? task.estimatedMinutes ?? fallbackTaskMinutes
    }

    private static func snapUp(_ date: Date) -> Date {
        let step = Double(snapMinutes) * 60
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / step).rounded(.up) * step)
    }

    private static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
