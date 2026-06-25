//
//  TasksTabView.swift
//  Nudge
//
//  Task list with sorting, editing, and completion animations.
//

import SwiftUI
import SwiftData
import WidgetKit

struct TasksTabView: View {
    let profile: UserProfile
    @Environment(\.modelContext) private var modelContext
    @Query private var tasks: [NudgeTask]
    @Query private var completedRecords: [CompletedTaskRecord]

    @Binding var selectedTab: AppTab
    @State private var activeSheet: TaskSheetDestination?
    @State private var showCancelSessionAlert = false
    @State private var showSessionTaskPicker = false
    @State private var showCompletedSheet = false
    /// Task proposed by the idle nudge's "Not yet" action. When non-nil
    /// we show `IdleStartConfirmationSheet` offering to start a session
    /// on this task with a "pick something else" escape hatch.
    @State private var idleProposedTaskID: UUID?

    private var coordinator: SessionCoordinator { SessionCoordinator.shared }

    private var actionableTasks: [NudgeTask] {
        tasks.filter { !$0.isInformationalEvent }
    }

    private var eventItems: [NudgeTask] {
        tasks
            .filter { $0.isInformationalEvent }
            .sorted { lhs, rhs in
                (lhs.specificTime ?? lhs.dueDate ?? .distantFuture) < (rhs.specificTime ?? rhs.dueDate ?? .distantFuture)
            }
    }

    /// Tasks shown in the main list — informational events excluded AND
    /// completed tasks excluded (they live in the Completed sheet instead).
    private var sortedTasks: [NudgeTask] {
        let comparator = TaskSortComparator()
        return actionableTasks
            .filter { !$0.isComplete }
            .sorted { comparator.compare($0, $1) }
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
                tasksContent
                    .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        .onAppear(perform: purgeOldCompletedRecords)
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
                        modelContext.insert(newTask)
                        try? modelContext.save()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
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
                            try? modelContext.save()
                            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                            refreshNotifications()
                        },
                        onDelete: {
                            modelContext.delete(task)
                            try? modelContext.save()
                            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                            refreshNotifications()
                        }
                    )
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .sheet(isPresented: $showSessionTaskPicker) {
            SessionTaskPickerSheet(
                tasks: actionableTasks.filter { !$0.isComplete },
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
        .onReceive(NotificationCenter.default.publisher(for: .nudgeIdleNotYetTapped)) { note in
            // Posted from the idle "Not yet" delegate handler with the
            // top open task's UUID. The sheet appears the next time this
            // view is on screen (the delegate also requests the Tasks
            // tab via .nudgeNotificationOpenTab).
            guard let uuidString = note.userInfo?["taskID"] as? String,
                  let uuid = UUID(uuidString: uuidString) else { return }
            idleProposedTaskID = uuid
        }
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

    private var tasksContent: some View {
        Group {
            if sortedTasks.isEmpty && eventItems.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if !sortedTasks.isEmpty {
                        sectionLabel("Tasks")

                        VStack(spacing: 12) {
                            ForEach(sortedTasks, id: \.id) { task in
                                TaskRowView(
                                    task: task,
                                    isLastIncompleteTask: incompleteCount == 1 && !task.isComplete,
                                    onOpen: { activeSheet = .edit(taskID: task.id) },
                                    onToggleComplete: { toggleCompletion(for: task) },
                                    onDelete: { deleteTask(task) }
                                )
                            }
                        }
                    }

                    if !eventItems.isEmpty {
                        sectionLabel("Events")

                        VStack(spacing: 12) {
                            ForEach(eventItems, id: \.id) { event in
                                EventRowView(task: event)
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

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.custom(NudgeTheme.fontSemiBold, size: 18))
            .foregroundColor(NudgeTheme.textPrimary)
    }
}

// MARK: - Task Row

struct TaskRowView: View {
    @Bindable var task: NudgeTask
    let isLastIncompleteTask: Bool
    let onOpen: () -> Void
    let onToggleComplete: () -> Void
    let onDelete: () -> Void

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
                        .font(.custom(NudgeTheme.fontMedium, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .strikethrough(task.isComplete, color: NudgeTheme.textMuted)

                    if task.isComplete {
                        AnimatedStrikethrough(isVisible: $task.isComplete)
                    }
                }

                // Subtitle slot — "12 hours left" / "5 days away" / "3 hours ago".
                // Hidden for far-future and at night so the row stays calm
                // when there's no time pressure to communicate.
                if let dueDate = task.specificTime ?? task.dueDate,
                   let remaining = CountdownState.remainingLine(dueDate: dueDate, now: CountdownClock.shared.now) {
                    Text(remaining)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(NudgeTheme.textSecondary)
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
                    .foregroundColor(NudgeTheme.textMuted)
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
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .taskCompletionEffect(isComplete: $task.isComplete)
        .contentShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .onTapGesture(perform: onOpen)
    }

    private var priorityColor: Color {
        switch task.priority {
        case "high":
            return NudgeTheme.primary
        case "medium":
            return NudgeTheme.textMuted.opacity(0.6)
        default:
            return NudgeTheme.textMuted
        }
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

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: task.specificTime == nil ? "calendar" : "calendar.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(NudgeTheme.primary)
                .frame(width: 28, height: 28)
                .background(NudgeTheme.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.custom(NudgeTheme.fontMedium, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)

                if let dueDate = task.specificTime ?? task.dueDate,
                   let remaining = CountdownState.remainingLine(dueDate: dueDate, now: CountdownClock.shared.now) {
                    Text(remaining)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(NudgeTheme.textSecondary)
                }
            }

            Spacer()

            if let dueLine = CountdownState.dueDateLine(
                dueDate: task.dueDate,
                specificTime: task.specificTime
            ) {
                Text(dueLine)
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
            }
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
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

    @State private var draft = TaskDraft()

    /// In edit mode, look up (or kick off) the AI-derived first step for
    /// this task so the under-3-hour CountdownLabel can suggest it.
    private var suggestedFirstStep: String? {
        guard case .edit(let task) = mode else { return nil }
        let intel = NudgeIntelligence.shared.intelligence(
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

                    editorSection(title: "Priority") {
                        HStack(spacing: 10) {
                            priorityChip(title: "High", value: "high")
                            priorityChip(title: "Medium", value: "medium")
                            priorityChip(title: "Low", value: "low")
                        }
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

    private func priorityChip(title: String, value: String) -> some View {
        Button(action: {
            NudgeHaptics.light()
            draft.priority = value
        }) {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 13))
                .foregroundColor(draft.priority == value ? .white : NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(draft.priority == value ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
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

    private func priorityColor(_ task: NudgeTask) -> Color {
        switch task.priority {
        case "high", "urgent": return NudgeTheme.primary
        case "medium": return NudgeTheme.textMuted.opacity(0.6)
        default: return NudgeTheme.textMuted
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

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let taskID):
            return "edit-\(taskID.uuidString)"
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
