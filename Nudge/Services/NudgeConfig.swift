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
    ///
    /// 10 (cycle 2026-08-04-02, was 3) — DELIBERATELY HIGH, and not a
    /// final value. The missed-placement series alone can want 4 slots,
    /// and at 3 it would crowd out every other kind; 10 is an observation
    /// setting, so real days show everything the arbiter would fire and
    /// the kinds that earn their place can be chosen from evidence. At
    /// this level the budget mostly stops binding: with the default
    /// profile (wake 8:00, bed 23:00) the awake window is 08:30–22:00 =
    /// 810 min, and `minNudgeSpacingMinutes` (90) caps that at 10
    /// fence-post slots BEFORE budget-exempt winners (morning prompt,
    /// event blocks, due-soon) claim theirs — so spacing, not this number,
    /// is now the practical ceiling.
    static let dailyNudgeBudget: Int = 10

    /// Minimum gap between any two nudges (discretionary or factual).
    static let minNudgeSpacingMinutes: Int = 90

    /// If the user started a session OR completed a task within this window,
    /// suppress discretionary nudges — they're clearly engaged.
    static let recentActivityCooldownMinutes: Int = 90

    // MARK: - Per-task fatigue
    /// After this many nudges for the same task, stop pushing and back
    /// off. (Break-it-down — the offer that used to replace the pushes at
    /// this threshold — was removed Jul 2026.)
    static let perTaskMaxNudges: Int = 3

    /// MASTER SWITCH for everything that ACTS on `NudgeOutcome` history —
    /// today that is exactly one consumer: the per-task fatigue gate in
    /// `NudgeArbiter.passesGates`. (The break-it-down builder was the
    /// second consumer until its removal, Jul 2026.)
    ///
    /// Deliberately OFF. `NudgeOutcomeClassifier` now writes real `.ignored`
    /// rows, which the fatigue predicates already match — so leaving this
    /// implicit ("the data just happens not to line up yet") would have
    /// silently changed which notifications fire the moment the sweep
    /// landed. An explicit flag keeps both consumers readable and armed by
    /// a one-word diff once the recorded classifications have been reviewed.
    static let fatigueGateEnabled: Bool = false

    // MARK: - Tasks message box
    /// How long after a notification body tap the Tasks tab's message box
    /// keeps explaining that nudge before falling through to the ordinary
    /// states (overdue → high-stakes → resting). Long enough to survive the
    /// tap→read gap comfortably; short enough that a lunchtime tap isn't
    /// still narrating itself at dinner.
    static let messageBoxTapContextMinutes: Int = 30

    /// The message box's "something high-stakes is approaching" state only
    /// looks this many days ahead. Beyond it, a high-stakes task is real
    /// but not *approaching*, and the resting state reads better.
    static let messageBoxHighStakesHorizonDays: Int = 7

    /// The daily Opus memo (Sep 2026) regenerates when the facts it was
    /// written from change (a dump lands, a task tips overdue), at most
    /// this many times per day. Past the cap the last memo stands until
    /// tomorrow: stale beats a runaway bill on a day of heavy editing.
    static let tasksMemoMaxPerDay: Int = 4

    /// How many open tasks the memo writer gets to see (soonest deadline
    /// first). Enough for a full picture, small enough that input tokens
    /// stay a rounding error next to output.
    static let tasksMemoOpenTaskCap: Int = 15

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
    /// **Two things stop it, and both mean "name the same task again".**
    /// An empty pool (one open task, already named twice) — the day's
    /// anchor must not go silent on the user with one thing on their list.
    /// And a replacement more than one stakes tier down, which would put
    /// "Biggest thing on your list: Clean my desk" in front of someone with
    /// a high-stakes task open. See `morningPromptRanking`.
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

    // MARK: - Task time windows (placement appropriateness)
    //
    // Boundaries for `TaskTimeWindow`'s bands. Deliberately round and few:
    // the band is a judgment about a task's NATURE, so precise-looking
    // boundaries would be invented precision. `businessHours` additionally
    // requires a weekday — checked at the placement site, not encoded here.

    /// `daytime` band: reasonable waking hours, 9 AM – 9 PM.
    static let daytimeStartHour: Int = 9
    static let daytimeEndHour: Int = 21

    /// `businessHours` band: weekday working hours, 9 AM – 5 PM.
    static let businessHoursStartHour: Int = 9
    static let businessHoursEndHour: Int = 17

    // MARK: - Plan my day

    /// Most tasks one planner run will place. Was an inline `4` in
    /// `planMyDay` since its first version; hoisted here (cycle
    /// 2026-08-02-02) when it gained a sibling below. Four ~45-minute
    /// blocks plus events is a full day for the target user — the planner
    /// proposes a starting point, not a packed schedule.
    static let planMaxPlacementsPerRun: Int = 4

    /// Most prep (study) tasks one planner run will place. Prep tasks are
    /// dated, exam-category, and score high, so without a cap all four
    /// slots can become study blocks — a monoculture, not a plan. Two of
    /// four: near an exam, study still claims half the proposed day (and
    /// two ~90-minute blocks is real study time), while at least two slots
    /// stay open for the rest of life. Caps *placement* only — what
    /// `ExamPrepSweep` creates is untouched, and the user can place more
    /// study blocks by hand.
    static let planMaxPrepPlacementsPerRun: Int = 2

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
    /// FORWARDER — the value lives on `NudgeTask.fallbackEventDurationMinutes`
    /// (the widget target compiles Models only and can't see this file, and
    /// the resolution method `eventDurationMinutes` lives there with it).
    /// Kept here so the tunables index stays complete; tune it there.
    static let defaultEventDurationMinutes: Int = NudgeTask.fallbackEventDurationMinutes

    /// Length assumed when the user schedules a start themselves ("study
    /// at 9am") without saying how long — Roman's rule (Sep 2026): a stated
    /// start with no stated length is an hour. Applied at the capture write
    /// site only; a stated duration always wins.
    static let defaultTimedIntentMinutes: Int = 60

    /// How many recent chat messages ride along with each capture call —
    /// the whole history was re-sent every turn, growing the input bill
    /// linearly with session length (Sep 2026). 12 = six exchanges, enough
    /// for follow-up answers and "the essay I mentioned".
    static let chatHistoryMaxMessages: Int = 12

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

    // MARK: - Prep ("start early") fire time
    //
    // `StartByPlanner` answers WHICH DAY the user should start. It does not
    // answer WHAT TIME OF DAY the nudge should arrive, and it was being
    // used for both — so the nudge inherited the deadline's clock time.
    // Bare due dates normalize to 23:59, which meant every deep-work
    // start-early nudge fired at 23:59 (always inside quiet hours, so it
    // never fired at all) and shallow ones fired at due − effort×2, i.e.
    // 21:59 for a 60-minute task — the night the thing was due, for a nudge
    // whose entire job is prompting an early start.
    //
    // The day now comes from the planner; the hour comes from here.
    // (This nudge was the `.getAhead` kind until Aug 2026, when get-ahead
    // split into `.prep` and `.dueSoon`.)

    /// Hours after wake at which a prep nudge fires on its anchor day.
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
    /// by the morning prompt, idle, and the floater check-in (wake+6h).
    /// When a prep and an idle candidate land on the same day, min-spacing
    /// keeps whichever scores higher — which is the intended resolution: a
    /// nudge naming a specific dated task should beat a generic "have you
    /// started anything?".
    static let prepAnchorHoursAfterWake: Double = 2

    // MARK: - Due-soon reminder
    //
    // Drives `NudgeArbiter.buildDueSoonCandidates` — the "this is landing"
    // half of the Aug 2026 get-ahead split. Budget-exempt like event
    // blocks (a deadline is a fact, not a suggestion), fires once per
    // task, and batches same-hour deadlines into one notification.

    /// Minutes before a task's deadline the due-soon reminder fires.
    static let dueSoonLeadMinutes: Int = 120

    /// Tasks whose deadlines fall within this many minutes of each other
    /// share ONE due-soon notification ("3 things due by 11:59 PM: …"),
    /// reusing the event-block clustering pattern. Per-task banners
    /// bypassing spacing is the swipe-dismiss training the arbiter was
    /// designed against.
    static let dueSoonBatchWindowMinutes: Int = 60

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

    // MARK: - Placement lifecycle (cycle 2026-08-04-02)
    //
    // Drives `NudgeArbiter.buildPlacementLeadCandidates` and
    // `buildPlacementMissedCandidates` — the two nudges around a timeline
    // placement (`plannedStartDate`). Before these, no builder fired on a
    // placement passing unstarted: the only notification-path read of
    // `plannedStartDate` was the floater check-in EXCLUDING placed tasks,
    // so putting a task on the timeline reduced its notification coverage
    // to zero.

    /// Minutes before the first slot of a placement cluster the heads-up
    /// fires. Short on purpose — this is "stand up, it's about to be
    /// laundry time", not the hour-out planning lead events get.
    static let placementLeadMinutes: Int = 5

    /// Placements whose slots are within this many hours of each other
    /// share ONE heads-up (chained clustering, same mechanism as event
    /// blocks). Its own constant rather than `eventBlockGapHours` — the
    /// value is the same today, but planner slots pack tighter than
    /// calendar events, so retuning one must not silently retune the other.
    static let placementClusterGapHours: Double = 2

    /// Minutes past a slot's start before the first missed-placement
    /// follow-up. Long enough that "running ten minutes late" isn't
    /// pestered; short enough that the slot is still mostly salvageable.
    static let placementMissedGraceMinutes: Int = 30

    /// Minutes between missed-placement attempts after the first. 120, not
    /// 60: `minNudgeSpacingMinutes` (90) silently evicts any series denser
    /// than itself, so an "hourly" schedule would really deliver every
    /// other attempt at random. 2h is the honest version of "hourly-ish"
    /// that survives the spacing gate intact.
    static let placementMissedRepeatMinutes: Int = 120

    /// Attempts per missed placement (first at slot + grace, then every
    /// `placementMissedRepeatMinutes`). 4 spans ~6.5 hours past the slot —
    /// the most persistent kind in the app, per the user's own request to
    /// be nudged rather than left alone — and the series always dies at
    /// midnight anyway when `PlacementRollover` clears the placement.
    static let placementMissedMaxAttempts: Int = 4

    /// Urgency floor for both placement kinds. Same reasoning as the prep
    /// floor at `urgentThreshold`, but stronger: the user themselves put
    /// this task at this time, so the plan slipping IS the urgency signal,
    /// whatever the deadline math says. 0.75 lets a placement nudge beat a
    /// same-window floater (0.6) or an un-floored prep without steamrolling
    /// a genuinely imminent deadline.
    static let placementUrgencyFloor: Double = 0.75

    // MARK: - Plan proposals (cycle 2026-09-16-01)
    //
    // Drives `PlanProposalSweep`: for a due-dated task or event worth
    // preparing for, one batched Opus call proposes the sessions, the
    // message box asks, the user's Yes writes.

    /// How far ahead the reader looks for anchored candidates. Matches the
    /// calendar import edge the reader has historically had to live with;
    /// the store may know further out (Item 4), the reader thinks three
    /// weeks ahead.
    static let planProposalHorizonDays: Int = 21

    /// Candidates per batched call, and calls per day. Two calls of five
    /// is the worst case; most days make zero because every candidate
    /// already carries a decision.
    static let planProposalBatchSize: Int = 5
    static let planProposalCallsPerDay: Int = 2

    /// Sessions a proposal may contain, and the length of one session.
    /// Small on purpose: preparation is a handful of short dated steps,
    /// not a second task list.
    static let planProposalMaxSessions: Int = 8
    static let planSessionMinMinutes: Int = 15
    static let planSessionMaxMinutes: Int = 120

    // MARK: - Exam prep sweep
    //
    // Drives `ExamPrepSweep` — the launch/day-change pass that turns
    // exam-category calendar events into daily study tasks
    // (`source == "prep"`), the app's defining feature (DESIGN.md "Study
    // tasks from exam events").

    /// The coarse prep-lead bands the capture classifier may emit for
    /// `NudgeTask.prepLeadDays`. Anything else is invalid and reads as
    /// missing — coarse bands only, no invented precision.
    static let prepLeadBands: Set<Int> = [3, 7, 14]

    /// Lead band assumed when an exam event carries no valid
    /// `prepLeadDays` (deterministic calendar imports never can; the AI
    /// may answer null or nonsense).
    static let defaultPrepLeadDays: Int = 7

    /// How long the message box keeps showing the "I've added study time"
    /// announcement and the one-time tombstone note after each first
    /// renders. Reuses the tap-context freshness idea: a passive display
    /// can't know it was read, so time bounds it.
    static let prepMessageFreshnessMinutes: Int = 30

    // MARK: - Commitment expansion
    //
    // Drives the commitment half of `ExamPrepSweep` (cycle 2026-08-03-01)
    // — the general form of the exam sweep: a brain-dumped commitment
    // ("an hour a day until Friday", "module 4 by Friday") expands into
    // one generated task per day (`source == "commitment"`).

    /// How many days ahead a rate/quantity commitment generates daily
    /// tasks. Matches the exam sweep's largest lead band: a commitment
    /// running months out gets a rolling 2-week window topped up daily,
    /// not a hundred rows at once.
    static let commitmentHorizonDays: Int = 14

    /// Split-work session lengths round UP to multiples of this. Eight
    /// hours across four days must be four two-hour sessions, not eight
    /// scattered fragments — half-hour blocks are the coarsest unit that
    /// still fits real gaps.
    static let commitmentSessionBlockMinutes: Int = 30

    /// Floor and ceiling on one split-work session. The floor keeps a
    /// tiny total from smearing into meaningless slivers (the day count
    /// shrinks instead); the ceiling keeps a huge total from producing a
    /// day-swallowing block nobody starts (`DESIGN.md`: never show a
    /// target that has become impossible) — the schedule then honestly
    /// covers less than the stated total rather than pretending.
    static let commitmentMinSessionMinutes: Int = 30
    static let commitmentMaxSessionMinutes: Int = 240

    /// Quantity carry-over cap, in days' worth of the daily count. A
    /// missed day's shortfall adds to the next day, but the carried
    /// amount stops growing after this many days' worth — a week of
    /// misses shows the same number as three days of misses. An uncapped
    /// carry produces a number the user cannot hit, and a number you
    /// cannot hit is the reason not to start.
    static let commitmentCarryCapDays: Int = 3

    // MARK: - AI nudge copy (generate-ahead cache, cycle 2026-08-03-03)
    //
    // Drives `NudgeCopyGenerator` / `NudgeCopyStore`. The arbiter only
    // READS the cache — generation runs on its own triggers, and every
    // read falls back to the deterministic template.

    /// How long cached copy stays servable. Three days because a user who
    /// stops opening the app is exactly the one who still needs the
    /// scheduled window working.
    static let copyCacheDays: Int = 3

    /// Tasks per kind the generation pass writes copy for. Spacing caps a
    /// day at ~10 nudges across ALL kinds (`dailyNudgeBudget` +
    /// `minNudgeSpacingMinutes`), so a handful per kind still covers the
    /// morning prompt's rotation and normal completion churn across the
    /// window; every-task-every-kind is waste.
    static let copyGenTasksPerKind: Int = 4

    /// Minimum minutes between generation attempts (success or failure).
    /// Collapses duplicate triggers in one launch sequence and stops a
    /// flaky network from turning every foreground into an API call.
    static let copyGenMinMinutesBetween: Int = 15

    /// Hard per-day ceiling on generation passes. The DEBUG count print is
    /// the real watchdog for too-loose triggers; this stops a runaway
    /// trigger from becoming a bill before anyone reads the console.
    static let copyGenMaxPerDay: Int = 6

    // MARK: - Come-back nudge (cycle 2026-08-03-03)
    //
    // Drives `NudgeArbiter.buildComeBackCandidates`. Scheduled on every
    // reevaluate at lastEngagement + `comeBackAfterDays`; engagement keeps
    // pushing it forward, so it only ever FIRES after that many quiet days.

    /// Days without engagement (app open, notification response, task
    /// completion) before the come-back fires. Matches `copyCacheDays`:
    /// the come-back is the last scheduled nudge in the cached window.
    static let comeBackAfterDays: Int = 3

    /// Hours after wake the come-back lands — same slot as prep
    /// (`prepAnchorHoursAfterWake`): late-morning, when what's-coming-up
    /// is still actionable that day.
    static let comeBackAnchorHoursAfterWake: Double = 2

    /// How far past the fire date the come-back looks for the thing it
    /// names ("Chem quiz Friday"). ≤ 6 so a bare weekday name is always
    /// unambiguous.
    static let comeBackLookaheadDays: Int = 6

    // MARK: - Goal lapse (cycle 2026-08-04-03)
    //
    // Drives `NudgeArbiter.buildGoalLapseCandidates` — the bait notification
    // for a personal goal that has gone a month untouched. Come-back
    // mechanics: the fire date derives from the goal's own evidence
    // (`lastActivityAt`, or `createdAt` for the never-started zero case), so
    // any recorded activity pushes it out on the next rebuild. The per-goal
    // history map is what stops re-fires while nothing changes.

    /// Days without goal activity before the bait fires. "A month or more"
    /// per the plan; 30 keeps the arithmetic obvious.
    static let goalLapseAfterDays: Int = 30

    /// Minimum days between two goal-lapse notifications about the SAME
    /// goal — the can't-become-wallpaper cap. Read from the per-goal
    /// delivered-history map in `schedule()`.
    static let goalLapseMinDaysBetweenPerGoal: Int = 30

    /// Hours after wake the bait lands. Mid-afternoon on purpose: the
    /// wake+1.5h → wake+7.5h band is already occupied (morning +0.5, prep/
    /// come-back +2, idle +3, floater +6), and a reflective "it's been a
    /// month" note doesn't compete with the day's start-something pushes.
    static let goalLapseAnchorHoursAfterWake: Double = 8

    /// Prune horizon for the per-goal delivered-history map — must exceed
    /// `goalLapseMinDaysBetweenPerGoal` or the cap erases itself.
    static let goalLapseHistoryRetentionDays: Int = 90

    /// Size of the task the one-tap goal offer creates ("Add a small
    /// step"). Small on purpose — the ask is re-contact with the goal,
    /// not a work session; 20 minutes is startable on a bad day.
    static let goalStepMinutes: Int = 20

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
