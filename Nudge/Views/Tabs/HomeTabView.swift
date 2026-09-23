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
            if Self.isPlanIntent(messageText) {
                await handlePlanIntent()
                isWaitingForAI = false
                return
            }
            // Model router (Sep 2026): pure chitchat skips the ~6¢ Opus
            // capture path and gets a Haiku one-liner (~0.05¢, sub-second).
            // Never while a question from the model is outstanding — a
            // one-word answer like "today" is a task_update in disguise.
            if !hasOutstandingModelQuestion, Self.isSmallTalk(messageText) {
                #if DEBUG
                print("[Router] chitchat → Haiku small-talk lane")
                #endif
                await handleSmallTalk(messageText)
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
                        if let priority = update.priority     { existingTask.priority = CaptureWriter.normalizedPriority(priority) }
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
                            newDueDate = CaptureWriter.parseDateString(dueDateStr)
                            existingTask.dueDate = newDueDate
                            didChangeTimeFields = true
                        }
                        if let dueTimeStr = update.dueTime {
                            newDueTime = dueTimeStr
                            existingTask.dueTime = dueTimeStr
                            didChangeTimeFields = true
                        }
                        if didChangeTimeFields {
                            existingTask.specificTime = CaptureWriter.parseSpecificTime(
                                timeString: newDueTime,
                                on: newDueDate
                            )
                        }
                    }
                }

                // The capture write site lives in `CaptureWriter` (moved
                // verbatim Sep 23 2026 so the eval harness runs the same
                // code). Returns the rows inserted plus the drop trace.
                let written = CaptureWriter.apply(
                    response: response,
                    allTasks: allTasks,
                    goalContexts: goalContexts,
                    modelContext: modelContext,
                    userMessage: messageText
                )
                let newlyCreatedTasks = written.created

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

                // Study-plan question and answer (cycle 2026-09-16-01 item
                // 3). The question is recorded so the one-word answer is
                // routed to capture; the answer is consent or refusal —
                // a Yes builds and writes the plan at once (no second
                // Yes / No in the message box), a No is final for that
                // anchor. Either way the outstanding question clears.
                if let question = response.planQuestion,
                   let parent = planParent(named: question.title, among: newlyCreatedTasks) {
                    PlanQuestionStore.markAsked(parentID: parent.id)
                }
                if let consents = response.planConsent, !consents.isEmpty {
                    for consent in consents {
                        guard let parent = planParent(named: consent.title, among: newlyCreatedTasks) else { continue }
                        if consent.wants {
                            PlanProposalSweep.shared.requestPlan(parentID: parent.id, modelContext: modelContext) { written in
                                guard written > 0 else { return }
                                WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                                NudgeArbiter.shared.reevaluate(
                                    reason: .taskCreatedOrEdited,
                                    profile: profile,
                                    modelContext: modelContext
                                )
                            }
                        } else {
                            PlanProposalSweep.shared.decline(PlanProposalContext(
                                parentID: parent.id, parentTitle: parent.title, reason: "", sessions: []
                            ))
                        }
                    }
                    PlanQuestionStore.clear()
                }

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
                    // A dump may have created an anchored item worth a
                    // plan; the reader judges it (async, proposes only).
                    PlanProposalSweep.shared.runIfNeeded(modelContext: modelContext)
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
                        errorText = "I'm not set up yet, my API key is missing."
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
                    errorText = "That didn't go through, nothing from it was saved. Try sending it again."
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
                    sentence = "I'm starting “\(parent.title)” today, waiting until "
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
    // MARK: - Model router (Sep 2026)

    /// True while the capture model has a question on the table (the
    /// commitment start-day ask). Any reply — however chatty it looks —
    /// must reach the full capture path to become a task_update.
    private var hasOutstandingModelQuestion: Bool {
        allTasks.contains { $0.commitmentStartAskedAt != nil }
            || PlanQuestionStore.outstandingParentID() != nil
    }

    /// The exam the model's study-plan question or answer names: the
    /// open exam event whose title matches, else the parent the question
    /// was recorded for (the model may paraphrase the title back).
    private func planParent(named title: String, among created: [NudgeTask]) -> NudgeTask? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = created + allTasks.filter { task in !created.contains { $0.id == task.id } }
        if let exact = pool.first(where: { !$0.isComplete && $0.title.lowercased() == wanted }) {
            return exact
        }
        if let outstanding = PlanQuestionStore.outstandingParentID(),
           let parent = pool.first(where: { $0.id == outstanding }) {
            return parent
        }
        return pool.first { !$0.isComplete && $0.isInformationalEvent && $0.title.lowercased().contains(wanted) }
    }

    /// Words that mean a message might carry work. Word-boundary matched
    /// (tokens, not substrings) so "that" doesn't trip on "at".
    private static let smallTalkBlockWords: Set<String> = [
        // days & relative time
        "today", "tonight", "tomorrow", "yesterday", "monday", "tuesday",
        "wednesday", "thursday", "friday", "saturday", "sunday", "morning",
        "afternoon", "evening", "night", "noon", "midnight", "week",
        "weekend", "month", "am", "pm", "later", "soon",
        // task-shaped verbs & nouns
        "need", "needs", "do", "doing", "due", "go", "going", "buy", "get",
        "pick", "grab", "call", "text", "email", "send", "pay", "finish",
        "start", "study", "work", "clean", "wash", "laundry", "meet",
        "meeting", "plan", "schedule", "remind", "reminder", "appointment",
        "class", "exam", "quiz", "test", "shift", "gym", "practice",
        "homework", "assignment", "essay", "project", "add", "make",
        "take", "drop", "apply", "application", "interview", "doctor",
        "dentist", "event", "task", "deadline", "cancel", "move", "change"
    ]

    /// The router's cheap-lane gate: TRUE only when the message provably
    /// contains no work. Bias is the whole design — a wrong "chat" verdict
    /// loses a capture (unforgivable); a wrong "task" verdict costs six
    /// cents. So: short, no digits, no day/time/task words, ties to Opus.
    /// Deterministic on purpose — an AI guessing which AI to call would
    /// itself cost a call.
    static func isSmallTalk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let tokens = trimmed.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard tokens.count <= 8, !tokens.isEmpty else { return false }
        return tokens.allSatisfy { !smallTalkBlockWords.contains($0) }
    }

    /// The cheap lane itself. On failure, the honest causeless copy —
    /// nothing was at stake, so no retry ceremony.
    private func handleSmallTalk(_ messageText: String) async {
        let history = messages.dropLast().map { msg in
            ChatMessage(
                role: msg.role == .user ? "user" : "assistant",
                content: msg.text
            )
        }
        do {
            let reply = try await ClaudeService.shared.smallTalk(
                userMessage: messageText,
                conversationHistory: Array(history)
            )
            messages.append(HomeChatMessage(role: .assistant, text: reply))
        } catch {
            #if DEBUG
            print("[HomeTabView] small-talk error: \(error)")
            #endif
            messages.append(HomeChatMessage(
                role: .assistant,
                text: "That didn't go through, try again in a moment."
            ))
        }
        persistSession()
    }

    static func isPlanIntent(_ text: String) -> Bool {
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
    /// An explicit chat message → `force: true`.
    private func handlePlanIntent() async {
        let outcome = await DayPlanRefiner.shared.refine(
            profile: profile,
            modelContext: modelContext,
            force: true
        )
        let reply: String
        switch outcome {
        case .success(let rationale), .cached(let rationale):
            reply = rationale.isEmpty ? "Done, I laid out your day on the timeline." : rationale
        case .noTasks:
            reply = "You're all set, there's nothing open to schedule into today's free time."
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
