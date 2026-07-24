//
//  TasksTabView.swift
//  Nudge
//
//  Task list with sorting, editing, and completion animations.
//

import Combine
import SwiftUI
import SwiftData
import WidgetKit

struct TasksTabView: View {
    let profile: UserProfile
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var tasks: [NudgeTask]
    @Query private var completedRecords: [CompletedTaskRecord]

    @Binding var selectedTab: AppTab
    @State private var activeSheet: TaskSheetDestination?
    @State private var showCancelSessionAlert = false
    @State private var showSessionTaskPicker = false
    @State private var showCompletedSheet = false
    /// Set when the user taps empty timeline space — drives the placement
    /// sheet. Carries the (15-min-rounded) tapped time.
    @State private var placement: PlacementContext?
    /// When "New task" is chosen from the placement sheet, the created task
    /// should land at this time. Consumed by the create editor's onSave.
    @State private var pendingPlacementTime: Date?
    /// AI day-plan rationale shown above the timeline (from DayPlanRefiner).
    @State private var refineRationale: String?
    @State private var isRefining = false
    #if DEBUG
    @State private var showDeleteAllAlert = false
    #endif
    /// Day-groups beyond the first `NudgeConfig.eventsExpandedDays` are
    /// collapsed behind a "Show N more days" button by default; this reveals
    /// them.
    @State private var showAllEventDays = false
    /// Task proposed by the idle nudge's "Not yet" action. When non-nil
    /// we show `IdleStartConfirmationSheet` offering to start a session
    /// on this task with a "pick something else" escape hatch.
    @State private var idleProposedTaskID: UUID?

    private var coordinator: SessionCoordinator { SessionCoordinator.shared }

    private var actionableTasks: [NudgeTask] {
        tasks.filter { !$0.isInformationalEvent }
    }

    /// Incomplete informational events, time-sorted. Completed events are
    /// excluded to match the Calendar tab preview's `!isComplete` filter.
    private var eventItems: [NudgeTask] {
        tasks
            .filter { $0.isInformationalEvent && !$0.isComplete }
            .sorted { lhs, rhs in
                (lhs.specificTime ?? lhs.dueDate ?? .distantFuture) < (rhs.specificTime ?? rhs.dueDate ?? .distantFuture)
            }
    }

    /// One calendar day's worth of events for the grouped Events section.
    private struct EventDayGroup: Identifiable {
        let day: Date
        let events: [NudgeTask]
        var id: Date { day }
    }

    /// Events bucketed by calendar day, each day time-ordered. Fully dateless
    /// events (no dueDate and no specificTime) have no day of their own, so
    /// they're parked under today — their "needs a time and date" chip stays
    /// visible at the top of the list instead of vanishing, the same surfacing
    /// the old flat list gave them.
    private var eventDayGroups: [EventDayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(grouping: eventItems) { event -> Date in
            guard let anchor = event.specificTime ?? event.dueDate else { return today }
            return cal.startOfDay(for: anchor)
        }
        return byDay
            .map { EventDayGroup(day: $0.key, events: $0.value.sorted(by: Self.eventsWithinDayOrder)) }
            .sorted { $0.day < $1.day }
    }

    /// Within a day: untimed / "needs a time" events sort to the top, then
    /// timed events in clock order. `nonisolated` because it's pure — it reads
    /// only its two NudgeTask arguments and no main-actor state — so it can be
    /// handed to the nonisolated `sorted(by:)` without crossing the actor.
    private nonisolated static func eventsWithinDayOrder(_ lhs: NudgeTask, _ rhs: NudgeTask) -> Bool {
        switch (lhs.specificTime, rhs.specificTime) {
        case let (l?, r?): return l < r
        case (nil, nil):   return lhs.title < rhs.title
        case (nil, _):     return true
        case (_, nil):     return false
        }
    }

    /// Normalized titles appearing `routineEventRepeatThreshold`+ times among
    /// the section's events — the repetition half of EventRowView's "routine"
    /// de-emphasis. A row can't see its siblings, so this is computed here and
    /// passed down per row. Counts the same set the section renders
    /// (`eventItems`: incomplete informational events, expanded AND collapsed
    /// days), the population the rule was validated against when chosen.
    private var routineRepeatedTitles: Set<String> {
        let counts = Dictionary(grouping: eventItems) {
            Self.normalizedEventTitle($0.title)
        }.mapValues(\.count)
        return Set(
            counts.filter { $0.value >= NudgeConfig.routineEventRepeatThreshold }.keys
        )
    }

    /// Trim + lowercase, the same normalization `CalendarService.isDuplicate`
    /// uses — "CHEM 210 " and "chem 210" count as the same fixture.
    /// `nonisolated` for the same reason as `eventsWithinDayOrder`: pure.
    private nonisolated static func normalizedEventTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The first `eventsExpandedDays` day-groups — always shown.
    private var expandedEventDays: [EventDayGroup] {
        Array(eventDayGroups.prefix(NudgeConfig.eventsExpandedDays))
    }

    /// Day-groups past the expanded window — hidden behind "Show N more days".
    private var collapsedEventDays: [EventDayGroup] {
        Array(eventDayGroups.dropFirst(NudgeConfig.eventsExpandedDays))
    }

