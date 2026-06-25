//
//  NudgeConfig.swift
//  Nudge
//
//  Every tunable constant the NudgeArbiter consults lives here. Keep this
//  file thin so non-engineers can read it and understand the system's shape.
//

import Foundation

enum NudgeConfig {
    // MARK: - Idle / paralysis nudge
    /// Hours after wake-up before the idle nudge fires (if nothing else has
    /// happened that day).
    static let idleThresholdHours: Double = 3

    // MARK: - Event block clustering
    /// Two events whose starts are within this many hours of each other
    /// belong to the same "block" and share one heads-up.
    static let eventBlockGapHours: Double = 2

    /// Lead time before the first event of a block.
    static let eventReminderLeadMinutes: Int = 60

    // MARK: - Daily budget + spacing
    /// Maximum discretionary nudges per day. Event-block reminders do NOT
    /// count against this budget — they're factual time reminders.
    static let dailyNudgeBudget: Int = 3

    /// Minimum gap between any two nudges (discretionary or factual).
    static let minNudgeSpacingMinutes: Int = 90

    /// If the user started a session OR completed a task within this window,
    /// suppress discretionary nudges — they're clearly engaged.
    static let recentActivityCooldownMinutes: Int = 90

    // MARK: - Per-task fatigue
    /// After this many nudges for the same task, stop pushing and switch to
    /// a break-it-down offer (or back off entirely).
    static let perTaskMaxNudges: Int = 3

    // MARK: - Quiet hours
    /// No discretionary nudges before this many minutes after wake.
    /// (Lets the user actually wake up before being pestered.)
    static let postWakeQuietMinutes: Int = 30

    /// No discretionary nudges within this many minutes of bedtime.
    static let preBedtimeQuietMinutes: Int = 60

    // MARK: - Cache lifetimes
    /// TaskIntelligence is re-analyzed if older than this many days.
    static let intelligenceCacheDays: Int = 7

    // MARK: - Eisenhower scoring tuning
    //
    // Drives `EisenhowerScorer`. Bump softness up to stretch the urgency
    // curve, bump exponents to bias the score toward urgency vs importance,
    // or edit the category dictionary to reweight what counts as "important".

    /// Softness of the logistic urgency curve. At slack = 0 → 0.5. Larger
    /// values produce a flatter transition (less aggressive escalation as
    /// the deadline approaches).
    static let urgencySoftness: Double = 18.0

    /// Urgency must be ≥ this to land in an "urgent" quadrant.
    static let urgentThreshold: Double = 0.5

    /// Importance must be ≥ this to land in an "important" quadrant.
    static let importantThreshold: Double = 0.55

    /// Final-score exponents. Urgency is weighted slightly higher than
    /// importance because ADHD users under-produce deadline salience, so
    /// we want time pressure to break ties.
    static let urgencyExponent: Double = 1.1
    static let importanceExponent: Double = 0.9

    /// Per-category importance prior. Keyed by the closed `TaskCategory`
    /// enum — unknown raw-string categories on existing tasks map to
    /// `.other` and pick up `defaultCategoryImportance`.
    static let categoryImportance: [TaskCategory: Double] = [
        .exam:     0.9,
        .work:     0.7,
        .school:   0.7,
        .health:   0.7,
        .personal: 0.4,
        .errand:   0.3,
        .other:    0.4
    ]

    /// Fallback prior when a task has no category at all (nil). `.other`
    /// uses its own entry above.
    static let defaultCategoryImportance: Double = 0.4

    // MARK: - Duration model
    //
    // Drives `DurationModel.estimate(for:)`. The static priors below are
    // cold-start defaults; the learned `CategoryDurationStats` row shifts
    // the estimate as real sessions accrue. `durationPriorWeight` controls
    // how strongly the prior anchors the estimate vs the learned mean —
    // higher → trust the prior more, slower personalization.

    /// Per-category cold-start effort prior in MINUTES. The user's first
    /// few sessions blend with these; with enough samples the learned mean
    /// dominates.
    static let categoryEffortPriors: [TaskCategory: Int] = [
        .exam:     120,
        .school:    60,
        .work:      60,
        .health:    30,
        .personal:  30,
        .errand:    30,
        .other:     45
    ]

    /// Fallback prior in minutes when category is nil or missing from the
    /// dictionary above.
    static let defaultEffortPriorMinutes: Int = 45

    /// Effective "sample weight" of the static prior in the shrinkage
    /// blend. 5 means "treat the prior as worth 5 real samples" — so a
    /// fresh user with 1 actual sample still trusts the prior 5× more
    /// than that one sample. After ~20 samples the learned mean dominates.
    static let durationPriorWeight: Double = 5.0

    /// EWMA smoothing factor for the learned mean update. Higher → trust
    /// new samples more (faster adaptation, noisier). 0.2 means the new
    /// sample contributes 20% and the prior mean carries 80%.
    static let durationLearningAlpha: Double = 0.2

    // MARK: - Event conflict gate
    //
    // Drives `BusyWindowResolver`. The arbiter refuses to fire any
    // discretionary nudge during a window the user is in class / meeting /
    // appointment — and extends the busy window 15 min past the event end
    // to cover pack-up time. Back-to-back events (next event within
    // `interEventGapToleranceMinutes` of this one's end) merge into a
    // single window so the cramped transition gap doesn't get pinged.

    /// Tail buffer after an event ends. No notifications during the buffer.
    static let postEventBufferMinutes: Int = 15

    /// If the next event starts within this many minutes of the current
    /// event's end, the whole gap is treated as busy (the busy window
    /// extends to the next event's start). Otherwise the 15-min tail
    /// buffer applies and the rest of the gap is free.
    static let interEventGapToleranceMinutes: Int = 90

    /// Fallback duration assumed for informational events that don't have
    /// `estimatedMinutes` set and aren't found in `EventDurationStats`.
    /// Capture flow (step 6) will ask the user instead of guessing, but
    /// this keeps the gate safe in the meantime.
    static let defaultEventDurationMinutes: Int = 60

    // MARK: - StartByPlanner
    //
    // Drives `StartByPlanner.plan(for:)`. Two branches inside the planner
    // (deep work vs shallow) consume different subsets of these constants.

    /// Effort above which a task can qualify as "deep work" (subject to
    /// category check too). Below this threshold the task is treated as
    /// single-shot regardless of category.
    static let deepWorkThresholdMinutes: Int = 60

    /// Typical length of one deep-work session in hours. Drives
    /// sessionsNeeded = ceil(effortHours / typicalDeepWorkSessionHours).
    static let typicalDeepWorkSessionHours: Double = 1.5

    /// Extra calendar days the planner adds before the deadline so the
    /// LAST session doesn't sit on the due date itself.
    static let deepWorkBufferDays: Int = 1

    /// For shallow tasks: total lead = effort × (1 + multiplier). A 30-min
    /// task with multiplier = 1.0 → startBy = due − 60 min.
    static let shallowBufferMultiplier: Double = 1.0
}
