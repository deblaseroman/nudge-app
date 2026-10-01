//
//  TaskActivityAttributes.swift
//  Nudge
//
//  ActivityKit attributes for the DayPlanner Live Activity.
//  This file must be in both the main app and widget extension targets.
//

import ActivityKit
import Foundation

struct TaskActivityAttributes: ActivityAttributes {
    public typealias TaskActivityStatus = ContentState

    public struct ContentState: Codable, Hashable {
        var taskName: String
        var sessionState: SessionState
        var timerEnd: Date
        var nextTaskName: String?
    }

    var userName: String
    var totalTasksToday: Int
    var currentTaskIndex: Int
}

enum SessionState: String, Codable, Hashable {
    case active
    case breakTime
    case getReady
    case finalWarning
    case complete
    case stayFocusedAlert
    /// Never written by the app: the widget shows it when the activity's
    /// stale date (the session's end instant) passes while the app is not
    /// running to end it — the timer would otherwise sit frozen at 0:00.
    case timeUp
}
