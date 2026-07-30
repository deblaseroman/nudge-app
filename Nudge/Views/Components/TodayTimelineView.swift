//
//  TodayTimelineView.swift
//  Nudge
//
//  Horizontal day timeline shown at the top of the Tasks tab. Spans from
//  (wake − 30 min) to bedtime at ~100pt/hour. Events and placed tasks render
//  as blocks above a horizontal axis; pending notification markers render
//  below it (read-only). Tapping a block opens the editor; tapping empty
//  axis space asks the caller to place a task at that (15-min-rounded) time.
//
//  No AI, no network. Pure layout + SwiftData reads. All mutation is done by
//  the caller through the `onTapEmpty` / `onOpenTask` callbacks so placement
//  logic + arbiter reevaluation stays in TasksTabView.
//

import SwiftUI
import SwiftData

struct TodayTimelineView: View {
    let profile: UserProfile
    /// Tapped an event or task block — open its editor/detail.
    let onOpenTask: (NudgeTask) -> Void
    /// Tapped empty axis space — the Date is already rounded to 15 min.
    let onTapEmpty: (Date) -> Void
    /// Long-pressed a placed task block — mark it complete (full animation).
    var onCompleteTask: (NudgeTask) -> Void = { _ in }

    // Bounded fetches. This view is ALWAYS mounted in the Tasks tab and
    // re-reads on every 60s clock tick, so unbounded @Query here fetches the
    // full task/outcome history into the main context on a hot path. Scope
    // and cap them:
    //   • outcomes → only pending markers (what the strip draws), capped
    //   • tasks    → capped; the day chart only needs today's handful
    @Query private var allTasks: [NudgeTask]
    @Query private var outcomes: [NudgeOutcome]
    @Query private var eventDurations: [EventDurationStats]

    /// Shared 60-second tick drives the "now" indicator.
    private var clock: CountdownClock { CountdownClock.shared }

    init(
        profile: UserProfile,
        onOpenTask: @escaping (NudgeTask) -> Void,
        onTapEmpty: @escaping (Date) -> Void,
        onCompleteTask: @escaping (NudgeTask) -> Void = { _ in }
    ) {
        self.profile = profile
        self.onOpenTask = onOpenTask
        self.onTapEmpty = onTapEmpty
        self.onCompleteTask = onCompleteTask

        var tasksDescriptor = FetchDescriptor<NudgeTask>()
        tasksDescriptor.fetchLimit = 300
        _allTasks = Query(tasksDescriptor)

        // Notification markers are the pending outcomes only.
        var outcomesDescriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> { $0.resultRaw == "pending" }
        )
        outcomesDescriptor.fetchLimit = 60
        _outcomes = Query(outcomesDescriptor)

