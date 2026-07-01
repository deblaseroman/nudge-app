//
//  SessionCoordinator.swift
//  Nudge
//
//  Drives one focus session on a single user-chosen task.
//  The session has two states: .active while the timer runs, .complete when
//  the user finishes (or the timer hits zero). No automatic chaining, no
//  break time, no next-task transitions.
//

import ActivityKit
import AudioToolbox
import Foundation
import Observation
import SwiftData
import WidgetKit

@Observable
@MainActor
final class SessionCoordinator {

    static let shared = SessionCoordinator()

    // MARK: - Published State

    var sessionState: SessionState = .active
    var isSessionActive: Bool = false
    var currentTask: NudgeTask?
    var sessionEnd: Date = .distantPast

    var currentTaskName: String {
        currentTask?.title ?? "No active session"
    }

    var currentTaskID: UUID? {
        currentTask?.id
    }

    // MARK: - Private

    private var sessionEndTimer: DispatchWorkItem?
    private var focusAlertTimer: DispatchWorkItem?
    private var focusAlertRevertTimer: DispatchWorkItem?
    private let activityManager = LiveActivityManager.shared
    private let defaultDurationMinutes = 60
    private let focusAlertOffset: TimeInterval = 20 * 60     // 20 min into session
    private let focusAlertDuration: TimeInterval = 10        // red banner shows for 10 s

    /// Wall-clock start of the current session. Used to compute
    /// `actualMinutes` when the user marks the task complete. Reset to nil
    /// on cancel so cancelled sessions don't contaminate the learning loop.
    private var sessionStartedAt: Date?

    /// Running count of distinct sessions the user has spent on the current
    /// task. Increments on every `startSession`, gets stamped onto the
    /// NudgeOutcome on completion, then resets only if the user cancels
    /// (we want a partial session to count toward the next attempt too).
    /// Keyed by taskID so switching tasks mid-day works correctly.
    private var sessionCountByTaskID: [UUID: Int] = [:]

    // MARK: - Start Session

    /// Starts a session on a single task. Uses the task's `estimatedMinutes`
    /// if set, otherwise falls back to a 60-minute default.
    func startSession(task: NudgeTask, userName: String) {
        cancelSession()

        currentTask = task
        sessionState = .active
        isSessionActive = true
        sessionStartedAt = Date()
        sessionCountByTaskID[task.id, default: 0] += 1

        // Persist "session was started today" so the arbiter's recent-
        // activity cooldown gate trips on the next reevaluation.
        SharedModelContainer.appGroupDefaults
            .set(Date(), forKey: NotificationScheduler.lastFocusSessionStartedAtKey)

        // Defer reevaluation: re-runs the arbiter so all pending
        // discretionary nudges are cancelled now that the user is engaged.
        let context = ModelContext(SharedModelContainer.container)
        if let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first {
            NudgeArbiter.shared.reevaluate(
                reason: .sessionStarted,
                profile: profile,
                modelContext: context
            )
        }

        let minutes = task.estimatedMinutes ?? defaultDurationMinutes
        let duration = TimeInterval(minutes * 60)
        sessionEnd = Date().addingTimeInterval(duration)

        // Publish the active session to the widget. Without this write
        // the widget timeline shows the "Start" button even after the
        // user starts a session — there was no signal to flip the state.
        publishSessionState(
            isActive: true,
            currentTaskID: task.id,
            timerEndDate: sessionEnd
        )

        do {
            try activityManager.startActivity(
                userName: userName,
                taskTitle: task.title,
                taskEnds: sessionEnd
            )
        } catch {
            print("[SessionCoordinator] Failed to start Live Activity: \(error)")
        }

        sessionEndTimer = scheduleWork(after: duration) { [weak self] in
            self?.handleTimerExpired()
        }

        // Schedule the 20-min "stay focused" alert if the session is long
        // enough to actually show it AND revert back.
        if duration > focusAlertOffset + focusAlertDuration {
            focusAlertTimer = scheduleWork(after: focusAlertOffset) { [weak self] in
                self?.triggerFocusAlert()
            }
        }
    }

    // MARK: - Complete

    /// Called when the user explicitly marks the current-session task as
    /// done — either via the checkmark button on the active session card
    /// or via the task-list checkbox while a session is running.
    ///
    /// This is the SOLE entry point for `DurationModel.record` — sessions
    /// that end without completing a task (timer expired, user cancelled)
    /// do NOT contribute to the learning loop. Why: a 60-min session that
    /// ended with the task still open means the estimate was TOO LOW, but
    /// we don't know by how much. Mixing those into the EWMA would bias
    /// the mean downward.
    func completeCurrentTask() {
        guard isSessionActive else { return }

        let task = currentTask
        let startedAt = sessionStartedAt
        let totalSessions = task.map { sessionCountByTaskID[$0.id] ?? 1 } ?? 1

        finishSession()

        guard let task, let startedAt else { return }

        // Wall-clock duration of THIS session. For multi-session tasks we'd
        // sum across all sessions, but `DurationModel` does its own EWMA
        // averaging so feeding it per-session minutes is fine.
        let minutes = max(1, Int((Date().timeIntervalSince(startedAt) / 60).rounded()))
        let context = ModelContext(SharedModelContainer.container)

        DurationModel.shared.record(
            actualMinutes: minutes,
            for: task.taskCategory ?? .other,
            modelContext: context
        )

        // Stamp the actuals onto the most recent NudgeOutcome for this
        // task so we can compare predicted vs actual in stats / weekly
        // review. We pick the most recent ROW regardless of result —
        // even an "ignored" nudge gets the audit info, since the user
        // eventually came back to the task.
        let taskID = task.id
        let descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> { $0.taskID == taskID },
            sortBy: [SortDescriptor(\.scheduledFor, order: .reverse)]
        )
        if let latest = (try? context.fetch(descriptor))?.first {
            latest.actualMinutes = minutes
            latest.sessionCount = totalSessions
            try? context.save()
        }

