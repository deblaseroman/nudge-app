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

    /// MASTER SWITCH for everything that ACTS on `NudgeOutcome` history:
    /// the per-task fatigue gate in `NudgeArbiter.passesGates` and the
    /// `buildBreakItDownCandidates` builder that fires once a task crosses
    /// `perTaskMaxNudges`.
    ///
    /// Deliberately OFF. `NudgeOutcomeClassifier` now writes real `.ignored`
    /// rows, which the fatigue predicates already match — so leaving this
    /// implicit ("the data just happens not to line up yet") would have
    /// silently changed which notifications fire the moment the sweep
    /// landed. An explicit flag keeps both consumers readable and armed by
    /// a one-word diff once the recorded classifications have been reviewed.
    static let fatigueGateEnabled: Bool = false

    // MARK: - Quiet hours
    /// No discretionary nudges before this many minutes after wake.
    /// (Lets the user actually wake up before being pestered.)
    /// Also the morning prompt's fire offset — it goes out the moment the
    /// post-wake quiet period ends.
    static let postWakeQuietMinutes: Int = 30

    /// No discretionary nudges within this many minutes of bedtime.
    static let preBedtimeQuietMinutes: Int = 60

    // MARK: - Morning prompt
    /// Skip the morning prompt when at least this fraction of the day's
    /// awake window (wake+quiet → bed−quiet) is already committed to
    /// events. A day that's half booked doesn't need a planning nudge on
    /// top.
    static let morningPromptBusyDayThreshold: Double = 0.5

    /// How many mornings in a row the prompt may name the SAME task before
    /// it steps aside for the next one down the ranking.
    ///
    /// The prompt names the highest-stakes open task, and stakes doesn't
    /// change day to day — so without this, one task months out gets named
    /// every morning until it's done, and an unchanging daily notification
    /// is how a channel gets tuned out. 2 rather than 3: a third identical
    /// morning is already past the point where the user stops reading it.
    ///
    /// **Only applies when there is something else to name.** If the pool
    /// empties, the same task is named again rather than the day's anchor
    /// going silent — see `morningPromptRanking`.
    static let morningPromptMaxConsecutiveDays: Int = 2

    // MARK: - Outcome classification
    //
    // Drives `NudgeOutcomeClassifier`, the launch/foreground sweep that
    // turns delivered-but-unanswered `NudgeOutcome` rows into
    // acted / engaged / ignored. Recording only — `fatigueGateEnabled`
    // above decides whether anything acts on the result.

    /// How long after a nudge's fire time the sweep waits before judging it.
    /// MUST stay greater than `outcomeActionWindowMinutes`: that guarantees
    /// the response window is already closed when we classify, so the very
    /// app-open that runs the sweep can never count as engagement with the
    /// row it is classifying.
    static let outcomeClassificationGraceMinutes: Int = 90

    /// The response window a delivered nudge gets. An app open, a session
    /// start, or the task action itself inside
    /// [fireDate, fireDate + this] is attributed to the nudge.
    static let outcomeActionWindowMinutes: Int = 60

    /// How long `AppOpenLog` keeps foreground timestamps. Matches the
    /// 14-day fatigue window — nothing looks further back than that.
    static let appOpenLogRetentionDays: Int = 14

    /// Hard cap on stored app-open timestamps regardless of age, so a heavy
    /// user can't grow the shared-defaults array without bound.
    static let appOpenLogMaxEntries: Int = 400

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

    // MARK: - Stakes → importance
    //
    // `TaskStakes` is the CONSEQUENCE signal — how bad is it if this is
    // missed. Category alone can't express it: a job interview and a
    // routine reading are both 0.70, so the tie breaks on deadline
    // proximity and consequence is ignored.
    //
    // ── WHY `.medium` IS ZERO AND `.low` IS NEGATIVE ────────────────────
    // `.medium` is the modal classification — treating it as a bonus would
    // shift almost everything equally and separate nothing. `.low` pushes
    // DOWN rather than letting `.high` push up alone: the importance sum is
    // clamped to 0...1 and the interesting tasks already crowd the top, so
    // buying separation at the bottom (where there is headroom) beats
    // buying it at the top (where the clamp eats it). `nil` — never
    // classified, which `StakesBackfill` hasn't necessarily reached — is
    // absence of evidence and scores 0.

    /// Additive importance term per stakes level. Applied in
    /// `EisenhowerScorer.importance`; `nil` stakes contributes nothing.
    static let stakesImportanceBonus: [TaskStakes: Double] = [
        .high:    0.20,
        .medium:  0.0,
        .low:    -0.15
    ]

    /// Ceiling on the SUM of the two "the user signalled this matters"
    /// bonuses — explicit `statedUrgency` (0.25) and a positive stakes
    /// term.
    ///
    /// They are not independent. A task someone flagged as urgent in the
    /// brain dump is very often the same task the classifier rates high
    /// stakes, so adding both naively counts one belief twice and pushes
    /// the pair straight into the 0...1 clamp — compressing exactly the
    /// high end the stakes signal exists to separate. Capping at 0.30
    /// means high stakes adds only +0.05 on top of an explicit urgency
    /// flag, while still contributing its full 0.20 on the (common) task
    /// that carries no stated urgency at all.
    ///
    /// The cap covers POSITIVE terms only. A `.low` penalty is independent
    /// evidence pointing the other way, so it always applies in full.
    static let stakesSignalCombinedCap: Double = 0.30

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

    /// Upper bound on the duration a calendar / iCal import may write to
    /// `NudgeTask.estimatedMinutes`. Real end times are honored up to this
    /// cap; anything longer is almost always a multi-day span entered as a
    /// single timed event, and letting that through would turn the busy
    /// gate into a multi-day notification blackout — strictly worse than
    /// the 60-minute guess it replaced. 12h covers a double shift and every
    /// realistic single-day commitment.
    static let maxImportedEventDurationMinutes: Int = 12 * 60

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

    // MARK: - Get-ahead fire time
    //
    // `StartByPlanner` answers WHICH DAY the user should start. It does not
    // answer WHAT TIME OF DAY the nudge should arrive, and it was being
    // used for both — so the nudge inherited the deadline's clock time.
    // Bare due dates normalize to 23:59, which meant every deep-work
    // get-ahead fired at 23:59 (always inside quiet hours, so it never
    // fired at all) and shallow ones fired at due − effort×2, i.e. 21:59
    // for a 60-minute task — the night the thing was due, for a nudge whose
    // entire job is prompting an early start.
    //
    // The day now comes from the planner; the hour comes from here.

    /// Hours after wake at which a get-ahead nudge fires on its anchor day.
    ///
    /// 2h is the EARLIEST offset that fits the existing gate structure:
    ///   • It clears the post-wake quiet floor (`postWakeQuietMinutes`, 30)
    ///     by 90 minutes.
    ///   • It sits exactly `minNudgeSpacingMinutes` (90) after the morning
    ///     prompt at wake+30, and `pickWinners` treats "too close" as
    ///     strictly less than that — so the two coexist instead of one
    ///     evicting the other. Anything earlier collides with the prompt.
    ///
    /// It does NOT clear the idle nudge at wake+`idleThresholdHours` (3h);
    /// nothing can, since the wake+1.5h → wake+7.5h band is fully occupied
    /// by the morning prompt, idle, break-it-down (wake+4h) and the floater
    /// check-in (wake+6h). When a get-ahead and an idle candidate land on
    /// the same day, min-spacing keeps whichever scores higher — which is
    /// the intended resolution: a nudge naming a specific dated task should
    /// beat a generic "have you started anything?".
    static let getAheadAnchorHoursAfterWake: Double = 2

    // MARK: - Floater check-in fire time

    /// Hours after wake at which the mid-day "are you working on something?"
    /// check-in for OPEN UNDATED tasks fires. Was an inline `6 * 60 * 60`
    /// literal in `buildFloaterCheckInCandidates`; the value is unchanged.
    ///
    /// ── KNOWN COLLISION — DELIBERATELY NOT RETUNED YET ──────────────────
    /// wake+6h lands in the middle of a committed afternoon: with the
    /// default wake (`morningCheckInTime`, 08:00) the anchor is 14:00. Any
    /// event starting roughly 12:30–15:30 suppresses the check-in, by one of
    /// two independent routes:
    ///
    ///   • The fire time falls inside a busy window. Note this includes
    ///     events that don't themselves cover 14:00 — `BusyWindowResolver`
    ///     merges gaps ≤ `interEventGapToleranceMinutes`, so a 12:00 class
    ///     and a 14:30 class become one window that swallows it.
    ///
    ///   • The event's own heads-up fires `eventReminderLeadMinutes` (60)
    ///     ahead and is seeded into `pickWinners`' winner set BEFORE any
    ///     discretionary candidate is considered — so a class at 15:00 puts
    ///     a reminder at exactly 14:00 and the floater loses min-spacing.
    ///     Clearing that needs a ≥ 17:00 event.
    ///
    /// The result is that the check-in fires on a free day and stays silent
    /// on a class day. That is accepted FOR NOW: the offset can't be retuned
    /// against evidence until `.floater` outcome rows exist, and they don't
    /// yet (see the rollover note on `buildFloaterCheckInCandidates`).
    static let floaterCheckInHoursAfterWake: Double = 6

    // MARK: - Stakes backfill
    //
    // Drives `StakesBackfill`, the one-shot pass that classifies stakes on
    // rows that never got a value and re-classifies calendar rows the
    // deterministic `CalendarService.inferStakes` fallback got wrong.

    /// Unique normalized titles per Claude request. The pass dedupes first,
    /// so this bounds request size, not row count — 40 titles is a few
    /// hundred output tokens, comfortably inside the response budget.
    static let stakesBackfillChunkSize: Int = 40

    /// Pause between chunk requests. Cheap insurance against tripping the
    /// rate limit on a large import; the pass is background work with no
    /// deadline, so there is nothing to gain by going faster.
    static let stakesBackfillInterChunkDelaySeconds: Double = 0.5

    /// How long to wait before the single retry after a 429. One retry
    /// only — if the limit is still hot, the pass abandons and runs again
    /// on a later launch.
    static let stakesBackfillRateLimitBackoffSeconds: Double = 5.0

    // MARK: - Stakes row display
    //
    // DISPLAY-ONLY thresholds for the task list's stakes treatments. They
    // drive row color/emphasis in `TaskRowView` and nothing else — no
    // scoring, ranking, gating, or notification decision reads them. Kept
    // here only because the app's convention is that every tunable lives in
    // NudgeConfig.

    /// A high-stakes task whose deadline falls within this many days reads
    /// as "approaching" (coral row). Pure calendar proximity measured off
    /// `NudgeTask.sortDeadline` — deliberately NOT the EisenhowerScorer
    /// urgency curve, which folds in remaining effort and so can't express a
    /// clean day count. Keeping it off the curve also keeps display fully
    /// independent of scoring.
    static let stakesApproachingDays: Int = 3

    /// A low-stakes, undated task older than this many days reads as
    /// "sitting" — a faint amber "Sitting N days" subtitle, no bar or tint.
    static let stakesSittingDays: Int = 7

    // MARK: - Events section display
    //
    // DISPLAY-ONLY. Drives how the Tasks tab's Events section groups rows into
    // days and how many day-groups it shows before collapsing the rest. No
    // scoring, gating, import, or notification decision reads it.

    /// Number of upcoming day-groups the Events section shows expanded; the
    /// remaining days collapse behind a single "Show N more days" control.
    static let eventsExpandedDays: Int = 3

    /// An event whose normalized title appears this many-or-more times among
    /// the section's events reads as a routine fixture (class meeting,
    /// standing appointment) and renders de-emphasized in EventRowView.
    /// With the 21-day calendar window, 3 ≈ "weekly or more frequent."
    static let routineEventRepeatThreshold: Int = 3
}
