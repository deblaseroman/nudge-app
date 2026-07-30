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

enum NudgeOutcomeKind: String, Codable, CaseIterable {
    case eventBlock
    case idle
    case getAhead
    // `breakItDown` was removed Jul 2026 along with its builder, category,
    // and toggle. No store ever held a row with that raw value — the
    // builder was gated behind `fatigueGateEnabled`, which has never been
    // true in production — so there is no history to preserve; were one to
    // exist, the `kind` getter's `?? .idle` fallback reads it without
    // crashing.
    /// Day-opening capture ask ("what do you want to get done today?").
    /// Replaced the fixed NotificationScheduler morning kickoff when the
    /// morning notification moved under the arbiter (Jul 2026).
    case morningPrompt
    /// Mid-day check-in on an OPEN UNDATED task ("are you working on
    /// something?"). Split out of `.getAhead` (Jul 2026) — the two builders
    /// had been sharing that kind, which made their rows indistinguishable
    /// in `NudgeOutcome` and left no way to tell which of the two features
    /// was working. Additive: existing rows keep their `getAhead` raw value,
    /// so pre-split history stays attributed to the kind it was logged under
    /// rather than being silently reinterpreted.
    ///
    /// Different job from `.getAhead` in every dimension: it targets undated
    /// low-stakes work when there's free time, where get-ahead targets dated
    /// work approaching a deadline.
    case floater
}

extension NudgeOutcomeKind {
    /// Whether a SUCCESSFUL nudge of this kind necessarily leaves a trace
    /// the app can see (an app open, a session start, a completion).
    ///
    /// ── THIS IS A CORRECTNESS PROPERTY, NOT A PREFERENCE ───────────────
    /// `NudgeOutcomeClassifier` infers `.ignored` from "the app was never
    /// opened inside the response window", and every fatigue consumer reads
    /// `.ignored` as evidence the nudge failed. That inference is only
    /// valid when success REQUIRES touching the app.
    ///
    /// For `.eventBlock` it doesn't. The success case for "Class in 1 hour"
    /// is the user reading it and going to class — no app open, and no
    /// completion either (informational events are rendered by
    /// `EventRowView`, which has no completion affordance at all, so the
    /// `CompletedTaskRecord` branch of `performedAction` is unreachable for
    /// them). Success and failure are therefore behaviourally IDENTICAL in
    /// the record: both produce `.ignored`. Inferring failure from silence
    /// is invalid for these kinds, so nothing that penalises a task may
    /// count their rows.
    ///
    /// The remaining kinds all ask for something the app can observe —
    /// starting a session, completing the named task, capturing a task, or
    /// (for `.idle`) answering a yes/no button that routes through the
    /// delegate. `.getAhead` is the softest of them: a user who does the
    /// errand offline and never opens the app logs `.ignored` too. That's
    /// NOISE — a success path through the app exists and is what the nudge
    /// asks for — where `.eventBlock` is a structural impossibility. The
    /// explicit-feedback channel (`markedUnhelpful`) is what will
    /// eventually let us measure that noise. `.floater` sits in
    /// exactly the same place as `.getAhead`: it names a specific task and
    /// asks the user to start it, which is a session start or a completion —
    /// both visible to the app.
    ///
    /// (`markedHelpful` was removed Jul 2026 — the remaining feedback
    /// channel is 👎 only, so it can flag noise but not confirm success.
    /// `DESIGN.md` puts the positive half in chat.)
    var successIsObservableInApp: Bool {
        switch self {
        case .eventBlock:
            return false
        case .idle, .getAhead, .morningPrompt, .floater:
            return true
        }
    }

    /// Raw values of the kinds whose `.ignored` rows carry no information
    /// about failure. Pre-computed as strings so SwiftData `#Predicate`s can
    /// filter them out without evaluating Swift-only enum logic, and derived
    /// from `allCases` so a new kind is covered the moment it declares
    /// itself unobservable.
    static let fatigueBlindRawValues: [String] = allCases
        .filter { !$0.successIsObservableInApp }
        .map(\.rawValue)
}

