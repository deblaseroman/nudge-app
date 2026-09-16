//
//  TodayTimelineView.swift
//  Nudge
//
//  Horizontal day timeline shown at the top of the Tasks tab. Spans from
//  (wake − 30 min) to bedtime at ~100pt/hour. Events and placed tasks render
//  as blocks above a horizontal axis. Tapping a block opens the editor;
//  tapping empty axis space asks the caller to place a task at that (15-min-rounded) time.
//
//  No AI, no network. Pure layout + SwiftData reads. All mutation is done by
//  the caller through the `onTapEmpty` / `onOpenTask` callbacks so placement
//  logic + arbiter reevaluation stays in TasksTabView.
//

import SwiftUI
import SwiftData

struct TodayTimelineView: View {
    let profile: UserProfile
    /// Day-slot index per task id, from `DaySlotPalette.assignments`. Owned by
    /// the parent (TasksTabView) rather than computed here so the tint on a
    /// block and the tint on that task's row under Today can't drift apart —
    /// see the note in DaySlotPalette. A task missing from the map falls back
    /// to the neutral event/stone tint.
    var slots: [UUID: Int] = [:]
    /// Tapped an event or task block — open its editor/detail.
    let onOpenTask: (NudgeTask) -> Void
    /// Tapped empty axis space — the Date is already rounded to 15 min.
    let onTapEmpty: (Date) -> Void
    /// Long-pressed a placed task block — mark it complete (full animation).
    var onCompleteTask: (NudgeTask) -> Void = { _ in }

    // Bounded fetches. This view is ALWAYS mounted in the Tasks tab and
    // re-reads on every 60s clock tick, so unbounded @Query here fetches the
    // full task history into the main context on a hot path. Scope and
    // cap it: tasks are capped; the day chart only needs today's handful.
    // (Pending-notification markers used to draw below the axis from a
    // second bounded query; removed Sep 2026, the timeline shows the day's
    // shape, not when the app will speak.)
    @Query private var allTasks: [NudgeTask]
    @Query private var eventDurations: [EventDurationStats]

    /// Shared 60-second tick drives the "now" indicator.
    private var clock: CountdownClock { CountdownClock.shared }

    init(
        profile: UserProfile,
        slots: [UUID: Int] = [:],
        onOpenTask: @escaping (NudgeTask) -> Void,
        onTapEmpty: @escaping (Date) -> Void,
        onCompleteTask: @escaping (NudgeTask) -> Void = { _ in }
    ) {
        self.profile = profile
        self.slots = slots
        self.onOpenTask = onOpenTask
        self.onTapEmpty = onTapEmpty
        self.onCompleteTask = onCompleteTask

        var tasksDescriptor = FetchDescriptor<NudgeTask>()
        tasksDescriptor.fetchLimit = 300
        _allTasks = Query(tasksDescriptor)

        _eventDurations = Query()
    }

    // MARK: - Layout constants

    private let hourWidth: CGFloat = 100
    private let blockTop: CGFloat = 8
    private let blockHeight: CGFloat = 58
    private let axisY: CGFloat = 82
    private let tickLabelY: CGFloat = 88
    /// Axis + tick labels and a little breathing room below them. Was 156
    /// when notification markers drew under the axis; the strip is shorter
    /// now, which is what moves Start Session up.
    private let totalHeight: CGFloat = 108
    private let defaultTaskMinutes = 30
    /// Completed blocks used to sit at 0.3, which was doing the whole job of
    /// "this is done". The fill now carries that itself (a slot tint mixed
    /// most of the way to grey), so this only has to finish the recession —
    /// pushed back up so the surviving hue, the point of the muted tint, is
    /// still legible instead of washed out twice.
    private let completedBlockOpacity: Double = 0.75
    /// Same fallback the busy gate uses — an inline 60 here was a second
    /// copy of the constant the two would have had to keep in sync by hand.

    // MARK: - Time window
    //
    // TWO windows, deliberately (Sep 2026, Roman's ruling on the "items
    // outside wake/bed are clipped" gap):
    //   • the BASE window (wake − 30m → bed) is where TASKS live — empty-
    //     space taps clamp into it, so task placement stays inside the
    //     user's day for now (revisit noted: people sometimes need to do
    //     things outside it).
    //   • the RENDER window additionally stretches to cover every one of
    //     today's EVENTS, wherever they fall. An event's time is a fact;
    //     a 6:30 shift used to exist, gate, and notify — invisibly,
    //     because the strip silently clipped it.

    private var baseStart: Date {
        let cal = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let comps = cal.dateComponents([.hour, .minute], from: wake)
        var day = cal.dateComponents([.year, .month, .day], from: Date())
        day.hour = comps.hour
        day.minute = comps.minute
        let wakeToday = cal.date(from: day) ?? Date()
        return wakeToday.addingTimeInterval(-30 * 60)
    }

