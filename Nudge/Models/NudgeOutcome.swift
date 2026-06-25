//
//  NudgeOutcome.swift
//  Nudge
//
//  Every nudge we emit is logged here along with what the user did about it.
//  This feeds back-pressure into the arbiter: tasks/times that get
//  consistently ignored back off, tasks/times that get tapped reinforce.
//

import Foundation
import SwiftData

enum NudgeOutcomeKind: String, Codable {
    case eventBlock
    case idle
    case getAhead
    case breakItDown
}

enum NudgeOutcomeResult: String, Codable {
    case pending          // scheduled but not yet fired / acted upon
    case tappedStart      // user tapped "Start session"
    case tappedSnooze     // user tapped "Snooze 30 min"
    case tappedBreakDown  // user tapped "Break it down"
    case dismissed        // user explicitly cleared the notification
    case ignored          // notification was delivered but no action taken
}

@Model
final class NudgeOutcome {
    var id: UUID
    var kindRaw: String
    var resultRaw: String
    var notificationID: String
    var taskID: UUID?            // optional — event-block reminders may span many tasks
    var scheduledFor: Date
    var firedAt: Date?
    var actedAt: Date?

    /// What `DurationModel.estimate` thought the task would take when the
    /// nudge was scheduled. Lets us compare predicted vs actual after the
    /// user finishes — eventually drives confidence intervals on the
    /// learned mean.
    var estimatedMinutes: Int?

    /// Wall-clock focused minutes the user logged on this task. Stamped
    /// by `SessionCoordinator.completeCurrentTask` when the task gets
    /// finished as part of an active session. Nil until that happens.
    var actualMinutes: Int?

    /// How many distinct sessions the user took to finish the task this
    /// nudge was about. Stays nil until the task completes; gets the
    /// running session count at that moment.
    var sessionCount: Int?

    var kind: NudgeOutcomeKind {
        get { NudgeOutcomeKind(rawValue: kindRaw) ?? .idle }
        set { kindRaw = newValue.rawValue }
    }

    var result: NudgeOutcomeResult {
        get { NudgeOutcomeResult(rawValue: resultRaw) ?? .pending }
        set { resultRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: NudgeOutcomeKind,
        result: NudgeOutcomeResult = .pending,
        notificationID: String,
        taskID: UUID? = nil,
        scheduledFor: Date,
        estimatedMinutes: Int? = nil,
        actualMinutes: Int? = nil,
        sessionCount: Int? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.resultRaw = result.rawValue
        self.notificationID = notificationID
        self.taskID = taskID
        self.scheduledFor = scheduledFor
        self.estimatedMinutes = estimatedMinutes
        self.actualMinutes = actualMinutes
        self.sessionCount = sessionCount
    }
}
