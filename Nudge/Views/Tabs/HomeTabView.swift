//
//  HomeTabView.swift
//  Nudge
//
//  Brain dump capture screen — the main Home tab.
//

import SwiftUI
import SwiftData
import UIKit
import WidgetKit

struct HomeTabView: View {
    let profile: UserProfile
    @Binding var selectedTab: AppTab

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \DailySession.startedAt, order: .reverse) private var sessions: [DailySession]
    @Query private var allTasks: [NudgeTask]
    @Query(filter: #Predicate<NudgeTask> { !$0.isComplete }) private var incompleteTasks: [NudgeTask]
    /// Expanded commitments — the memory behind "a second module of the
    /// same course should not ask again". Unbounded @Query is fine: one
    /// row per expanded commitment, a handful ever.
    @Query private var commitments: [NudgeCommitment]
    /// Active goals feed the capture prompt as matching context (item 2,
    /// cycle 2026-08-04-03). Unbounded is fine — a handful of rows.
    @Query(sort: \NudgeGoal.createdAt) private var allGoals: [NudgeGoal]

    @State private var composerText = ""
    @State private var messages: [HomeChatMessage] = []
    @State private var isWaitingForAI = false
    /// Mirrors `UNUserNotificationCenter.notificationSettings().authorizationStatus`.
    /// We surface a banner when iOS says denied but the user thinks they
    /// have notifications on — otherwise the entire notification pipeline
    /// silently never fires.
    @State private var notificationAuthState: NudgeNotificationService.AuthorizationState = .notDetermined
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if shouldShowPermissionBanner {
                        notificationsDisabledBanner
                    }
                    chatThread
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .background(
                LinearGradient(
                    colors: [NudgeTheme.background, NudgeTheme.surfaceAlt],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .safeAreaInset(edge: .bottom) {
                sendBar
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                loadConversation()
                // Register this view's send action so the floating tab-bar
                // button can invoke it when the user has typed something.
                ChatComposerStore.shared.sendAction = { sendMessage() }
                ChatComposerStore.shared.updateHasSendableText(from: composerText)
                ChatComposerStore.shared.isWaitingForAI = isWaitingForAI
                Task { @MainActor in await refreshNotificationAuthState() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // The user may have flipped the OS permission while we were
                // backgrounded. Re-read the system state on every return so
                // the banner appears / disappears immediately.
                if newPhase == .active {
                    Task { @MainActor in await refreshNotificationAuthState() }
                }
            }
            .onDisappear {
                // Clear the action so the tab-bar button reverts to its
                // navigation behavior when the user leaves the chat tab.
                ChatComposerStore.shared.reset()
            }
            .onChange(of: composerText) { _, newValue in
                // ChatComposerStore only flips its Bool when the value
                // actually changes — so the tab bar re-renders on first
                // keystroke and on last, not on every key between.
                ChatComposerStore.shared.updateHasSendableText(from: newValue)
            }
            .onChange(of: isWaitingForAI) { _, newValue in
                ChatComposerStore.shared.isWaitingForAI = newValue
            }
            .onChange(of: sessions.first?.id) { _, _ in
                loadConversation()
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(NudgeAnimation.standard) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// True only when iOS denied notifications but the user's in-app
    /// preference still says they want them on — i.e. the silent-failure
    /// case. If the user has flipped the in-app toggle off themselves, we
    /// don't pester them.
    private var shouldShowPermissionBanner: Bool {
        notificationAuthState == .denied && profile.notificationsEnabled
    }

    private var notificationsDisabledBanner: some View {
        Button {
            NudgeHaptics.light()
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(NudgeTheme.danger)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are turned off")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        .foregroundColor(NudgeTheme.textPrimary)
                    Text("Tap to fix")
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.danger.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func refreshNotificationAuthState() async {
        let state = await NudgeNotificationService.shared.authorizationState()
        await MainActor.run { notificationAuthState = state }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AccountShortcutButton(selectedTab: $selectedTab)

            VStack(alignment: .leading, spacing: 4) {
                Text("Hi \(profile.name.isEmpty ? "there" : profile.name)")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 28))
                    .foregroundColor(NudgeTheme.textPrimary)

                Text("Write it however it comes out.")
                    .font(.custom(NudgeTheme.fontBody, size: 15))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            Spacer()

            MascotAvatarView(size: 48)
        }
    }

    private var chatThread: some View {
        VStack(alignment: .leading, spacing: 14) {
            if messages.isEmpty {
                homeBubble(
                    text: "Send me anything exactly how it comes to mind. I'll help turn it into a plan.",
                    role: .assistant
                )
            } else {
                ForEach(messages) { message in
                    homeBubble(text: message.text, role: message.role)
                        .id(message.id)
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sendBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(NudgeTheme.border)
                .frame(height: 1)

            // Send action lives on the floating tab-bar button now.
            ZStack(alignment: .topLeading) {
                if composerText.isEmpty {
                    Text("Type a message")
                        .font(.custom(NudgeTheme.fontBody, size: 15))
                        .foregroundColor(NudgeTheme.textPlaceholder)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }

                TextEditor(text: $composerText)
                    .font(.custom(NudgeTheme.fontBody, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 52, maxHeight: 120)
                    .background(Color.clear)
                    .focused($isComposerFocused)
            }
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }

    private var trimmedComposerText: String {
        composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func homeBubble(text: String, role: HomeChatRole) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            if role == .assistant {
                MascotAvatarView(size: 34)
            } else {
                Spacer(minLength: 44)
            }

            Text(text)
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(role == .assistant ? NudgeTheme.textPrimary : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(role == .assistant ? NudgeTheme.surface : NudgeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))

            if role == .assistant {
                Spacer(minLength: 44)
            } else {
                Color.clear
                    .frame(width: 34, height: 34)
            }
        }
    }

    private func sendMessage() {
        guard !trimmedComposerText.isEmpty else {
            NudgeHaptics.error()
            return
        }

        NudgeHaptics.medium()
        let messageText = trimmedComposerText
        let userMessage = HomeChatMessage(role: .user, text: messageText)
        messages.append(userMessage)
        composerText = ""
        isComposerFocused = false
        isWaitingForAI = true

        // ── CLAUDE API INTEGRATION ──────────────────────────────────────
        // Calls ClaudeService.sendChat() with the full conversation history.
        // The API extracts tasks, assigns priorities, estimates durations,
        // and returns a conversational response + structured task data.
        // ────────────────────────────────────────────────────────────────
        Task {
            // Plan/restructure intent → route to the AI day-plan refiner
            // instead of the brain-dump prompt. Still counts as a chat turn.
            if isPlanIntent(messageText) {
                await handlePlanIntent()
                isWaitingForAI = false
                return
            }
            do {
                let history = messages.dropLast().map { msg in
                    ChatMessage(
                        role: msg.role == .user ? "user" : "assistant",
                        content: msg.text
                    )
                }

                // Build existing task context — only incomplete tasks so the AI
                // doesn't see stale dates from old completed tasks
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")

                let existingContext = allTasks
                    .filter { !$0.isComplete }
                    .map { task in
                    ExistingTaskContext(
                        id: task.id.uuidString,
                        title: task.title,
                        priority: task.priority,
                        category: task.category,
                        estimatedMinutes: task.estimatedMinutes,
                        dueDate: task.dueDate.map { dateFormatter.string(from: $0) }
                    )
                }

                // Stable refs for this one call — the model echoes "G1"
                // back in goalRef and we resolve it to the UUID below.
                let goalContexts = allGoals
                    .filter { $0.isActive }
                    .enumerated()
                    .map { index, goal in
                        ActiveGoalContext(ref: "G\(index + 1)", id: goal.id, title: goal.title)
                    }

                let response = try await ClaudeService.shared.sendChat(
                    conversationHistory: Array(history),
                    userMessage: messageText,
                    existingTasks: existingContext,
                    knownCommitmentSizes: knownCommitmentSizes,
                    activeGoals: goalContexts
                )

                // The assistant bubble is appended AFTER updates/creates
                // are applied (cycle 2026-08-03-02 item 3): the start-day
                // follow-up needs the freshly written commitment state to
                // decide whether to append its question or statement to
                // this same closing message.

                // Apply updates to existing tasks (e.g. duration after clarifying
                // question, or a time correction like "actually class is at 9 pm").
                //
                // IMPORTANT: when dueTime or dueDate changes, we must also
                // recompute `specificTime` — that's the canonical sortable
                // Date the rest of the app reads. Without this, the AI says
                // "done!" but the task's real time field never moves.
                if let updates = response.taskUpdates {
                    for update in updates {
                        guard let idString = update.id,
                              let uuid = UUID(uuidString: idString),
                              let existingTask = allTasks.first(where: { $0.id == uuid })
                        else { continue }

                        if let mins = update.estimatedMinutes { existingTask.estimatedMinutes = mins }
                        if let priority = update.priority     { existingTask.priority = normalizedPriority(priority) }
                        if let title = update.title          { existingTask.title = title }
                        if let category = update.category    { existingTask.category = category }
                        if let isComplete = update.isComplete {
                            existingTask.isComplete = isComplete
                            existingTask.completedAt = isComplete ? Date() : nil
                            // Chat-driven completion counts as goal
                            // activity, same as the checkbox.
                            if isComplete {
                                NudgeGoal.recordActivity(
                                    goalID: existingTask.goalID, in: modelContext
                                )
                            }
                        }
                        // The user's answer to a per-day count question —
                        // same clamp as the capture write path.
                        if let count = update.commitmentDailyCount, count > 0 {
                            existingTask.commitmentDailyCount = min(count, 99)
                        }
                        // The user's answer to the app-asked start-day
                        // question ("today" / "tomorrow") — settles the
                        // outstanding ask; the sweep expands on it.
                        if let startDay = update.commitmentStartDay?.lowercased() {
                            let cal = Calendar.current
                            let today = cal.startOfDay(for: Date())
                            if startDay == "tomorrow" {
                                existingTask.commitmentStartDate =
                                    cal.date(byAdding: .day, value: 1, to: today)
                            } else if startDay == "today" {
                                existingTask.commitmentStartDate = today
                            }
                        }

                        // Re-resolve dueDate / dueTime / specificTime together —
                        // any of the three changing requires the other two to
                        // be reconciled. We resolve dueDate first, then time.
                        var newDueDate = existingTask.dueDate
                        var newDueTime = existingTask.dueTime
                        var didChangeTimeFields = false
                        if let dueDateStr = update.dueDate {
                            newDueDate = parseDateString(dueDateStr)
                            existingTask.dueDate = newDueDate
                            didChangeTimeFields = true
                        }
                        if let dueTimeStr = update.dueTime {
                            newDueTime = dueTimeStr
                            existingTask.dueTime = dueTimeStr
                            didChangeTimeFields = true
                        }
                        if didChangeTimeFields {
                            existingTask.specificTime = parseSpecificTime(
                                timeString: newDueTime,
                                on: newDueDate
                            )
                        }
                    }
                }

                // One active plan at a time: if this response captures a NEW
                // ordered plan, clear sequenceIndex on any surviving tasks
                // from the previous plan first. Those tasks aren't deleted —
                // they just drop back into the normal Unscheduled/Scheduled
                // sections. The new plan then owns 1,2,3…
                let incomingIsPlan = response.tasks.contains { $0.sequenceIndex != nil }
                if incomingIsPlan {
                    for task in allTasks where task.sequenceIndex != nil {
                        task.sequenceIndex = nil
                    }
                }

                // Persist only genuinely NEW tasks
                var newlyCreatedTasks: [NudgeTask] = []
                // Drop-trace (cycle 2026-08-05-02): every item the model
                // returned that does NOT become a row is recorded here with
                // its reason, and reconciled against the returned count after
                // the loop. The Sep 2 event vanished with zero evidence of
                // whether the model omitted it or the app dropped it; this
                // makes that distinction one console line.
                var droppedItems: [(title: String, reason: String)] = []
                for taskData in response.tasks {
                    let newTitle = taskData.title.lowercased()
                    let newDueDate = parseDateString(taskData.dueDate)

                    // Only skip if an INCOMPLETE task with the same title exists
                    // for the SAME day. Completed tasks from previous days should
                    // not block creating a fresh task for today.
                    // `first(where:)` instead of `contains` so the suppressing
                    // row can be NAMED in the drop log — same predicate.
                    let duplicateOf = allTasks.first { existing in
                        guard !existing.isComplete else { return false }
                        let existingTitle = existing.title.lowercased()
                        let titleMatch = existingTitle == newTitle
                            || existingTitle.contains(newTitle)
                            || newTitle.contains(existingTitle)
                        guard titleMatch else { return false }

                        if let existingDue = existing.dueDate, let newDue = newDueDate {
                            return Calendar.current.isDate(existingDue, inSameDayAs: newDue)
                        }
                        return true
                    }
                    if let duplicateOf {
                        // Which clause suppressed it: both dates present means
                        // the same-day comparison matched; otherwise it was
                        // the nil-date fallthrough (title match alone).
                        let clause = (duplicateOf.dueDate != nil && newDueDate != nil)
                            ? "same-day" : "nil-date fallthrough"
                        droppedItems.append((taskData.title,
                            "dedupe vs \"\(duplicateOf.title)\" (\(clause))"))
                        #if DEBUG
                        print("[HomeTabView] DROP: \"\(taskData.title)\" suppressed by dedupe — matched existing \"\(duplicateOf.title)\" via \(clause)")
                        #endif
                        continue
                    }

                    // Parse dueTime ("3:00 PM") combined with dueDate into specificTime.
                    let specificTime = parseSpecificTime(timeString: taskData.dueTime, on: newDueDate)

                    // Events keep their event classification even without a
                    // time now — a timeless event lands in the Events list with
                    // a "needs a time" chip, and the AI's reply asks for the
                    // time in one follow-up question. (Previously we demoted
                    // timeless events to tasks; that hid genuine plans.)
                    let isEvent = taskData.isEvent ?? false

                    // DUE vs START (cycle 2026-09-03-01): a task's date is a
                    // deadline ONLY when the model said so. "start" (or a
                    // missing/unknown dueKind — the cheap wrong guess) means
                    // the date is an INTENTION: it goes to intendedDate, plus
                    // a manual placement when a clock time was stated, and
                    // the deadline fields stay nil so no countdown, overdue
                    // state, or dueSoon nudge can ever fabricate from it.
                    // Events are untouched: their time is their time.
                    let isDeadline = isEvent || taskData.dueKind?.lowercased() == "deadline"
                    let intentDay: Date? = (!isDeadline && newDueDate != nil)
                        ? Calendar.current.startOfDay(for: newDueDate!) : nil
                    let intentStart: Date? = isDeadline ? nil : specificTime

                    // Floater detection: no date AND no time → low-priority,
                    // "get to it whenever" task. Force low priority unless the
                    // AI explicitly said high.
                    let isFloater = !isEvent && newDueDate == nil && specificTime == nil
                    // Canonical set is high|medium|low. "urgent" left the
                    // prompt's allowed values (Jul 2026) but the model may
                    // still emit it — fold it into "high" at the write site
                    // so no fourth value ever reaches the store again.
                    let rawPriority = normalizedPriority(taskData.priority ?? "medium")
                    let priority: String = {
                        guard isFloater else { return rawPriority }
                        return rawPriority == "high" ? rawPriority : "low"
                    }()

                    let task = NudgeTask(
                        title: taskData.title,
                        dueDate: isDeadline ? newDueDate : nil,
                        dueTime: isDeadline ? taskData.dueTime : nil,
                        specificTime: isDeadline ? specificTime : nil,
                        priority: priority,
                        category: taskData.category,
                        source: "capture",
                        estimatedMinutes: taskData.estimatedMinutes,
                        recurrence: taskData.recurrence,
                        isInformationalEvent: isEvent,
                        // Ordered-plan position ("first X, then Y") — nil for
                        // items the user didn't sequence. Never sets a timeline
                        // placement; a plan is a numbered list, not a schedule.
                        sequenceIndex: isEvent ? nil : taskData.sequenceIndex
                    )
                    task.intendedDate = intentDay
                    // "Study at 7" is the user scheduling it themselves —
                    // a MANUAL placement (plannedIsAuto stays false), which
                    // the timeline, planners, and placement nudges already
                    // understand. PlacementRollover clears it if the day
                    // passes unstarted; intendedDate above survives as the
                    // record of the slip.
                    if let intentStart {
                        task.plannedStartDate = intentStart
                        // A stated start with no stated length is an hour
                        // (Roman's rule, Sep 2026) — without this the block
                        // draws at the 30-minute task fallback and the busy
                        // math undercounts the session.
                        if task.estimatedMinutes == nil {
                            task.estimatedMinutes = NudgeConfig.defaultTimedIntentMinutes
                        }
                    }
                    // Stakes writes go through the one guarded automation
                    // path (never the init) so every non-user writer
                    // inherits the user-override protection. Unknown or
                    // missing strings parse to nil and leave stakes unset.
                    task.setStakesFromAutomation(TaskStakes.parse(taskData.stakes))
                    // Study-lead band — meaningful only on exam events;
                    // band-validated (3|7|14, else nil) so no invented
                    // precision reaches the store.
                    if isEvent {
                        task.prepLeadDays = ExamPrepSweep.validLeadBand(taskData.prepLeadDays)
                    } else {
                        // Appropriateness band — tasks only (events aren't
                        // placed). Unknown strings parse to nil, which
                        // falls to the deterministic inference at read.
                        task.timeWindow = TaskTimeWindow.parse(taskData.timeWindow)
                        // Commitment shape (cycle 2026-08-03-01) — marks the
                        // task for expansion into daily tasks once its
                        // numbers are known. Unknown strings parse to nil:
                        // the task stays an ordinary task, the safe default.
                        task.commitmentShape = CommitmentShape.parse(taskData.commitmentShape)
                        if let count = taskData.commitmentDailyCount, count > 0 {
                            task.commitmentDailyCount = min(count, 99)
                        }
                        // Second name from capture: the short session name
                        // the dailies will carry (the task's own title is
                        // the goal name). Only meaningful alongside a
                        // shape; blank or missing stays nil and expansion
                        // falls back to the goal name.
                        if task.commitmentShape != nil,
                           let session = taskData.commitmentSessionTitle?
                               .trimmingCharacters(in: .whitespacesAndNewlines),
                           !session.isEmpty {
                            task.commitmentSessionTitle = session
                        }
                        // Goal link (item 2, cycle 2026-08-04-03): resolve
                        // the model's ref back to the goal's UUID. Tasks
                        // only — an unknown ref (hallucinated, or a goal
                        // deactivated mid-conversation) resolves to nil,
                        // the safe default.
                        if let ref = taskData.goalRef,
                           let matched = goalContexts.first(where: { $0.ref == ref }) {
                            task.goalID = matched.id
                            #if DEBUG
                            print("[GoalLink] \"\(task.title)\" → goal \"\(matched.title)\" (\(ref))")
                            #endif
                        }
                    }
                    modelContext.insert(task)
                    newlyCreatedTasks.append(task)
                }

                // Count reconciliation: returned = inserted + dropped, every
                // drop named. A mismatch against what the user said is now
                // readable in one line instead of counting parsed-date prints.
                #if DEBUG
                print("[HomeTabView] CAPTURE: returned=\(response.tasks.count) inserted=\(newlyCreatedTasks.count) dropped=\(droppedItems.count)")
                for item in droppedItems {
                    print("[HomeTabView]   dropped \"\(item.title)\": \(item.reason)")
                }
                #endif

                // Start-day follow-up (item 3, cycle 2026-08-03-02):
                // decided app-side with the same arithmetic the sweep
                // uses — the model is never trusted with it — and
                // appended to the SAME closing message.
                var assistantText = response.message
                if let followUp = commitmentStartDayFollowUp(newlyCreated: newlyCreatedTasks) {
                    let trimmed = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
                    assistantText = trimmed.isEmpty ? followUp : trimmed + " " + followUp
                }
                messages.append(HomeChatMessage(role: .assistant, text: assistantText))

                persistSession()

                // NOT `try?` (cycle 2026-08-05-02): a failed save here
                // discarded the whole batch AFTER the chat had already shown
                // it as captured — the worst version of a silent drop. The
                // user is told the fact (save failed, retry) with no invented
                // cause; the inserts stay in the context, so the retry path
                // is the next successful save, not re-entry.
                do {
                    try modelContext.save()
                } catch {
                    #if DEBUG
                    print("[HomeTabView] SAVE FAILED after capture: \(error)")
                    #endif
                    messages.append(HomeChatMessage(
                        role: .assistant,
                        text: "I couldn't save that just now. If it's not in your list, send it again."
                    ))
                    persistSession()
                }

                if !response.tasks.isEmpty || response.taskUpdates?.isEmpty == false {
                    WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                    // Kick off intelligence analysis for each new task so
                    // get-ahead nudges fire at recommendedStartBy.
                    for task in newlyCreatedTasks {
                        NudgeIntelligence.shared.refreshSoon(for: task)
                    }
                    // Expand any commitment whose numbers are now known —
                    // covers both the fully-specified capture ("an hour a
                    // day until Friday") and the answer turn that just
                    // filled in the missing number via task_updates.
                    // BEFORE the reevaluate, so fresh dailies are in the
                    // store when candidates are built.
                    ExamPrepSweep.shared.run(modelContext: modelContext)
                    // Single arbiter call replaces every per-feature scheduler.
                    NudgeArbiter.shared.reevaluate(
                        reason: .taskCreatedOrEdited,
                        profile: profile,
                        modelContext: modelContext
                    )
                }
            } catch {
                #if DEBUG
                print("[HomeTabView] API error: \(error)")
                #endif

                var errorText: String
                if let claudeError = error as? ClaudeError {
                    switch claudeError {
                    case .missingAPIKey:
                        errorText = "I'm not set up yet — my API key is missing."
                    case .authenticationFailed:
                        errorText = "Hmm, my credentials aren't working. Check the API key in Settings."
                    case .rateLimitExceeded:
                        errorText = "I'm getting too many requests right now. Give me a sec and try again."
                    case .parseError:
                        errorText = "I got a little confused with my response. Try sending that again?"
                    default:
                        errorText = "Sorry, something went wrong on my end. Try again in a moment."
                    }
                } else {
                    // Deliberately causeless (cycle 2026-08-05-02): this
                    // branch catches ANY non-ClaudeError — a URLError, but
                    // just as easily a DecodingError from a malformed model
                    // response. "Check your internet" asserted a diagnosis
                    // the app doesn't have (fabricated precision, per
                    // DESIGN.md), and sent users retrying a network that was
                    // fine. State the two things actually known: it didn't
                    // go through, and nothing from it was saved — the throw
                    // precedes every insert, which is what makes "try again"
                    // safe to say.
                    errorText = "That didn't go through — nothing from it was saved. Try sending it again."
                    #if DEBUG
                    errorText += " [\(type(of: error))]"
                    #endif
                }

                let fallback = HomeChatMessage(role: .assistant, text: errorText)
                messages.append(fallback)
                persistSession()
            }

            isWaitingForAI = false
        }
    }

    /// The start-today-or-tomorrow flow (cycle 2026-08-03-02 item 3),
    /// run over every unexpanded, fully-specified commitment parent this
    /// turn touched. Decided deterministically with the sweep's own
    /// arithmetic — the model never computes room or session growth:
    ///   • no room today → start tomorrow silently (a question with one
    ///     answer is noise; the message box announcement says "from
    ///     tomorrow")
    ///   • dropping today would grow the sessions → start today and SAY
    ///     so (no choice to offer, so state what's happening)
    ///   • both genuinely available → ask, and hold that commitment's
    ///     expansion until the answer (or until the day rolls over and
    ///     the question expires)
    /// At most one appended sentence per turn — the flow is capped at
    /// two questions for a reason; a second choice-commitment in the
    /// same dump just expands on the default.
    private func commitmentStartDayFollowUp(newlyCreated: [NudgeTask]) -> String? {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        // New parents first (the @Query may not reflect this turn's
        // inserts yet), then surviving existing ones, deduped.
        let newIDs = Set(newlyCreated.map(\.id))
        let candidates = newlyCreated + allTasks.filter { !newIDs.contains($0.id) }

        var sentence: String?
        for parent in candidates {
            guard parent.commitmentShapeRaw != nil,
                  parent.commitmentStartDate == nil,
                  parent.commitmentStartAskedAt == nil,
                  let shape = ExamPrepSweep.expansionReadiness(parent, today: today),
                  let due = parent.dueDate else { continue }

            let decision = ExamPrepSweep.startDayDecision(
                shape: shape,
                totalMinutes: shape == .splitWork ? parent.estimatedMinutes : nil,
                dailyMinutes: shape == .rate ? parent.estimatedMinutes : nil,
                category: parent.taskCategory,
                endDay: cal.startOfDay(for: due),
                now: now,
                profile: profile
            )
            switch decision {
            case .tomorrowOnly:
                parent.commitmentStartDate = cal.date(byAdding: .day, value: 1, to: today)
            case .todayForced:
                if sentence == nil {
                    sentence = "I'm starting “\(parent.title)” today — waiting until "
                        + "tomorrow would make each session longer."
                }
            case .choice:
                if sentence == nil {
                    parent.commitmentStartAskedAt = now
                    sentence = "Want to start “\(parent.title)” today, or from tomorrow?"
                }
            }
        }
        return sentence
    }

    /// Previously-answered commitment sizes for the capture prompt's
    /// KNOWN COMMITMENT SIZES context — one line per sized splitWork
    /// commitment. The rows themselves are the memory; matching a new
    /// commitment against them is the model's job (it rides the one
    /// capture call, so there is no second round trip).
    private var knownCommitmentSizes: [String] {
        commitments
            .filter { $0.shape == .splitWork }
            .compactMap { commitment in
                guard let total = commitment.totalMinutes, total > 0 else { return nil }
                let hours = Double(total) / 60
                let sized = hours == hours.rounded()
                    ? "\(Int(hours)) hour\(Int(hours) == 1 ? "" : "s")"
                    : String(format: "%.1f hours", hours)
                return "\"\(commitment.title)\" ≈ \(sized)"
            }
    }

    /// Simple keyword intent: is the user asking to plan / restructure / move
    /// their day around? (Not a brain dump.)
    private func isPlanIntent(_ text: String) -> Bool {
        let t = text.lowercased()
        let phrases = [
            "plan my day", "plan my", "plan out my day", "plan the day",
            "restructure", "reorganize", "reorganise", "rearrange",
            "move things around", "move stuff around", "shuffle my day",
            "organize my day", "organise my day", "redo my schedule",
            "fix my schedule", "replan"
        ]
        return phrases.contains { t.contains($0) }
    }

    /// Runs the AI day-plan refiner and replies in-chat with the rationale.
    /// Gated behind Pro / trial. An explicit chat message → `force: true`.
    private func handlePlanIntent() async {
        guard profile.isPro || profile.isInTrial else {
            messages.append(HomeChatMessage(
                role: .assistant,
                text: "Planning your day with AI is a Pro feature. You can still use “Plan my day” in the Tasks tab any time."
            ))
            persistSession()
            return
        }

        let outcome = await DayPlanRefiner.shared.refine(
            profile: profile,
            modelContext: modelContext,
            force: true
        )
        let reply: String
        switch outcome {
        case .success(let rationale), .cached(let rationale):
            reply = rationale.isEmpty ? "Done — I laid out your day on the timeline." : rationale
        case .noTasks:
            reply = "You're all set — there's nothing open to schedule into today's free time."
        case .notEntitled:
            reply = "Planning your day with AI is a Pro feature."
        case .failed:
            reply = "I couldn't rework the schedule just now. Try again in a moment, or use “Plan my day” in the Tasks tab."
        }
        messages.append(HomeChatMessage(role: .assistant, text: reply))
        persistSession()
    }

    private func persistSession() {
        let allMessages = messages
        // Reuse the latest session only if it was started TODAY. Otherwise
        // create a fresh session so yesterday's transcript doesn't get
        // appended to (and re-fed to the AI as conversation history).
        if let session = sessions.first, Calendar.current.isDateInToday(session.startedAt) {
            session.sessionText = allMessages
                .filter { $0.role == .user }
                .map(\.text)
                .joined(separator: "\n")
            session.chatTranscript = encodeMessages(allMessages)
            session.taskCount = allMessages.filter { $0.role == .user }.count
        } else {
            let session = DailySession(
                sessionText: allMessages.filter { $0.role == .user }.map(\.text).joined(separator: "\n"),
                chatTranscript: encodeMessages(allMessages),
                startedAt: Date(),
                taskCount: allMessages.filter { $0.role == .user }.count,
                targetBedtime: profile.bedtime,
                targetWakeTime: profile.wakeTime
            )
            modelContext.insert(session)
        }
    }

    private func parseDateString(_ dateString: String?) -> Date? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        let parsedDay = parser.date(from: dateString) ?? Date()

        // A bare date (no clock time) means "due by the END of that day."
        // Default to 23:59, NOT midnight — otherwise a task "due today"
        // is instantly overdue against 12:00 AM. When the user gave an
        // explicit time it's applied separately via `specificTime`, which
        // takes precedence in every deadline calculation.
        let calendar = Calendar.current
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: parsedDay) ?? parsedDay

        #if DEBUG
        print("[HomeTabView] Parsed date: input=\"\(dateString)\" → result=\(endOfDay)")
        #endif

        return endOfDay
    }

    /// Combines a date with a clock-time string ("3:00 PM", "15:00") into a
    /// concrete Date. Returns nil for fuzzy values ("morning", "afternoon",
    /// "evening", "night") or when no time/date is given.
    /// Canonical priority vocabulary is high|medium|low. Older prompts
    /// offered "urgent" as a fourth value that every render surface had to
    /// special-case (or silently fell through on); it was dropped from the
    /// prompt Jul 2026 and folds into "high" here so it can never reach the
    /// store again even if the model still emits it. Existing rows were
    /// normalized by `LegacyPriorityNormalizer`.
    private func normalizedPriority(_ raw: String) -> String {
        raw == "urgent" ? "high" : raw
    }

    private func parseSpecificTime(timeString: String?, on date: Date?) -> Date? {
        guard let timeString, !timeString.isEmpty, let date else { return nil }

        let fuzzy: Set<String> = ["morning", "afternoon", "evening", "night"]
        if fuzzy.contains(timeString.lowercased()) { return nil }

        let formats = ["h:mm a", "h a", "HH:mm", "H:mm"]
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        for format in formats {
            let parser = DateFormatter()
            parser.dateFormat = format
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone.current
            if let parsed = parser.date(from: timeString) {
                let hour = calendar.component(.hour, from: parsed)
                let minute = calendar.component(.minute, from: parsed)
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            }
        }
        return nil
    }

    private func loadConversation() {
        // Only restore the transcript if the most recent session was started
        // today. Yesterday's chat history must NOT be sent to the AI, otherwise
        // it re-executes yesterday's "add task X" instructions on today's send.
        guard let session = sessions.first,
              Calendar.current.isDateInToday(session.startedAt) else {
            messages = []
            return
        }

        messages = decodeMessages(from: session.chatTranscript)
    }

    private func encodeMessages(_ messages: [HomeChatMessage]) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(messages),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private func decodeMessages(from transcript: String) -> [HomeChatMessage] {
        guard let data = transcript.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HomeChatMessage].self, from: data) else {
            return transcript.isEmpty ? [] : [HomeChatMessage(role: .assistant, text: transcript)]
        }
        return decoded
    }
}

struct HomeChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: HomeChatRole
    let text: String

    init(id: UUID = UUID(), role: HomeChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum HomeChatRole: String, Codable {
    case user
    case assistant
}