        _eventDurations = Query()
    }

    // MARK: - Layout constants

    private let hourWidth: CGFloat = 100
    private let blockTop: CGFloat = 8
    private let blockHeight: CGFloat = 58
    private let axisY: CGFloat = 82
    private let tickLabelY: CGFloat = 88
    private let markerTop: CGFloat = 112
    private let totalHeight: CGFloat = 156
    private let defaultTaskMinutes = 30
    /// Same fallback the busy gate uses — an inline 60 here was a second
    /// copy of the constant the two would have had to keep in sync by hand.
    private let defaultEventMinutes = NudgeConfig.defaultEventDurationMinutes

    // MARK: - Time window

    private var startTime: Date {
        let cal = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let comps = cal.dateComponents([.hour, .minute], from: wake)
        var day = cal.dateComponents([.year, .month, .day], from: Date())
        day.hour = comps.hour
        day.minute = comps.minute
        let wakeToday = cal.date(from: day) ?? Date()
        return wakeToday.addingTimeInterval(-30 * 60)
    }

    private var endTime: Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: profile.bedtime)
        var day = cal.dateComponents([.year, .month, .day], from: Date())
        day.hour = comps.hour
        day.minute = comps.minute
        let bedToday = cal.date(from: day) ?? Date()
        // Guard against a bedtime that lands before wake (misconfigured) —
        // fall back to a 16-hour window so the view never collapses.
        return bedToday > startTime ? bedToday : startTime.addingTimeInterval(16 * 3600)
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
    private func snappedDate(forX localX: CGFloat) -> Date {
        let clamped = min(max(localX, 0), contentWidth)
        let raw = startTime.addingTimeInterval(Double(clamped / hourWidth) * 3600)
        let ti = raw.timeIntervalSinceReferenceDate
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

    private var todaysMarkers: [NudgeOutcome] {
        outcomes.filter { o in
            o.resultRaw == "pending" && Calendar.current.isDateInToday(o.scheduledFor)
        }
    }

    /// Event duration, mirroring `BusyWindowResolver.resolveDurationMinutes`
    /// step for step: explicit `estimatedMinutes` (written by the calendar /
    /// screenshot import from the event's real end time), then the learned
    /// `EventDurationStats` row, then the shared default.
    ///
    /// The order is load-bearing, not incidental. This view and the busy
    /// gate must not disagree about how long an event is — a three-hour lab
    /// drawn 60 minutes wide while the arbiter suppresses nudges across the
    /// full three hours reads as a bug in whichever one the user checks
    /// second. If you change the resolution order in one place, change it
    /// in the other.
    private func eventMinutes(for task: NudgeTask) -> Int {
        if let explicit = task.estimatedMinutes, explicit > 0 { return explicit }
        let key = EventDurationStats.normalize(task.title)
        if let learned = eventDurations.first(where: { $0.titleKey == key }) {
            return learned.durationMinutes
        }
        return defaultEventMinutes
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
                    ForEach(todaysMarkers, id: \.id) { markerView($0) }
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
            .frame(height: totalHeight)
            .background(NudgeTheme.surfaceAlt.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
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
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
            .opacity(task.isComplete ? 0.3 : 1.0)
        }
        .buttonStyle(.plain)
        .offset(x: x(for: start), y: blockTop)
    }

    private func taskBlock(_ task: NudgeTask) -> some View {
        let start = task.plannedStartDate ?? Date()
        let w = width(forMinutes: taskMinutes(for: task))
        return Button {
            onOpenTask(task)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 12))
                    .foregroundColor(task.isComplete ? NudgeTheme.textMuted : NudgeTheme.primary)
                    .strikethrough(task.isComplete, color: NudgeTheme.textMuted)
                    .lineLimit(1)
                Text(clockLabel(start))
                    .font(.custom(NudgeTheme.fontBody, size: 10))
                    .foregroundColor(NudgeTheme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: w, height: blockHeight, alignment: .topLeading)
            .background(NudgeTheme.primary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(NudgeTheme.primary.opacity(0.5), lineWidth: 1)
            )
            .opacity(task.isComplete ? 0.3 : 1.0)
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

    private func markerView(_ outcome: NudgeOutcome) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(NudgeTheme.primary)
                .frame(width: 6, height: 6)
            Text(clockLabel(outcome.scheduledFor))
                .font(.custom(NudgeTheme.fontMedium, size: 9))
                .foregroundColor(NudgeTheme.textSecondary)
            Text(markerLabel(outcome.kind))
                .font(.custom(NudgeTheme.fontBody, size: 9))
                .foregroundColor(NudgeTheme.textMuted)
                .lineLimit(1)
        }
        .frame(width: 72)
        .offset(x: x(for: outcome.scheduledFor) - 36, y: markerTop)
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

    private func markerLabel(_ kind: NudgeOutcomeKind) -> String {
        switch kind {
        case .eventBlock:    return "event reminder"
        case .idle:          return "check-in"
        case .getAhead:      return "get ahead"
        case .morningPrompt: return "morning check-in"
        case .floater:       return "open work check-in"
        }
    }
}
