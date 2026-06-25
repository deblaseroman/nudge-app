//
//  LiveActivityManager.swift
//  Nudge
//
//  Drives the Live Activity for a single-task focus session.
//

import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {

    static let shared = LiveActivityManager()

    private var currentActivity: Activity<TaskActivityAttributes>? {
        Activity<TaskActivityAttributes>.activities.first
    }

    /// Starts a Live Activity for a single chosen task.
    func startActivity(
        userName: String,
        taskTitle: String,
        taskEnds: Date
    ) throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = TaskActivityAttributes(
            userName: userName,
            totalTasksToday: 1,
            currentTaskIndex: 1
        )

        let state = TaskActivityAttributes.ContentState(
            taskName: taskTitle,
            sessionState: .active,
            timerEnd: taskEnds,
            nextTaskName: nil
        )

        let content = ActivityContent(
            state: state,
            staleDate: taskEnds.addingTimeInterval(60)
        )

        _ = try Activity.request(
            attributes: attributes,
            content: content,
            pushType: nil
        )
    }

    /// Flips the current activity to the red "stay focused" alert state.
    /// `timerEnd` is kept on the same end time so the countdown doesn't jump.
    func showStayFocusedAlert(taskTitle: String, taskEnds: Date) async {
        let state = TaskActivityAttributes.ContentState(
            taskName: taskTitle,
            sessionState: .stayFocusedAlert,
            timerEnd: taskEnds,
            nextTaskName: nil
        )
        await currentActivity?.update(
            ActivityContent(state: state, staleDate: taskEnds.addingTimeInterval(60))
        )
    }

    /// Reverts the activity from the alert state back to `.active`.
    func revertToActive(taskTitle: String, taskEnds: Date) async {
        let state = TaskActivityAttributes.ContentState(
            taskName: taskTitle,
            sessionState: .active,
            timerEnd: taskEnds,
            nextTaskName: nil
        )
        await currentActivity?.update(
            ActivityContent(state: state, staleDate: taskEnds.addingTimeInterval(60))
        )
    }

    /// Ends every pending Live Activity immediately. Called when the user
    /// completes or cancels a session — the Dynamic Island / lock-screen
    /// banner must disappear right away, not linger.
    func endActivity() async {
        let activities = Activity<TaskActivityAttributes>.activities
        guard !activities.isEmpty else { return }

        for activity in activities {
            let finalState = TaskActivityAttributes.ContentState(
                taskName: "All done, \(activity.attributes.userName)!",
                sessionState: .complete,
                timerEnd: Date(),
                nextTaskName: nil
            )
            await activity.end(
                ActivityContent(state: finalState, staleDate: Date()),
                dismissalPolicy: .immediate
            )
        }
    }
}
