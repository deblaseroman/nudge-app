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
    /// Day-opening capture ask ("what do you want to get done today?").
    /// Replaced the fixed NotificationScheduler morning kickoff when the
    /// morning notification moved under the arbiter (Jul 2026).
    case morningPrompt
}

enum NudgeOutcomeResult: String, Codable {
    case pending          // scheduled but not yet fired / acted upon
    case tappedStart      // user tapped "Start session"
    case tappedSnooze     // user tapped "Snooze 30 min"
    case tappedBreakDown  // user tapped "Break it down"
    case dismissed        // user explicitly cleared the notification
    case ignored          // delivered, app never opened in the response window

    // ── Swept results (written by `NudgeOutcomeClassifier`) ──────────────
    // The `tapped*` cases above are written by the notification delegate
    // and mean "the user touched the notification itself". These two are
    // inferred AFTER the fact, from what the user did in the app, for rows
    // the delegate never heard about. Additive on purpose — no existing
    // case changed meaning.

    /// Delivered, not tapped, but the user did the thing it asked for
    /// inside the response window (started a session, completed the task,
    /// or — for the morning prompt — captured something).
    case acted

    /// Delivered, not tapped; the user opened the app inside the response
    /// window but did not do the thing. The interesting middle case:
    /// the nudge reached them and moved them, just not to the action.
    case engaged
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

    /// When `NudgeOutcomeClassifier` resolved this row out of `pending`.
    /// Nil for rows the notification delegate answered directly (a tap
    /// stamps `actedAt` instead) and for rows still awaiting the sweep.
    /// Additive optional — existing rows migrate as nil.
    var classifiedAt: Date?

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
