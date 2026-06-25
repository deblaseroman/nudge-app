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
}