    private var baseEnd: Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: profile.bedtime)
        var day = cal.dateComponents([.year, .month, .day], from: Date())
        day.hour = comps.hour
        day.minute = comps.minute
        let bedToday = cal.date(from: day) ?? Date()
        // Guard against a bedtime that lands before wake (misconfigured) —
        // fall back to a 16-hour window so the view never collapses.
        return bedToday > baseStart ? bedToday : baseStart.addingTimeInterval(16 * 3600)
    }

    private var startTime: Date {
        guard let earliest = todaysEvents.compactMap(\.specificTime).min(),
              earliest < baseStart else { return baseStart }
        // Half an hour of lead so the earliest block isn't flush at the edge.
        return earliest.addingTimeInterval(-30 * 60)
    }

    private var endTime: Date {
        let latestEnd = todaysEvents
            .compactMap { event -> Date? in
                guard let start = event.specificTime else { return nil }
                return start.addingTimeInterval(Double(eventMinutes(for: event)) * 60)
            }
            .max()
        guard let latestEnd, latestEnd > baseEnd else { return baseEnd }
        return latestEnd.addingTimeInterval(15 * 60)
    }

    private var totalSeconds: TimeInterval { endTime.timeIntervalSince(startTime) }
    private var contentWidth: CGFloat { CGFloat(totalSeconds / 3600) * hourWidth }

    // MARK: - Positioning helpers

    private func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(startTime) / 3600) * hourWidth
    }

    private func width(forMinutes minutes: Int) -> CGFloat {
        max(CGFloat(minutes) / 60 * hourWidth, 40)
    }

    /// Converts a local x into a clock time snapped to the nearest 15 min.
    /// The result is clamped into the BASE window: the strip may render
    /// beyond wake/bed to show an early or late event, but a tap out there
    /// proposes a task at the nearest in-window time instead — tasks stay
    /// inside the day's bounds (Roman's ruling; revisit noted).
    private func snappedDate(forX localX: CGFloat) -> Date {
        let clamped = min(max(localX, 0), contentWidth)
        let raw = startTime.addingTimeInterval(Double(clamped / hourWidth) * 3600)
        let bounded = min(max(raw, baseStart), baseEnd)
        let ti = bounded.timeIntervalSinceReferenceDate
        let snapped = (ti / 900).rounded() * 900
        return Date(timeIntervalSinceReferenceDate: snapped)
    }

    // MARK: - Data slices

    private var todaysEvents: [NudgeTask] {
        allTasks.filter { task in
            guard task.isInformationalEvent, let t = task.specificTime else { return false }
            return Calendar.current.isDateInToday(t)
        }
    }

    private var placedTasks: [NudgeTask] {
        allTasks.filter { task in
            guard !task.isInformationalEvent, let p = task.plannedStartDate else { return false }
            return Calendar.current.isDateInToday(p)
        }
    }

    /// Event duration — the shared `NudgeTask.eventDurationMinutes`
    /// resolution (explicit → learned `EventDurationStats` → fallback),
    /// against this view's bounded `@Query` rather than a per-event fetch,
    /// because this view re-reads on every 60s tick. Same method the busy
    /// gate, the planners, and the widget use, so the drawn block and the
    /// arbiter's busy window can't disagree about an event's length.
    private func eventMinutes(for task: NudgeTask) -> Int {
        task.eventDurationMinutes(in: eventDurations)
    }

    private func taskMinutes(for task: NudgeTask) -> Int {
        task.plannedDurationMinutes ?? task.estimatedMinutes ?? defaultTaskMinutes
    }

    /// Whole-hour tick dates from the first hour ≥ startTime through endTime.
    private var hourTicks: [Date] {
        let cal = Calendar.current
        var ticks: [Date] = []
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: startTime)
        // If start has minutes, begin at the next whole hour.
        if cal.component(.minute, from: startTime) != 0 {
            comps.hour = (comps.hour ?? 0) + 1
        }
        guard var t = cal.date(from: comps) else { return ticks }
        while t <= endTime {
            ticks.append(t)
            guard let next = cal.date(byAdding: .hour, value: 1, to: t) else { break }
            t = next
        }
        return ticks
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    axis
                    ForEach(hourTicks, id: \.self) { tickView(at: $0) }
                    ForEach(todaysEvents, id: \.id) { eventBlock($0) }
                    ForEach(placedTasks, id: \.id) { taskBlock($0) }
                    nowIndicator
                    // Invisible scroll anchor whose FRAME ORIGIN is genuinely
                    // at "now". Neither .offset nor .padding work here — both
                    // leave the view's frame origin at x=0, so ScrollViewReader
                    // targeted the start of the day. An HStack with a leading
                    // spacer of width = x(now) actually pushes the anchor's
                    // frame to the now position.
                    HStack(spacing: 0) {
                        Color.clear.frame(width: max(x(for: clock.now), 0), height: 1)
                        Color.clear.frame(width: 1, height: 1).id("nowAnchor")
                        Spacer(minLength: 0)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                }
                .frame(width: contentWidth, height: totalHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                // Empty-space taps live on the CONTAINER — a parent gesture is
                // lower priority than the block Buttons inside, so tapping a
                // block opens it while tapping bare axis places a task.
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            onTapEmpty(snappedDate(forX: value.location.x))
                        }
                )
            }
            // The strip is full-bleed inside the Tasks tab (it escapes the
            // page gutter), so it is a band, not a card: no rounded clip,
            // and the gutter becomes scroll margin so the first label sits
            // off the screen edge.
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .frame(height: totalHeight)
            .background(NudgeTheme.surfaceAlt.opacity(0.4))
            .onAppear {
                // Open with "now" near the LEFT edge (small lead-in of the
                // past for padding) rather than centered — so the strip
                // starts at the blue line. The full day is still rendered, so
                // the user can scroll back to the morning if they want.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("nowAnchor", anchor: UnitPoint(x: 0.1, y: 0.5))
                }
            }
        }
    }

    // MARK: - Pieces

    private var axis: some View {
        Rectangle()
            .fill(NudgeTheme.border)
            .frame(width: contentWidth, height: 1)
            .offset(x: 0, y: axisY)
    }

    private func tickView(at date: Date) -> some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(NudgeTheme.border)
                .frame(width: 1, height: 6)
            Text(hourLabel(date))
                .font(.custom(NudgeTheme.fontMedium, size: 10))
                .foregroundColor(NudgeTheme.textMuted)
                .fixedSize()
        }
        .frame(width: 44)
        .offset(x: x(for: date) - 22, y: axisY - 3)
    }

    private func eventBlock(_ task: NudgeTask) -> some View {
        let start = task.specificTime ?? Date()
        let w = width(forMinutes: eventMinutes(for: task))
        return Button {
            onOpenTask(task)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 12))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .lineLimit(1)
                Text(clockLabel(start))
                    .font(.custom(NudgeTheme.fontBody, size: 10))
                    .foregroundColor(NudgeTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: w, height: blockHeight, alignment: .topLeading)
            // One stone tint for every event, outside the task rotation —
            // events are fixed points in the day, not steps in the plan.
            .background(task.isComplete ? NudgeTheme.eventSlotFillCompleted : NudgeTheme.eventSlotFill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        task.isComplete ? NudgeTheme.eventSlotAccentCompleted : NudgeTheme.eventSlotAccent,
                        lineWidth: 1
                    )
            )
            .opacity(task.isComplete ? completedBlockOpacity : 1.0)
        }
        .buttonStyle(.plain)
        .offset(x: x(for: start), y: blockTop)
    }

    private func taskBlock(_ task: NudgeTask) -> some View {
        let start = task.plannedStartDate ?? Date()
        let w = width(forMinutes: taskMinutes(for: task))
        // Tinted by position in the day. Title moves to `textPrimary` — it
        // used to be `primary` against a flat blue-grey fill, which no longer
        // holds contrast across six hues.
        let slot = slots[task.id]
        let fill = task.isComplete
            ? (slot.map { NudgeTheme.daySlotFillCompleted($0) } ?? NudgeTheme.eventSlotFillCompleted)
            : (slot.map { NudgeTheme.daySlotFill($0) } ?? NudgeTheme.eventSlotFill)
        let accent = task.isComplete
            ? (slot.map { NudgeTheme.daySlotAccentCompleted($0) } ?? NudgeTheme.eventSlotAccentCompleted)
            : (slot.map { NudgeTheme.daySlotAccent($0) } ?? NudgeTheme.eventSlotAccent)
        return Button {
            onOpenTask(task)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 12))
                    .foregroundColor(task.isComplete ? NudgeTheme.textMuted : NudgeTheme.textPrimary)
                    .strikethrough(task.isComplete, color: NudgeTheme.textMuted)
                    .lineLimit(1)
                Text(clockLabel(start))
                    .font(.custom(NudgeTheme.fontBody, size: 10))
                    .foregroundColor(NudgeTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: w, height: blockHeight, alignment: .topLeading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(accent, lineWidth: 1)
            )
            .opacity(task.isComplete ? completedBlockOpacity : 1.0)
        }
        .buttonStyle(.plain)
        // Complete from the timeline: long-press marks done with the full
        // NudgeFeedback burst (same effect as the list rows). Tap still opens
        // the block; the long-press is a simultaneous gesture so both work.
        .taskCompletionEffect(isComplete: Binding(get: { task.isComplete }, set: { _ in }))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                if !task.isComplete { onCompleteTask(task) }
            }
        )
        .offset(x: x(for: start), y: blockTop)
    }

    @ViewBuilder
    private var nowIndicator: some View {
        let now = clock.now
        if now >= startTime && now <= endTime {
            VStack(spacing: 0) {
                Circle()
                    .fill(NudgeTheme.primary)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(NudgeTheme.primary)
                    .frame(width: 2, height: axisY + 6)
            }
            .offset(x: x(for: now) - 4, y: blockTop - 8)
        }
    }

    // MARK: - Formatting

    private func hourLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f.string(from: date)
    }

    private func clockLabel(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        let f = DateFormatter()
        f.dateFormat = minute == 0 ? "h a" : "h:mm a"
        return f.string(from: date)
    }
}
