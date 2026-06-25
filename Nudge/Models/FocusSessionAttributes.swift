//
//  FocusSessionAttributes.swift
//  Nudge
//
//  ActivityKit attributes for the focus session Live Activity.
//  This file must be in both the main app and widget extension targets.
//

import ActivityKit
import Foundation

struct FocusSessionAttributes: ActivityAttributes {
    /// Fixed at session start — never changes.
    let sessionID: UUID
    let totalDurationSeconds: Int

    /// Dynamic state updated throughout the session.
    struct ContentState: Codable, Hashable {
        let currentTaskTitle: String
        let currentTaskID: String?
        let timerEndDate: Date
        let isPaused: Bool
        let pausedTimeRemaining: Int?
        let completedTaskCount: Int
        let totalTaskCount: Int
    }
}