        // Reset the per-task session counter — next time the user starts a
        // session on this task it's a fresh run.
        sessionCountByTaskID[task.id] = nil

        // Recompute scheduled nudges: the completed task should no longer
        // generate get-ahead / floater / break-it-down reminders. Without
        // this the user keeps getting pinged about work they just finished.
        if let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first {
            NudgeArbiter.shared.reevaluate(
                reason: .taskCompleted,
                profile: profile,
                modelContext: context
            )
        }
    }

    // MARK: - External End Sync

    /// If the coordinator still thinks a session is running but the Live
    /// Activity has already been dismissed (e.g. the user tapped "End" on the
    /// home-screen widget while the app was backgrounded), tear down our
    /// internal timers/state to match reality.
    ///
    /// Call this every time the app becomes active.
    func syncIfActivityDismissed() {
        guard isSessionActive else { return }
        guard Activity<TaskActivityAttributes>.activities.isEmpty else { return }
        cancelAllTimers()
        isSessionActive = false
        sessionState = .active
        currentTask = nil
        sessionEnd = .distantPast
        sessionStartedAt = nil
        publishSessionState(isActive: false, currentTaskID: nil, timerEndDate: nil)
    }

    // MARK: - Cancel

    func cancelSession() {
        guard isSessionActive else { return }
        cancelAllTimers()

        // ActivityKit (`Activity<...>.end` etc.) asserts main thread.
        // LiveActivityManager is @MainActor, and @_inheritActorContext on
        // Task.init SHOULD carry it in from here — but being explicit
        // removes any ambiguity if the surrounding actor context is ever
        // lost (e.g., called from a non-isolated callback in the future).
        Task { @MainActor in
            await activityManager.endActivity()
        }

        isSessionActive = false
        sessionState = .active
        currentTask = nil
        sessionEnd = .distantPast
        sessionStartedAt = nil
        publishSessionState(isActive: false, currentTaskID: nil, timerEndDate: nil)
    }

    // MARK: - Private

    private func handleTimerExpired() {
        playAlarmSound()
        finishSession()
    }

    private func finishSession() {
        cancelAllTimers()
        sessionState = .complete
        playAlarmSound()

        Task { @MainActor in
            await activityManager.endActivity()
        }

        // sessionStartedAt is cleared HERE — completeCurrentTask already
        // read it before calling finishSession, so this is the safe spot.
        sessionStartedAt = nil

        // Clear the widget's view of the active session. The widget will
        // re-render its "Start" button on the next timeline reload.
        publishSessionState(isActive: false, currentTaskID: nil, timerEndDate: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.isSessionActive = false
            self?.currentTask = nil
            self?.sessionState = .active
        }
    }

    private func triggerFocusAlert() {
        guard isSessionActive, sessionState == .active, let task = currentTask else { return }
        let ends = sessionEnd
        Task { @MainActor in
            await activityManager.showStayFocusedAlert(taskTitle: task.title, taskEnds: ends)
        }
        focusAlertRevertTimer = scheduleWork(after: focusAlertDuration) { [weak self] in
            self?.revertFocusAlert()
        }
    }

    private func revertFocusAlert() {
        guard isSessionActive, let task = currentTask else { return }
        let ends = sessionEnd
        Task { @MainActor in
            await activityManager.revertToActive(taskTitle: task.title, taskEnds: ends)
        }
    }

    private func cancelAllTimers() {
        sessionEndTimer?.cancel()
        focusAlertTimer?.cancel()
        focusAlertRevertTimer?.cancel()
        sessionEndTimer = nil
        focusAlertTimer = nil
        focusAlertRevertTimer = nil
    }

    private func scheduleWork(after delay: TimeInterval, block: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { @MainActor in
            block()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func playAlarmSound() {
        AudioServicesPlaySystemSound(1005)
    }

    // MARK: - Widget session-state bridge
    //
    // The widget reads `activeSessionState` from the shared App Group
    // UserDefaults to decide whether to show the "Start" button or the
    // active-session control bar. Without these writes the widget never
    // sees that a session is running.
    //
    // Schema (kept in lockstep with `NudgeWidget.swift` line ~437):
    //   isActive: Bool
    //   isPaused: Bool                   — always false for now (no pause)
    //   pausedTimeRemaining: Int?        — nil for now
    //   timerEndDate: TimeInterval       — Unix epoch seconds
    //   currentTaskID: String            — UUID string

    private func publishSessionState(
        isActive: Bool,
        currentTaskID: UUID?,
        timerEndDate: Date?
    ) {
        let defaults = SharedModelContainer.appGroupDefaults
        if isActive {
            var dict: [String: Any] = [
                "isActive": true,
                "isPaused": false
            ]
            if let timerEndDate {
                dict["timerEndDate"] = timerEndDate.timeIntervalSince1970
            }
            if let currentTaskID {
                dict["currentTaskID"] = currentTaskID.uuidString
            }
            defaults.set(dict, forKey: "activeSessionState")
        } else {
            defaults.removeObject(forKey: "activeSessionState")
        }
        // Kick the widget to pick up the new state immediately rather
        // than waiting for the next 15-min timeline refresh.
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
    }
}