enum NudgeOutcomeResult: String, Codable {
    case pending          // scheduled but not yet fired / acted upon
    case tappedStart      // user tapped "Start session"
    case tappedSnooze     // user tapped "Snooze 30 min"
    // `tappedBreakDown` left with the `.breakItDown` kind (Jul 2026). Its
    // writer had already been removed, so no row ever carried the raw
    // value; the `result` getter's `?? .pending` fallback covers a stray.
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

    // ── Explicit feedback (written by the notification delegate) ─────────
    // Stored in `NudgeOutcome.feedbackRaw`, NEVER in `resultRaw`. Behaviour
    // can't separate "this nudge was useless" from "this nudge worked and I
    // didn't need the app" — both are silence. This case is the user saying
    // it was the former, in their own words rather than ours.
    //
    // There was a `markedHelpful` counterpart until Jul 2026. Nothing ever
    // read it, no row ever carried it, and `DESIGN.md` puts the positive
    // half of the opinion channel in chat rather than on a banner button.
    // The `feedback` getter runs `NudgeOutcomeResult(rawValue:)` inside a
    // `guard`, so were a stored `"markedHelpful"` string to exist it now
    // reads as nil rather than crashing.

    /// User tapped the 👎 action on the notification itself.
    case markedUnhelpful

    /// True for the case above — the one that belongs in the feedback
    /// column rather than the result column.
    var isExplicitFeedback: Bool {
        self == .markedUnhelpful
    }
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

    // ── Explicit feedback: a SECOND, INDEPENDENT COLUMN ──────────────────
    // `resultRaw` answers "what did the user do?" — a behavioural reading,
    // written either by the delegate (a tap) or inferred after the fact by
    // `NudgeOutcomeClassifier`. `feedbackRaw` answers "what did the user
    // think?" — an opinion, only ever written by the delegate when a
    // feedback button is pressed.
    //
    // They are deliberately NOT the same field. Folding feedback into
    // `resultRaw` would make the two signals destroy each other in both
    // directions: a 👎 on a delivered nudge would erase the behavioural
    // record, and — worse — writing anything into `resultRaw` takes the row
    // out of `pending`, which is the ONLY thing the classifier sweeps. The
    // row would then never be classified at all, so pressing 👎 would cost
    // us the inferred reading we're trying to compare it against.
    //
    // With two columns a row can carry `result == .acted` AND
    // `feedback == .markedUnhelpful` simultaneously — the user did the thing
    // and still didn't want to be asked — which is exactly the combination
    // no behavioural reading can express, and the reason to collect this at
    // all.
    //
    // Additive optionals — existing rows migrate as nil (no feedback given).

    /// Raw value of a `NudgeOutcomeResult` explicit-feedback case. Nil until
    /// the user presses a feedback button; nil forever on rows where they
    /// never do (the overwhelming majority).
    var feedbackRaw: String?

    /// When the feedback button was pressed. Distinct from `actedAt` — the
    /// user can act on a nudge and rate it at different moments, or rate one
    /// they never acted on.
    var feedbackAt: Date?

    var kind: NudgeOutcomeKind {
        get { NudgeOutcomeKind(rawValue: kindRaw) ?? .idle }
        set { kindRaw = newValue.rawValue }
    }

    var result: NudgeOutcomeResult {
        get { NudgeOutcomeResult(rawValue: resultRaw) ?? .pending }
        set { resultRaw = newValue.rawValue }
    }

    /// The user's explicit rating of this nudge, if they gave one. Only
    /// `.markedUnhelpful` is storable here; the setter
    /// refuses anything else so a behavioural case can never leak into the
    /// opinion column (or vice versa — see the comment on `feedbackRaw`).
    var feedback: NudgeOutcomeResult? {
        get {
            guard let raw = feedbackRaw,
                  let value = NudgeOutcomeResult(rawValue: raw),
                  value.isExplicitFeedback else { return nil }
            return value
        }
        set {
            guard let newValue else {
                feedbackRaw = nil
                return
            }
            guard newValue.isExplicitFeedback else {
                assertionFailure("`feedback` holds explicit-feedback cases only, got \(newValue)")
                return
            }
            feedbackRaw = newValue.rawValue
        }
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