    /// Header for a day-group: "Today · Friday", "Tomorrow · Saturday", then
    /// "Sunday, Jul 27" for everything further out.
    private func eventDayHeader(for day: Date) -> String {
        let cal = Calendar.current
        let daysOut = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: day).day ?? 0
        let weekday = day.formatted(.dateTime.weekday(.wide))
        switch daysOut {
        case 0:  return "Today · \(weekday)"
        case 1:  return "Tomorrow · \(weekday)"
        default: return "\(weekday), \(day.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }


    /// Tasks shown in the main list — informational events excluded,
    /// completed tasks excluded, AND ordered-plan tasks excluded (those live
    /// only in the "Today's plan" section so they're never duplicated).
    private var sortedTasks: [NudgeTask] {
        let comparator = TaskSortComparator()
        return actionableTasks
            .filter { !$0.isComplete && $0.sequenceIndex == nil }
            .sorted { comparator.compare($0, $1) }
    }

    /// Ordered "Today's plan" tasks (captured from the brain dump), in
    /// sequenceIndex order. Includes completed ones so they stay struck-
    /// through with their number; the section only SHOWS when at least one
    /// is still open (`hasActivePlan`).
    private var planTasks: [NudgeTask] {
        actionableTasks
            .filter { $0.sequenceIndex != nil }
            .sorted { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }
    }

    private var hasActivePlan: Bool {
        planTasks.contains { !$0.isComplete }
    }

    /// Incomplete actionable tasks in the SAME order the app list uses:
    /// ordered-plan tasks first (sequenceIndex order), then everything else by
    /// TaskSortComparator. Used by the "start a session" task picker so it
    /// matches the list. (`planTasks` is already sequenceIndex-sorted;
    /// `sortedTasks` is the non-plan, incomplete, comparator-sorted set.)
    private var orderedActionableTasks: [NudgeTask] {
        planTasks.filter { !$0.isComplete } + sortedTasks
    }

    /// Open tasks not yet placed on today's timeline.
    private var unscheduledTasks: [NudgeTask] {
        sortedTasks.filter { $0.plannedStartDate == nil }
    }

    /// Open tasks placed on today's timeline. Kept in the list (in addition
    /// to appearing on the timeline) so they stay checkable — placement must
    /// not remove a task from completion tracking.
    private var scheduledTasks: [NudgeTask] {
        sortedTasks.filter { task in
            guard let p = task.plannedStartDate else { return false }
            return Calendar.current.isDateInToday(p)
        }
    }

    /// True when "Plan my day" has auto-placed at least one task today —
    /// gates the "Clear plan" button.
    private var hasAutoPlacements: Bool {
        tasks.contains { task in
            guard task.plannedIsAuto, let p = task.plannedStartDate else { return false }
            return Calendar.current.isDateInToday(p)
        }
    }

    private var incompleteCount: Int {
        actionableTasks.filter { !$0.isComplete }.count
    }

    /// Monday 00:00 of the current calendar week.
    private var weekStart: Date {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return calendar.date(from: comps) ?? Calendar.current.startOfDay(for: Date())
    }

    /// CompletedTaskRecord rows from this week, newest at top.
    private var thisWeekCompleted: [CompletedTaskRecord] {
        completedRecords
            .filter { $0.completedAt >= weekStart }
            .sorted { $0.completedAt > $1.completedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                startSessionButton
                completedButton
                HStack(alignment: .center) {
                    sectionLabel("Today")
                    Spacer()
                    if hasAutoPlacements {
                        Button {
                            clearPlan()
                        } label: {
                            Text("Clear plan")
                                .font(.custom(NudgeTheme.fontMedium, size: 13))
                                .foregroundColor(NudgeTheme.textMuted)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(NudgeTheme.surfaceAlt)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if profile.isPro || profile.isInTrial {
                        Button {
                            refineWithAI()
                        } label: {
                            HStack(spacing: 6) {
                                if isRefining {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text("Refine")
                                    .font(.custom(NudgeTheme.fontSemiBold, size: 13))
                            }
                            .foregroundColor(NudgeTheme.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(NudgeTheme.primary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefining)
                    }
                    Button {
                        planMyDay()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Plan my day")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 13))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(NudgeTheme.primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let rationale = refineRationale, !rationale.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(NudgeTheme.primary)
                        Text(rationale)
                            .font(.custom(NudgeTheme.fontMedium, size: 13))
                            .foregroundColor(NudgeTheme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NudgeTheme.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                }
                TodayTimelineView(
                    profile: profile,
                    onOpenTask: { task in
                        // A placed task opens the manage window (with the
                        // remove-from-timeline button); events open the editor.
                        if !task.isInformationalEvent && task.plannedStartDate != nil {
                            activeSheet = .manageTimeline(taskID: task.id)
                        } else {
                            activeSheet = .edit(taskID: task.id)
                        }
                    },
                    onTapEmpty: { placement = PlacementContext(time: $0) },
                    onCompleteTask: { toggleCompletion(for: $0) }
                )
                tasksContent
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        .onAppear {
            purgeOldCompletedRecords()
            // Pick up a rationale produced elsewhere today (e.g. via the
            // Home chat "plan my day" flow).
            refineRationale = DayPlanRefiner.shared.todaysRationale()
            // Durable idle "Not yet" intent — present the sheet whenever the
            // Tasks tab appears, including a cold launch from the tap.
            consumePendingIdleTask()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Also consume when returning to the foreground while the Tasks
            // tab is already on screen (onAppear won't re-fire then).
            if newPhase == .active { consumePendingIdleTask() }
        }
        .sheet(item: $placement) { ctx in
            placementSheet(for: ctx)
        }
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .create:
                TaskEditorSheet(
                    mode: .create,
                    onSave: { draft in
                        let newTask = NudgeTask(
                            title: draft.title,
                            dueDate: draft.dueDate,
                            dueTime: draft.dueTimeLabel,
                            specificTime: draft.specificTime,
                            priority: draft.priority,
                            source: "manual"
                        )
                        // If "New task" was chosen from a timeline slot, land
                        // the new task at that time.
                        if let placeAt = pendingPlacementTime {
                            newTask.plannedStartDate = placeAt
                            pendingPlacementTime = nil
                        }
                        // Hand-set stakes: write directly + flag as user-set
                        // so no later automation pass overwrites it.
                        if draft.stakesUserPicked, let picked = draft.stakes {
                            newTask.stakes = picked
                            newTask.stakesIsUserSet = true
                        }
                        modelContext.insert(newTask)
                        try? modelContext.save()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                        // Enrich the new task's signals once, explicitly, at
                        // creation — not on every arbiter read.
                        NudgeIntelligence.shared.refreshSoon(for: newTask)
                        refreshNotifications()
                    }
                )
                .presentationDetents([.medium, .large])
            case .edit(let taskID):
                if let task = tasks.first(where: { $0.id == taskID }) {
                    TaskEditorSheet(
                        mode: .edit(task: task),
                        onSave: { draft in
                            task.title = draft.title
                            task.priority = draft.priority
                            task.dueDate = draft.dueDate
                            task.dueTime = draft.dueTimeLabel
                            task.specificTime = draft.specificTime
                            // Hand-set stakes: write directly + flag as
                            // user-set so no later automation pass overwrites
                            // it. Only when a chip was actually tapped.
                            if draft.stakesUserPicked, let picked = draft.stakes {
                                task.stakes = picked
                                task.stakesIsUserSet = true
                            }
                            try? modelContext.save()
                            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                            // Title may have changed — re-enrich once.
                            NudgeIntelligence.shared.refreshSoon(for: task)
                            refreshNotifications()
                        },
                        onDelete: {
                            modelContext.delete(task)
                            try? modelContext.save()
                            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                            refreshNotifications()
                        },
                        // Only offered when the task is actually placed on the
                        // timeline. Clears the placement without deleting it.
                        onRemoveFromTimeline: (!task.isInformationalEvent && task.plannedStartDate != nil)
                            ? { unscheduleTask(task) }
                            : nil
                    )
                    .presentationDetents([.medium, .large])
                }
            case .manageTimeline(let taskID):
                if let task = tasks.first(where: { $0.id == taskID }) {
                    manageTimelineSheet(for: task)
                }
            }
        }
        .sheet(isPresented: $showSessionTaskPicker) {
            SessionTaskPickerSheet(
                tasks: orderedActionableTasks,
                onPick: { task in
                    showSessionTaskPicker = false
                    coordinator.startSession(task: task, userName: profile.name)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showCompletedSheet) {
            WeeklyCompletedSheet(records: thisWeekCompleted)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: idleSheetIsPresented) {
            if let task = idleProposedTask {
                IdleStartConfirmationSheet(
                    task: task,
                    onConfirm: {
                        idleProposedTaskID = nil
                        coordinator.startSession(task: task, userName: profile.name)
                    },
                    onPickSomethingElse: {
                        idleProposedTaskID = nil
                        showSessionTaskPicker = true
                    }
                )
                .presentationDetents([.height(280), .medium])
            }
        }
        .onReceive(
            // Same Combine main-hop as ContentView's openTab observer.
            // This is the @State write that flips the sheet binding — if
            // it lands off-main, SwiftUI's sheet presentation invokes
            // `_performBlockAfterCATransactionCommitSynchronizes` on the
            // wrong thread and UIKit asserts "Call must be made on main
            // thread". `.receive(on: DispatchQueue.main)` makes the
            // publisher itself responsible for delivering on main, so
            // every subsequent step (state mutation → SwiftUI invalidation
            // → CATransaction commit → sheet present) is main-bound.
            NotificationCenter.default
                .publisher(for: .nudgeIdleNotYetTapped)
                .receive(on: DispatchQueue.main)
        ) { note in
            // Posted from the idle "Not yet" delegate handler with the
            // top open task's UUID. The sheet appears the next time this
            // view is on screen (the delegate also requests the Tasks
            // tab via .nudgeNotificationOpenTab).
            guard let uuidString = note.userInfo?["taskID"] as? String,
                  let uuid = UUID(uuidString: uuidString) else { return }
            idleProposedTaskID = uuid
        }
    }

    /// Reads the DURABLE idle "Not yet" intent from the app group and, if a
    /// valid still-open task is pending from today, presents the confirmation
    /// sheet. This is the launch-path-independent path: it works on cold
    /// launch (where the transient .nudgeIdleNotYetTapped post is missed
    /// because this view wasn't subscribed yet) AND warm resume. Consuming
    /// (clearing) the keys makes it one-shot.
    private func consumePendingIdleTask() {
        let defaults = SharedModelContainer.appGroupDefaults
        guard let idString = defaults.string(forKey: NudgeNotificationService.pendingIdleTaskIDKey),
              let uuid = UUID(uuidString: idString) else { return }

        defer {
            defaults.removeObject(forKey: NudgeNotificationService.pendingIdleTaskIDKey)
            defaults.removeObject(forKey: NudgeNotificationService.pendingIdleTaskDateKey)
        }

        // Ignore a stale intent (e.g. tapped yesterday, app opened today).
        if let date = defaults.object(forKey: NudgeNotificationService.pendingIdleTaskDateKey) as? Date,
           !Calendar.current.isDateInToday(date) {
            return
        }
        // Only present if the task still exists and is open.
        guard tasks.contains(where: { $0.id == uuid && !$0.isComplete }) else { return }
        idleProposedTaskID = uuid
    }

    /// Looks up the proposed task, guarding against deletion or completion
    /// between the notification firing and the user tapping "Not yet".
    private var idleProposedTask: NudgeTask? {
        guard let id = idleProposedTaskID else { return nil }
        return tasks.first(where: { $0.id == id && !$0.isComplete })
    }

    /// Binding wired to `idleProposedTaskID` — clearing it on dismiss is
    /// what flips the sheet closed when the user swipes it down.
    private var idleSheetIsPresented: Binding<Bool> {
        Binding(
            get: { idleProposedTask != nil },
            set: { presented in
                if !presented { idleProposedTaskID = nil }
            }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AccountShortcutButton(selectedTab: $selectedTab)
            ScreenHeader(title: "Tasks", subtitle: "Overdue tasks rise to the top, then everything else sorts by due date.")

            Spacer()

            #if DEBUG
            // Testing-only: wipe every task + event. Never ships in release.
            Button(action: {
                NudgeHaptics.medium()
                showDeleteAllAlert = true
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(NudgeTheme.overdue)
                    .frame(width: 42, height: 42)
                    .background(NudgeTheme.overdue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            #endif

            Button(action: {
                NudgeHaptics.medium()
                activeSheet = .create
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        #if DEBUG
        .alert("Delete everything?", isPresented: $showDeleteAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete all", role: .destructive) { deleteAllTasksAndEvents() }
        } message: {
            Text("Removes every task and event. Testing only.")
        }
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No tasks yet")
                .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("Use the Home tab to dump what is on your mind, or add one manually here.")
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// Fixed row height so the reorderable List can be sized inside the
    /// outer ScrollView (a scroll-disabled List needs a bounded height).
    private let planRowHeight: CGFloat = 84

    /// Ordered "Today's plan" — a numbered, long-press-reorderable list.
    /// Uses a scroll-disabled List so SwiftUI's `.onMove` gives native drag
    /// reordering while still living inside the tab's ScrollView.
    private var planSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Today's plan")
            List {
                ForEach(planTasks, id: \.id) { task in
                    HStack(alignment: .center, spacing: 10) {
                        Text("\(task.sequenceIndex ?? 0).")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(task.isComplete ? NudgeTheme.textMuted : NudgeTheme.primary)
                            .frame(width: 20, alignment: .trailing)
                        TaskRowView(
                            task: task,
                            isLastIncompleteTask: false,
                            onOpen: { activeSheet = .edit(taskID: task.id) },
                            onToggleComplete: { toggleCompletion(for: task) },
                            onDelete: { deleteTask(task) },
                            onConvertToEvent: { setEventFlag(task, isEvent: true) }
                        )
                    }
                    .frame(height: planRowHeight)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: movePlanTasks)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: planRowHeight * CGFloat(max(planTasks.count, 1)))
        }
    }

    /// Rewrites sequenceIndex to match the dropped order, persists, and
    /// reevaluates (order changes which task the idle nudge suggests first).
    private func movePlanTasks(from source: IndexSet, to destination: Int) {
        var reordered = planTasks
        reordered.move(fromOffsets: source, toOffset: destination)
        for (i, task) in reordered.enumerated() {
            task.sequenceIndex = i + 1
        }
        try? modelContext.save()
        NudgeHaptics.light()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    private var tasksContent: some View {
        Group {
            if sortedTasks.isEmpty && eventItems.isEmpty && !hasActivePlan {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if hasActivePlan {
                        planSection
                    }

                    if !unscheduledTasks.isEmpty {
                        sectionLabel("Unscheduled")

                        VStack(spacing: 12) {
                            ForEach(unscheduledTasks, id: \.id) { task in
                                TaskRowView(
                                    task: task,
                                    isLastIncompleteTask: incompleteCount == 1 && !task.isComplete,
                                    onOpen: { activeSheet = .edit(taskID: task.id) },
                                    onToggleComplete: { toggleCompletion(for: task) },
                                    onDelete: { deleteTask(task) },
                                    onConvertToEvent: { setEventFlag(task, isEvent: true) }
                                )
                            }
                        }
                    }

                    if !scheduledTasks.isEmpty {
                        sectionLabel("Scheduled")

                        VStack(spacing: 12) {
                            ForEach(scheduledTasks, id: \.id) { task in
                                TaskRowView(
                                    task: task,
                                    isLastIncompleteTask: incompleteCount == 1 && !task.isComplete,
                                    onOpen: { activeSheet = .edit(taskID: task.id) },
                                    onToggleComplete: { toggleCompletion(for: task) },
                                    onDelete: { deleteTask(task) },
                                    onConvertToEvent: { setEventFlag(task, isEvent: true) }
                                )
                            }
                        }
                    }

                    if !eventDayGroups.isEmpty {
                        sectionLabel("Events")

                        // Computed once per render, not once per row — the
                        // repeat count scans every event.
                        let routineTitles = routineRepeatedTitles

                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(expandedEventDays) { group in
                                eventDaySection(group, routineTitles: routineTitles)
                            }

                            if showAllEventDays {
                                ForEach(collapsedEventDays) { group in
                                    eventDaySection(group, routineTitles: routineTitles)
                                }
                            }

                            if !collapsedEventDays.isEmpty {
                                Button {
                                    NudgeHaptics.light()
                                    withAnimation(NudgeAnimation.standard) {
                                        showAllEventDays.toggle()
                                    }
                                } label: {
                                    Text(showAllEventDays
                                         ? "Show fewer days"
                                         : "Show \(collapsedEventDays.count) more day\(collapsedEventDays.count == 1 ? "" : "s")")
                                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                                        .foregroundColor(NudgeTheme.primary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(NudgeTheme.surfaceAlt)
                                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var startSessionButton: some View {
        Group {
            if coordinator.isSessionActive {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: sessionStateIcon)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(sessionStateLabel)
                                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                                .foregroundColor(.white)

                            Text(coordinator.currentTaskName)
                                .font(.custom(NudgeTheme.fontBody, size: 12))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)
                        }

                        Spacer()

                        if coordinator.sessionState == .active {
                            Button(action: {
                                NudgeHaptics.medium()
                                coordinator.completeCurrentTask()
                            }) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(NudgeTheme.primary)
                                    .frame(width: 34, height: 34)
                                    .background(.white)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: {
                            NudgeHaptics.medium()
                            showCancelSessionAlert = true
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 34)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 56)
                    .background(sessionStateTint)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .alert("Cancel Session?", isPresented: $showCancelSessionAlert) {
                    Button("Keep going", role: .cancel) { }
                    Button("Cancel session", role: .destructive) {
                        coordinator.cancelSession()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                    }
                } message: {
                    Text("This will end your current session and stop all timers.")
                }
            } else {
                Button(action: startSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14, weight: .bold))

                        Text("Start Session")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))

                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var completedButton: some View {
        HStack {
            Spacer()
            Button(action: {
                NudgeHaptics.light()
                showCompletedSheet = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Completed (\(thisWeekCompleted.count))")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 13))
                }
                .foregroundColor(NudgeTheme.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(NudgeTheme.primary.opacity(0.12))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(NudgeTheme.primary.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var sessionStateLabel: String {
        coordinator.sessionState == .complete ? "All Done" : "Focusing"
    }

    private var sessionStateIcon: String {
        coordinator.sessionState == .complete ? "checkmark.circle.fill" : "bolt.fill"
    }

    private var sessionStateTint: Color {
        coordinator.sessionState == .complete
            ? Color(red: 0.33, green: 0.64, blue: 0.47)
            : NudgeTheme.primary
    }

    private func toggleCompletion(for task: NudgeTask) {
        let newValue = !task.isComplete

        withAnimation(NudgeAnimation.standard) {
            task.isComplete = newValue
        }

        if newValue {
            let completionDate = Date()
            task.completedAt = completionDate

            // Create a persistent record so stats survive task deletion
            let sourceID = task.id
            let existing = try? modelContext.fetch(
                FetchDescriptor<CompletedTaskRecord>(
                    predicate: #Predicate<CompletedTaskRecord> { $0.sourceTaskID == sourceID }
                )
            ).first
            if existing == nil {
                let record = CompletedTaskRecord(
                    title: task.title,
                    priority: task.priority,
                    completedAt: completionDate,
                    sourceTaskID: task.id
                )
                modelContext.insert(record)
            }
        } else {
            task.completedAt = nil

            // Remove the record if unchecking
            let sourceID = task.id
            if let record = try? modelContext.fetch(
                FetchDescriptor<CompletedTaskRecord>(
                    predicate: #Predicate<CompletedTaskRecord> { $0.sourceTaskID == sourceID }
                )
            ).first {
                modelContext.delete(record)
            }
        }

        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")

        // Re-evaluate the wasting-time nudge + class/work reminders. If the
        // user just completed a task, this cancels today's pending nudge.
        refreshNotifications()

        // If the coordinator session is active and the task being completed is
        // the CURRENT block, advance the session. Completing any other task
        // (out-of-order) must NOT advance the coordinator's index.
        if coordinator.isSessionActive
            && newValue
            && coordinator.currentTaskID == task.id {
            coordinator.completeCurrentTask()
        }

        guard newValue, incompleteCount == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NudgeHaptics.success()
        }
    }

    private func deleteTask(_ task: NudgeTask) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            modelContext.delete(task)
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    #if DEBUG
    /// Testing-only: wipes every NudgeTask (tasks AND events). Not compiled
    /// into release builds.
    private func deleteAllTasksAndEvents() {
        NudgeHaptics.medium()
        withAnimation(NudgeAnimation.standard) {
            for task in tasks {
                modelContext.delete(task)
            }
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }
    #endif

    /// One-tap correction when the AI misclassified an item. Flips it
    /// between task and event, then re-runs the arbiter since the two are
    /// scheduled differently (events get factual heads-ups; tasks get
    /// discretionary nudges).
    private func setEventFlag(_ task: NudgeTask, isEvent: Bool) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            task.isInformationalEvent = isEvent
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    /// Fills in a missing start time on an event (from the "needs a time"
    /// chip). Combines the chosen clock time with the event's existing day
    /// (or today if it had no date), then re-runs the arbiter so the event
    /// reminder can schedule immediately.
    private func setEventTime(_ event: NudgeTask, to time: Date) {
        let cal = Calendar.current
        let timeComps = cal.dateComponents([.hour, .minute], from: time)
        // If the event already has a day, keep it (time-only edit). If not,
        // the picker included a date, so take the day from the picked value.
        let baseDay = event.dueDate ?? time
        var dayComps = cal.dateComponents([.year, .month, .day], from: baseDay)
        dayComps.hour = timeComps.hour
        dayComps.minute = timeComps.minute
        let combined = cal.date(from: dayComps)

        withAnimation(NudgeAnimation.standard) {
            event.specificTime = combined
            if event.dueDate == nil { event.dueDate = combined }
            if let combined {
                let fmt = DateFormatter()
                fmt.dateFormat = "h:mm a"
                event.dueTime = fmt.string(from: combined)
            }
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    // MARK: - Timeline placement

    /// Identifies a tapped empty-timeline slot for the placement sheet.
    struct PlacementContext: Identifiable {
        let id = UUID()
        let time: Date
    }

    /// Places (or moves) a task onto today's timeline at `time`. Does NOT
    /// touch dueDate/specificTime — placement is independent of the deadline.
    private func placeTask(_ task: NudgeTask, at time: Date) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            task.plannedStartDate = time
            task.plannedIsAuto = false   // user-placed
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    /// Clears a task's timeline placement (back to Unscheduled).
    private func unscheduleTask(_ task: NudgeTask) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            task.plannedStartDate = nil
            task.plannedIsAuto = false
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    // MARK: - Plan my day (deterministic, no AI)

    /// Effort minutes used for planning: explicit estimate, else the
    /// per-category prior, else 30.
    private func planningMinutes(for task: NudgeTask) -> Int {
        if let e = task.estimatedMinutes, e > 0 { return e }
        if let c = task.taskCategory { return NudgeConfig.categoryEffortPriors[c] ?? 30 }
        return 30
    }

    /// Deterministic Eisenhower score for ranking candidates. Reads only
    /// cached intelligence (no API).
    private func planScore(for task: NudgeTask) -> Double {
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

    /// Auto-places up to 4 open tasks into today's free gaps. Deterministic;
    /// fills around events and any existing placements; never overwrites a
    /// manual placement.
    private func planMyDay() {
        let cal = Calendar.current

        // Day window: wake + 30 min → bedtime − 60 min (today).
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = cal.dateComponents([.hour, .minute], from: wake)
        let bedComps = cal.dateComponents([.hour, .minute], from: profile.bedtime)
        var dayComps = cal.dateComponents([.year, .month, .day], from: Date())
        dayComps.hour = wakeComps.hour; dayComps.minute = wakeComps.minute
        guard let wakeToday = cal.date(from: dayComps) else { return }
        dayComps.hour = bedComps.hour; dayComps.minute = bedComps.minute
        guard let bedToday = cal.date(from: dayComps) else { return }

        let dayStart = wakeToday.addingTimeInterval(30 * 60)
        let dayEnd = bedToday.addingTimeInterval(-60 * 60)
        // Don't place in the past.
        let scanStart = max(dayStart, Date())
        guard dayEnd > scanStart else { return }

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

        // Candidates: open, non-event, not already placed. Ranked by score.
        // Explicit "Plan my day" DOES place plan tasks. Plan tasks go first,
        // in the user's stated sequenceIndex order (their order outranks
        // Eisenhower score); non-plan tasks follow, by score. A placed plan
        // task keeps its number in Today's plan AND shows on the timeline.
        let openUnplaced = tasks.filter {
            !$0.isComplete && !$0.isInformationalEvent && $0.plannedStartDate == nil
        }
        let planCandidates = openUnplaced
            .filter { $0.sequenceIndex != nil }
            .sorted { ($0.sequenceIndex ?? .max) < ($1.sequenceIndex ?? .max) }
        let scoredCandidates = openUnplaced
            .filter { $0.sequenceIndex == nil }
            .sorted { planScore(for: $0) > planScore(for: $1) }
        let candidates = planCandidates + scoredCandidates

        let spacing: TimeInterval = 15 * 60
        var placedCount = 0

        for task in candidates {
            guard placedCount < 4 else { break }
            let duration = TimeInterval(planningMinutes(for: task) * 60)
            guard let start = earliestGapStart(
                fitting: duration,
                busy: busy,
                from: scanStart,
                to: dayEnd
            ) else { continue }

            task.plannedStartDate = start
            task.plannedDurationMinutes = planningMinutes(for: task)
            task.plannedIsAuto = true
            // Occupy this slot + 15 min spacing for the next placement.
            busy.append((start, start.addingTimeInterval(duration + spacing)))
            placedCount += 1
        }

        guard placedCount > 0 else {
            NudgeHaptics.error()
            return
        }
        withAnimation(NudgeAnimation.standard) { }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        NudgeHaptics.success()
        refreshNotifications()
    }

    /// Earliest start ≥ `from` where `duration` fits before the next busy
    /// interval (or `to`). Snaps to the next 15-min boundary when it still
    /// fits. Returns nil if nothing fits.
    private func earliestGapStart(
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

    /// Runs the AI refine (Pro/trial only). A button tap is an explicit ask,
    /// so `force: true`. Shows the returned rationale above the timeline.
    private func refineWithAI() {
        guard !isRefining else { return }
        isRefining = true
        Task { @MainActor in
            let outcome = await DayPlanRefiner.shared.refine(
                profile: profile,
                modelContext: modelContext,
                force: true
            )
            isRefining = false
            switch outcome {
            case .success(let r), .cached(let r):
                refineRationale = r
            case .noTasks:
                NudgeHaptics.error()
            case .notEntitled, .failed:
                NudgeHaptics.error()
            }
        }
    }

    /// Removes only auto (Plan my day) placements from today; keeps manual
    /// ones.
    private func clearPlan() {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            for task in tasks {
                guard task.plannedIsAuto, let p = task.plannedStartDate,
                      Calendar.current.isDateInToday(p) else { continue }
                task.plannedStartDate = nil
                task.plannedDurationMinutes = nil
                task.plannedIsAuto = false
            }
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        refreshNotifications()
    }

    @ViewBuilder
    private func manageTimelineSheet(for task: NudgeTask) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(task.title)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 18))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .multilineTextAlignment(.center)
                    if let planned = task.plannedStartDate {
                        Text("Placed at \(planned.formatted(date: .omitted, time: .shortened))")
                            .font(.custom(NudgeTheme.fontBody, size: 13))
                            .foregroundColor(NudgeTheme.textMuted)
                    }
                }
                .padding(.top, 12)

                // Swap this slot for a different task: free the slot, then
                // open the placement picker at the same time.
                Button {
                    let time = task.plannedStartDate
                    unscheduleTask(task)
                    activeSheet = nil
                    if let time {
                        DispatchQueue.main.async { placement = PlacementContext(time: time) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Swap for another task")
                    }
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                    .foregroundColor(NudgeTheme.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(NudgeTheme.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)

                Button {
                    let id = task.id
                    activeSheet = nil
                    DispatchQueue.main.async { activeSheet = .edit(taskID: id) }
                } label: {
                    Text("Open task details")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(20)
            .background(NudgeTheme.background)
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { activeSheet = nil }
                }
                // Small remove button, top-right.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        unscheduleTask(task)
                        activeSheet = nil
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(NudgeTheme.overdue)
                    }
                    .accessibilityLabel("Remove from timeline")
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    @ViewBuilder
    private func placementSheet(for ctx: PlacementContext) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        NudgeHaptics.light()
                        pendingPlacementTime = ctx.time
                        placement = nil
                        // Present the create editor on the next runloop tick
                        // so the placement sheet finishes dismissing first.
                        DispatchQueue.main.async { activeSheet = .create }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("New task")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            Spacer()
                        }
                        .foregroundColor(NudgeTheme.primary)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(NudgeTheme.primary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                    }
                    .buttonStyle(.plain)

                    if unscheduledTasks.isEmpty {
                        Text("No unscheduled tasks to place.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(unscheduledTasks, id: \.id) { task in
                            Button {
                                placeTask(task, at: ctx.time)
                                placement = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title)
                                        .font(.custom(NudgeTheme.fontMedium, size: 15))
                                        .foregroundColor(NudgeTheme.textPrimary)
                                    // Importance (stakes), one channel app-wide.
                                    // "—" when unclassified (nil stakes).
                                    Text(task.stakes?.rawValue.capitalized ?? "—")
                                        .font(.custom(NudgeTheme.fontBody, size: 12))
                                        .foregroundColor(NudgeTheme.textMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(NudgeTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                                .overlay(
                                    RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                                        .stroke(NudgeTheme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle("Place at \(ctx.time.formatted(date: .omitted, time: .shortened))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { placement = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Re-runs every notification decision via the arbiter using the
    /// current data state. The reason flag lets the arbiter pick the
    /// appropriate cancel/keep semantics for the trigger.
    private func refreshNotifications(reason: NudgeArbiterReason = .taskCreatedOrEdited) {
        NudgeArbiter.shared.reevaluate(
            reason: reason,
            profile: profile,
            modelContext: modelContext
        )
    }

    /// Deletes CompletedTaskRecord rows from any week prior to the current one.
    /// Runs on appear, so the cleanup happens whenever the user opens the tab
    /// on or after a Monday boundary.
    private func purgeOldCompletedRecords() {
        let cutoff = weekStart
        let stale = completedRecords.filter { $0.completedAt < cutoff }
        guard !stale.isEmpty else { return }
        for record in stale {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    private func startSession() {
        NudgeHaptics.medium()
        guard !coordinator.isSessionActive else { return }

        let incompleteTasks = actionableTasks.filter { !$0.isComplete }
        guard !incompleteTasks.isEmpty else { return }

        showSessionTaskPicker = true
    }

    /// One day's section in the Events list: a day header over that day's
    /// event rows. The header is the quietest text layer (muted), so the rows
    /// — and their high-stakes emphasis — carry the visual weight.
    @ViewBuilder
    private func eventDaySection(_ group: EventDayGroup, routineTitles: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eventDayHeader(for: group.day))
                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                .foregroundColor(NudgeTheme.textMuted)

            VStack(spacing: 12) {
                ForEach(group.events, id: \.id) { event in
                    EventRowView(
                        task: event,
                        titleRepeatsAsRoutine: routineTitles.contains(
                            Self.normalizedEventTitle(event.title)
                        ),
                        onOpen: { activeSheet = .edit(taskID: event.id) },
                        onDelete: { deleteTask(event) },
                        onConvertToTask: { setEventFlag(event, isEvent: false) },
                        onSetTime: { setEventTime(event, to: $0) }
                    )
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.custom(NudgeTheme.fontSemiBold, size: 18))
            .foregroundColor(NudgeTheme.textPrimary)
    }
}

// MARK: - Shared stakes row styling
//
// The high-stakes visual treatment shared by task and event rows: the amber
// "High" pill and the semibold title weight. Task rows layer their own
// time-pressure states (overdue / approaching / sitting) on top; event rows
// use ONLY these two, because those time states are task concepts.

/// Amber "High" importance pill. Shared so a high-stakes item reads identically
/// whether it's a task or an event. Callers guard on stakes/completion; this is
/// purely the pill's appearance. Its text is folded into the row title's
/// VoiceOver label, so it stays hidden from the a11y tree here.
struct HighStakesPill: View {
    var body: some View {
        Text("High")
            .font(.custom(NudgeTheme.fontSemiBold, size: 11))
            .foregroundColor(NudgeTheme.amber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NudgeTheme.amber.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityHidden(true)
    }
}

enum StakesRowStyle {
    /// Semibold title when the row is high-stakes, else the normal medium
    /// weight. Task rows pass their calm high-stakes state (the weight bump is
    /// suppressed under time pressure, where color carries the signal); event
    /// rows pass the event's stakes directly.
    static func titleFontName(isHighStakes: Bool) -> String {
        isHighStakes ? NudgeTheme.fontSemiBold : NudgeTheme.fontMedium
    }
}

// MARK: - Task Row

struct TaskRowView: View {
    @Bindable var task: NudgeTask
    let isLastIncompleteTask: Bool
    let onOpen: () -> Void
    let onToggleComplete: () -> Void
    let onDelete: () -> Void
    /// Flips this task into an event (isInformationalEvent = true) when the
    /// AI misclassified it. One-tap correction.
    let onConvertToEvent: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(priorityColor)
                .frame(width: 10, height: 10)

            Button(action: onToggleComplete) {
                ZStack {
                    Circle()
                        .stroke(task.isComplete ? NudgeTheme.primary : NudgeTheme.border, lineWidth: 2)
                        .fill(task.isComplete ? NudgeTheme.primary : Color.clear)
                        .frame(width: 28, height: 28)

                    if task.isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .checkboxBounce(isComplete: $task.isComplete)

            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .leading) {
                    Text(task.title)
                        .font(.custom(titleFontName, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .strikethrough(task.isComplete, color: NudgeTheme.textMuted)
                        .accessibilityLabel(titleAccessibilityLabel)

                    if task.isComplete {
                        AnimatedStrikethrough(isVisible: $task.isComplete)
                    }
                }

                // Subtitle slot — the remaining-time line ("12 hours left" /
                // "5 days away"), recolored coral when the deadline is
                // approaching, or the amber "Sitting N days" line for aging
                // low-stakes floaters. Nil ⇒ no subtitle, so calm rows stay
                // exactly as before.
                if let subtitle {
                    Text(subtitle.text)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(subtitle.color)
                }
            }

            Spacer()

            // Right-side date + clock-time line. Hidden for floaters.
            if !task.isComplete,
               let dueLine = CountdownState.dueDateLine(
                    dueDate: task.dueDate,
                    specificTime: task.specificTime
               ) {
                Text(dueLine)
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(rowTreatment == .overdue ? NudgeTheme.overdue : NudgeTheme.textMuted)
            }

            // One-tap "this is actually an event" correction.
            if !task.isComplete {
                Button(action: onConvertToEvent) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(width: 30, height: 30)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Convert to event")
            }

            if task.isComplete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(width: 30, height: 30)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // Stakes importance badge. Last element so it sits flush at the
            // trailing edge and aligns vertically down the list. Amber in
            // every row state — importance is constant; the row's time
            // colors move independently. Its text is folded into the title's
            // VoiceOver label, so it's hidden from the a11y tree here.
            if task.stakes == .high, !task.isComplete {
                HighStakesPill()
            }
        }
        .padding(16)
        .background(rowBackground)
        // Leading stakes/time bar. Added before the clip so its outer
        // corners round with the card; clear (absent) for calm + sitting.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(stakesBarColor ?? .clear)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .taskCompletionEffect(isComplete: $task.isComplete)
        .contentShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .onTapGesture(perform: onOpen)
    }

    /// Leading importance dot. Reads STAKES (not priority) so importance is
    /// one channel app-wide — same mapping as the session picker's dot.
    private var priorityColor: Color {
        switch task.stakes {
        case .high:
            return NudgeTheme.primary
        case .medium:
            return NudgeTheme.textMuted.opacity(0.6)
        case .low, .none:
            return NudgeTheme.textMuted
        }
    }

    // MARK: - Stakes row treatment (display only)
    //
    // First match wins. Time-pressure states (overdue, approaching) outrank
    // the calm high-stakes state. The amber "High" pill and the leading dot
    // are computed separately and do NOT depend on this — importance shows
    // regardless of which time state the row is in.

    private enum StakesRowTreatment: Equatable {
        case overdue                // stakes medium|high AND past deadline
        case approaching            // stakes high AND deadline within N days
        case highStakes             // stakes high, no time pressure
        case sitting(days: Int)     // stakes low, undated, aging
        case none
    }

    private var rowTreatment: StakesRowTreatment {
        // A finished task needs no flagging. Returning .none keeps completed
        // rows exactly as today — no bar, tint, weight bump, or subtitle
        // change — and (with the pill's own guard) no pill either.
        guard !task.isComplete else { return .none }

        let stakes = task.stakes
        // Overdue is a factual state, so everything past due reads
        // overdue-red EXCEPT deliberately low-stakes tasks, which we protect
        // from red. nil (unclassified) is not low, so it still shows overdue.
        if task.isOverdue, stakes != .low {
            return .overdue
        }
        if stakes == .high, isApproaching {
            return .approaching
        }
        if stakes == .high {
            return .highStakes
        }
        if stakes == .low,
           task.dueDate == nil, task.specificTime == nil,
           let days = daysSitting, days >= NudgeConfig.stakesSittingDays {
            return .sitting(days: days)
        }
        return .none
    }

    /// "Approaching" = deadline within `stakesApproachingDays` calendar days,
    /// measured off `sortDeadline`. Deliberately a plain day count and NOT
    /// the EisenhowerScorer urgency curve: that curve is a function of slack
    /// (hoursUntilDue − effortHoursRemaining), so a fixed urgency value maps
    /// to a different day count per task and can't express a clean "3 days."
    /// Keeping this off the curve also keeps the display fully independent of
    /// scoring — the entire reason stakes exists as its own signal.
    private var isApproaching: Bool {
        let deadline = task.sortDeadline
        guard deadline != .distantFuture else { return false }
        let now = CountdownClock.shared.now
        let window = Double(NudgeConfig.stakesApproachingDays) * 86_400
        return deadline > now && deadline <= now.addingTimeInterval(window)
    }

    private var daysSitting: Int? {
        Calendar.current.dateComponents(
            [.day], from: task.createdAt, to: CountdownClock.shared.now
        ).day
    }

    /// Card fill. Tinted only for the two time-pressure states; every other
    /// state keeps today's `surface`, so non-special rows are unchanged.
    private var rowBackground: Color {
        switch rowTreatment {
        case .overdue:     return NudgeTheme.overdue.opacity(0.12)
        case .approaching: return NudgeTheme.coral.opacity(0.12)
        default:           return NudgeTheme.surface
        }
    }

    /// Leading edge bar. Amber for calm high-stakes; the time colors when
    /// the row is under time pressure; absent otherwise (sitting shows only
    /// its subtitle, no bar).
    private var stakesBarColor: Color? {
        switch rowTreatment {
        case .overdue:        return NudgeTheme.overdue
        case .approaching:    return NudgeTheme.coral
        case .highStakes:     return NudgeTheme.amber
        case .sitting, .none: return nil
        }
    }

    /// Title weight bumps only in the calm high-stakes state. Under time
    /// pressure the row color carries the signal and the title stays as-is;
    /// non-high rows keep today's weight exactly.
    private var titleFontName: String {
        StakesRowStyle.titleFontName(isHighStakes: rowTreatment == .highStakes)
    }

    /// Subtitle under the title. Returns today's remaining-time line for
    /// normal rows (unchanged), recolors it coral when approaching, and
    /// substitutes the amber "Sitting N days" line for the sitting state
    /// (which has no deadline, hence no remaining-time line of its own).
    private var subtitle: (text: String, color: Color)? {
        if case .sitting(let days) = rowTreatment {
            return ("Sitting \(days) day\(days == 1 ? "" : "s")", NudgeTheme.amber)
        }
        if let dueDate = task.specificTime ?? task.dueDate,
           let remaining = CountdownState.remainingLine(
               dueDate: dueDate, now: CountdownClock.shared.now
           ) {
            let color = (rowTreatment == .approaching)
                ? NudgeTheme.coral : NudgeTheme.textSecondary
            return (remaining, color)
        }
        return nil
    }

    /// VoiceOver label for the title element. Adds stakes + state words on
    /// high-stakes and overdue rows (the two the spec calls out); other rows
    /// keep just the title, and the sitting subtitle is already spoken as
    /// its own text element.
    private var titleAccessibilityLabel: String {
        var parts = [task.title]
        if task.stakes == .high, !task.isComplete { parts.append("High stakes") }
        switch rowTreatment {
        case .overdue:     parts.append("overdue")
        case .approaching: parts.append("due soon")
        default:           break
        }
        return parts.joined(separator: ", ")
    }

    /// Picks the leading word for the CountdownLabel based on what the task
    /// actually is — "Exam Nov 15" reads better than "Due Nov 15" for a
    /// midterm. Falls back to "Due".
    private func countdownPrefix(for task: NudgeTask) -> String {
        let title = task.title.lowercased()
        if title.contains("exam") || title.contains("midterm") || title.contains("final") {
            return "Exam"
        }
        if title.contains("quiz") {
            return "Quiz"
        }
        if title.contains("presentation") {
            return "Presentation"
        }
        return "Due"
    }
}

struct EventRowView: View {
    let task: NudgeTask
    /// True when this event's normalized title appears
    /// `NudgeConfig.routineEventRepeatThreshold`+ times among the section's
    /// events — computed by the parent, since a row can't see its siblings.
    /// The repetition half of `isRoutine` below.
    var titleRepeatsAsRoutine: Bool = false
    /// Tap opens the editor (where the user can reschedule the date/time or
    /// delete). Defaulted so existing previews / call sites still compile.
    var onOpen: () -> Void = {}
    /// Quick trash button — events never "complete," so unlike tasks the
    /// delete affordance is always present on the row itself.
    var onDelete: () -> Void = {}
    /// Flips this event back into a task (isInformationalEvent = false) when
    /// the AI misclassified it. One-tap correction.
    var onConvertToTask: () -> Void = {}
    /// Called with a chosen clock time when the user fills in a missing start
    /// time via the "needs a time" chip.
    var onSetTime: (Date) -> Void = { _ in }

    @State private var showTimePicker = false
    @State private var pickedTime = Date()

    /// An event with no concrete start time needs one before reminders can
    /// fire — surfaced via the "needs a time" chip.
    private var needsTime: Bool { task.specificTime == nil }

    /// A timeless event may also be missing its day entirely. When so, the
    /// chip and picker cover BOTH date and time.
    private var needsDate: Bool { task.dueDate == nil }

    private var chipLabel: String {
        needsDate ? "needs a time and date" : "needs a time"
    }

    // MARK: - Stakes display (parity with TaskRowView)
    //
    // Events borrow only the two importance channels from the task row — the
    // amber "High" pill and the semibold title weight. The time-pressure
    // states (overdue / approaching / sitting) are deliberately absent: an
    // event isn't "completed" or "overdue," the user just shows up.

    /// High-stakes events get the pill + heavier title, exactly like tasks.
    private var isHighStakes: Bool { task.stakes == .high }

    /// "Routine" = a recurring fixture, not a notable commitment: the title
    /// repeats `routineEventRepeatThreshold`+ times (≈ weekly-or-denser within
    /// the 21-day window), stakes below high, already timed (so it isn't the
    /// attention-needing "needs a time" case), and not a work shift — the
    /// `.work` carve-out is insurance so repeated shifts keep full weight.
    /// Repetition was chosen over source-keyed dimming after a real-data
    /// comparison: it catches typed AND imported class meetings; source
    /// caught only imported ones. These render in a lighter title and quieter
    /// icon so exams and needs-a-time events carry the weight in each day.
    private var isRoutine: Bool {
        titleRepeatsAsRoutine
            && task.stakes != .high
            && !needsTime
            && task.taskCategory != .work
    }

    private var titleFontName: String {
        StakesRowStyle.titleFontName(isHighStakes: isHighStakes)
    }

    private var titleColor: Color {
        isRoutine ? NudgeTheme.textSecondary : NudgeTheme.textPrimary
    }

    private var iconColor: Color {
        isRoutine ? NudgeTheme.textMuted : NudgeTheme.primary
    }

    private var iconBackground: Color {
        isRoutine ? NudgeTheme.surfaceAlt : NudgeTheme.primary.opacity(0.12)
    }

    /// Folds "High stakes" into the title's VoiceOver label, mirroring
    /// TaskRowView so the hidden pill's meaning is still announced.
    private var titleAccessibilityLabel: String {
        isHighStakes ? "\(task.title), High stakes" : task.title
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: task.specificTime == nil ? "calendar" : "calendar.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(iconBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.custom(titleFontName, size: 15))
                    .foregroundColor(titleColor)
                    .accessibilityLabel(titleAccessibilityLabel)

                // Events use their own timing phrasing (Today / Tomorrow /
                // In N days, date / date) — NOT the task-style "hours left /
                // days away" countdown.
                if let eventLine = CountdownState.eventLine(
                    specificTime: task.specificTime,
                    dueDate: task.dueDate,
                    now: CountdownClock.shared.now
                ) {
                    Text(eventLine)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(NudgeTheme.textSecondary)
                }

                // "needs a time" chip — opens an inline time picker. Tapping
                // it must NOT also trigger the row's edit tap, so it lives in
                // its own button.
                if needsTime {
                    Button {
                        NudgeHaptics.light()
                        pickedTime = task.specificTime ?? task.dueDate ?? Date()
                        showTimePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text(chipLabel)
                                .font(.custom(NudgeTheme.fontMedium, size: 11))
                        }
                        .foregroundColor(NudgeTheme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(NudgeTheme.primary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // One-tap "this is actually a task" correction.
            Button(action: onConvertToTask) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
                    .frame(width: 30, height: 30)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Convert to task")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
                    .frame(width: 30, height: 30)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            // High-stakes importance pill — parity with task rows. Last in the
            // row so it sits flush at the trailing edge; hidden from a11y since
            // its text is folded into the title's VoiceOver label.
            if isHighStakes {
                HighStakesPill()
            }
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .onTapGesture(perform: onOpen)
        .sheet(isPresented: $showTimePicker) {
            NavigationStack {
                VStack(spacing: 20) {
                    DatePicker(
                        "Start",
                        selection: $pickedTime,
                        displayedComponents: needsDate ? [.date, .hourAndMinute] : [.hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                    Button {
                        NudgeHaptics.medium()
                        onSetTime(pickedTime)
                        showTimePicker = false
                    } label: {
                        Text("Set time")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NudgeTheme.primary)
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }

                    Spacer()
                }
                .padding(20)
                .background(NudgeTheme.background)
                .navigationTitle("When is \(task.title)?")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showTimePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    /// Events use "Starts" (or "Class starts") instead of "Due" because
    /// they don't get "completed" — the user just shows up.
    private var eventPrefix: String {
        switch task.category {
        case "school": return "Class"
        case "work":   return "Work"
        default:       return "Starts"
        }
    }
}

// MARK: - Task Editor Sheet

struct TaskEditorSheet: View {
    enum Mode {
        case create
        case edit(task: NudgeTask)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let mode: Mode
    let onSave: (TaskDraft) -> Void
    var onDelete: (() -> Void)? = nil
    /// When set (task is placed on today's timeline), shows a button to
    /// remove it from the timeline without deleting the task itself.
    var onRemoveFromTimeline: (() -> Void)? = nil

    @State private var draft = TaskDraft()

    /// In edit mode, the AI-derived first step for this task so the
    /// under-3-hour CountdownLabel can suggest it. Pure READ — enrichment
    /// (if the cache is stale/missing) is kicked off separately from the
    /// editor's `.task` below, never as a side effect of this getter.
    private var suggestedFirstStep: String? {
        guard case .edit(let task) = mode else { return nil }
        let intel = NudgeIntelligence.shared.cachedIntelligence(
            for: task,
            modelContext: modelContext
        )
        return intel.suggestedFirstStep
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Task title", text: $draft.title, axis: .vertical)
                            .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                            .foregroundColor(NudgeTheme.textPrimary)

                        // Live countdown — the editor sheet is the only place
                        // where the "Want to start on this now?" suggestion
                        // appears (per spec rule 5). Tapping the suggestion
                        // dismisses the sheet so the user can hit Start Session.
                        // The AI's suggested first step shows underneath as
                        // a small subtitle to lower activation energy.
                        CountdownLabel(
                            dueDate: draft.specificTime ?? draft.dueDate,
                            prefix: countdownPrefix(forTitle: draft.title),
                            showsActionSuggestion: true,
                            suggestedFirstStep: suggestedFirstStep,
                            onStartNow: { dismiss() }
                        )

                        Text("Edit details, reschedule, or remove the task.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                    }

                    editorSection(title: "Reschedule") {
                        HStack(spacing: 10) {
                            quickDateChip(title: "Today", offset: 0)
                            quickDateChip(title: "Tomorrow", offset: 1)
                            quickDateChip(title: "Next Week", offset: 7)
                        }

                        HStack(spacing: 10) {
                            Button(action: {
                                NudgeHaptics.light()
                                draft.clearDueDate()
                            }) {
                                Text("No date")
                                    .font(.custom(NudgeTheme.fontMedium, size: 13))
                                    .foregroundColor(NudgeTheme.textPrimary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(NudgeTheme.surfaceAlt)
                                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                            }

                            Spacer()
                        }

                        DatePicker(
                            "Due",
                            selection: Binding(
                                get: { draft.specificTime ?? draft.defaultDateForPicker },
                                set: { draft.setSpecificTime($0) }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                    }

                    editorSection(title: "Importance") {
                        HStack(spacing: 10) {
                            stakesChip(title: "High", value: .high)
                            stakesChip(title: "Medium", value: .medium)
                            stakesChip(title: "Low", value: .low)
                        }
                    }

                    if let onRemoveFromTimeline {
                        Button(action: {
                            onRemoveFromTimeline()
                            dismiss()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar.badge.minus")
                                Text("Remove from timeline")
                            }
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(NudgeTheme.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(NudgeTheme.primary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        }
                        .buttonStyle(.plain)
                    }

                    if let onDelete {
                        Button(role: .destructive, action: {
                            onDelete()
                            dismiss()
                        }) {
                            Text("Delete task")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle(modeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        NudgeHaptics.medium()
                        onSave(draft.cleaned())
                        dismiss()
                    }
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                }
            }
        }
        .onAppear(perform: populateDraftIfNeeded)
    }

    private var modeTitle: String {
        switch mode {
        case .create:
            return "New Task"
        case .edit:
            return "Task Details"
        }
    }

    /// Mirror of the helper on TaskRowView — picks the leading word for
    /// the live countdown based on the task title.
    private func countdownPrefix(forTitle title: String) -> String {
        let t = title.lowercased()
        if t.contains("exam") || t.contains("midterm") || t.contains("final") { return "Exam" }
        if t.contains("quiz") { return "Quiz" }
        if t.contains("presentation") { return "Presentation" }
        return "Due"
    }

    private func quickDateChip(title: String, offset: Int) -> some View {
        Button(action: {
            NudgeHaptics.light()
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            draft.setDate(date)
        }) {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(NudgeTheme.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
    }

    /// Stakes selector chip. Writes `draft.stakes` and flags the choice as
    /// user-made so the save path can set `stakesIsUserSet` (which makes
    /// `setStakesFromAutomation` a no-op on the row thereafter). Priority is
    /// no longer surfaced or edited here; it stays in the model untouched.
    private func stakesChip(title: String, value: TaskStakes) -> some View {
        let isSelected = draft.stakes == value
        return Button(action: {
            NudgeHaptics.light()
            draft.stakes = value
            draft.stakesUserPicked = true
        }) {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(isSelected ? .white : NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isSelected ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
    }

    private func editorSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                .foregroundColor(NudgeTheme.textPrimary)

            content()
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func populateDraftIfNeeded() {
        guard case .edit(let task) = mode else { return }
        draft = TaskDraft(
            title: task.title,
            priority: task.priority,
            dueDate: task.dueDate,
            specificTime: task.specificTime
        )
        // Show the task's current stakes selected, WITHOUT marking it a fresh
        // user choice — only tapping a chip sets stakesUserPicked, so simply
        // opening + saving a row can't lock an automation-set value.
        draft.stakes = task.stakes
        // Explicit enrichment trigger. The `suggestedFirstStep` getter is
        // now a pure read (it used to kick off a refresh on cache miss);
        // opening the editor is the moment to (re)analyze so the suggestion
        // populates. refreshSoon is single-flight, so this is a no-op if a
        // refresh is already running or the cache is fresh enough that no
        // caller has invalidated it.
        NudgeIntelligence.shared.refreshSoon(for: task)
    }
}

// MARK: - Session Task Picker

struct SessionTaskPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let tasks: [NudgeTask]
    let onPick: (NudgeTask) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What are you working on?")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .padding(.bottom, 4)

                    Text("Pick a task to focus on. The session ends when you complete it or stop the timer.")
                        .font(.custom(NudgeTheme.fontBody, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                        .padding(.bottom, 8)

                    if tasks.isEmpty {
                        VStack(spacing: 8) {
                            Text("No tasks to focus on")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                                .foregroundColor(NudgeTheme.textPrimary)
                            Text("Add a task first, then start a session.")
                                .font(.custom(NudgeTheme.fontBody, size: 13))
                                .foregroundColor(NudgeTheme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(tasks, id: \.id) { task in
                            Button {
                                NudgeHaptics.medium()
                                onPick(task)
                            } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    Circle()
                                        .fill(priorityColor(task))
                                        .frame(width: 10, height: 10)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(task.title)
                                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                                            .foregroundColor(NudgeTheme.textPrimary)
                                            .multilineTextAlignment(.leading)

                                        Text(durationLabel(task))
                                            .font(.custom(NudgeTheme.fontBody, size: 13))
                                            .foregroundColor(NudgeTheme.textMuted)
                                    }

                                    Spacer()

                                    Image(systemName: "play.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(NudgeTheme.primary)
                                }
                                .padding(16)
                                .background(NudgeTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                                .overlay(
                                    RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                                        .stroke(NudgeTheme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle("Start Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Leading importance dot — reads STAKES (not priority), matching
    /// TaskRowView so importance is one channel app-wide.
    private func priorityColor(_ task: NudgeTask) -> Color {
        switch task.stakes {
        case .high: return NudgeTheme.primary
        case .medium: return NudgeTheme.textMuted.opacity(0.6)
        case .low, .none: return NudgeTheme.textMuted
        }
    }

    private func durationLabel(_ task: NudgeTask) -> String {
        let minutes = task.estimatedMinutes ?? 60
        return "\(minutes) min session"
    }
}

// MARK: - Completed Tasks Sheet

struct WeeklyCompletedSheet: View {
    @Environment(\.dismiss) private var dismiss

    let records: [CompletedTaskRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if records.isEmpty {
                        emptyState
                    } else {
                        Text("\(records.count) task\(records.count == 1 ? "" : "s") completed this week")
                            .font(.custom(NudgeTheme.fontBody, size: 13))
                            .foregroundColor(NudgeTheme.textMuted)
                            .padding(.bottom, 4)

                        ForEach(records, id: \.id) { record in
                            recordRow(record)
                        }
                    }
                }
                .padding(20)
            }
            .background(NudgeTheme.background)
            .navigationTitle("Completed This Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundColor(NudgeTheme.textMuted)

            Text("No tasks completed yet")
                .font(.custom(NudgeTheme.fontSemiBold, size: 17))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("Tasks you check off this week will appear here.")
                .font(.custom(NudgeTheme.fontBody, size: 13))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func recordRow(_ record: CompletedTaskRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(NudgeTheme.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)

                Text(timestampLabel(for: record.completedAt))
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            Spacer()
        }
        .padding(14)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func timestampLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today, \(date.formatted(date: .omitted, time: .shortened))"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))"
        }
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "EEEE 'at' h:mm a"
        return weekdayFmt.string(from: date)
    }
}

// MARK: - Supporting Types

struct TaskDraft {
    var title = ""
    var priority = "medium"
    /// User-chosen stakes. Populated from the task on edit so the current
    /// value shows selected, but a save only writes it when the user
    /// actually tapped a chip (`stakesUserPicked`) — opening a row and
    /// saving without touching stakes must not lock an automation-set value.
    var stakes: TaskStakes? = nil
    var stakesUserPicked = false
    var dueDate: Date? = nil
    var specificTime: Date? = nil

    var defaultDateForPicker: Date {
        specificTime ?? dueDate ?? Date()
    }

    var dueTimeLabel: String? {
        guard let dueDate else { return nil }
        if let specificTime {
            return specificTime.formatted(date: .omitted, time: .shortened)
        }
        return dueDate.formatted(date: .abbreviated, time: .omitted)
    }

    mutating func setDate(_ date: Date) {
        let startOfDay = Calendar.current.startOfDay(for: date)
        dueDate = startOfDay
        specificTime = nil
    }

    mutating func setSpecificTime(_ date: Date) {
        dueDate = Calendar.current.startOfDay(for: date)
        specificTime = date
    }

    mutating func clearDueDate() {
        dueDate = nil
        specificTime = nil
    }

    func cleaned() -> TaskDraft {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

enum TaskSheetDestination: Identifiable {
    case create
    case edit(taskID: UUID)
    /// Small window shown when a PLACED task's timeline block is tapped —
    /// holds the "Remove from timeline" button.
    case manageTimeline(taskID: UUID)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let taskID):
            return "edit-\(taskID.uuidString)"
        case .manageTimeline(let taskID):
            return "manage-\(taskID.uuidString)"
        }
    }
}

struct TaskSortComparator {
    func compare(_ lhs: NudgeTask, _ rhs: NudgeTask) -> Bool {
        let leftBucket = sortBucket(for: lhs)
        let rightBucket = sortBucket(for: rhs)

        if leftBucket != rightBucket {
            return leftBucket < rightBucket
        }

        switch leftBucket {
        case 0, 1:
            return lhs.sortDeadline < rhs.sortDeadline
        case 2:
            return lhs.createdAt < rhs.createdAt
        default:
            return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
        }
    }

    private func sortBucket(for task: NudgeTask) -> Int {
        if task.isComplete {
            return 3
        }
        if task.isOverdue {
            return 0
        }
        if task.sortDeadline != .distantFuture {
            return 1
        }
        return 2
    }
}

// MARK: - Idle confirmation sheet

/// Shown when the user taps "Not yet" on the idle nudge. Surfaces ONE
/// pre-picked task so the user doesn't have to scan the list — the whole
/// point is to cut decision paralysis in half. They can confirm and start
/// a 10-minute session, or escape to the full picker.
struct IdleStartConfirmationSheet: View {
    let task: NudgeTask
    let onConfirm: () -> Void
    let onPickSomethingElse: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(NudgeTheme.border)
                .frame(width: 40, height: 4)
                .padding(.top, 8)

            VStack(spacing: 10) {
                Text("Let's start with")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)

                Text("\(task.title)")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("Just 10 minutes — that's it.")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            VStack(spacing: 10) {
                Button(action: {
                    NudgeHaptics.medium()
                    onConfirm()
                    dismiss()
                }) {
                    Text("Start")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(NudgeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .buttonStyle(.plain)

                Button(action: {
                    NudgeHaptics.light()
                    onPickSomethingElse()
                    dismiss()
                }) {
                    Text("Pick something else")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NudgeTheme.background)
    }
}

extension NudgeTask {
    var subtitle: String {
        var parts: [String] = []

        if let dueLabel {
            parts.append(dueLabel)
        } else {
            parts.append("No due date")
        }

        parts.append(priority.capitalized)
        return parts.joined(separator: " • ")
    }

    var dueLabel: String? {
        if let specificTime {
            return specificTime.formatted(date: .abbreviated, time: .shortened)
        }

        if let dueDate {
            return dueDate.formatted(date: .abbreviated, time: .omitted)
        }

        return nil
    }

    var sortDeadline: Date {
        if let specificTime {
            return specificTime
        }

        if let dueDate {
            let start = Calendar.current.startOfDay(for: dueDate)
            return Calendar.current.date(byAdding: .day, value: 1, to: start) ?? dueDate
        }

        return .distantFuture
    }

    var isOverdue: Bool {
        guard !isComplete else { return false }
        return sortDeadline < Date()
    }
}
