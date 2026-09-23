# Report — 2026-09-16-02 — Realignment additions and cleanup

**Plan:** none archived. Built directly from Roman's rulings in chat on
Sep 16 2026 ("Yes add that, then start on the build and cleanup") against
the additions list and removal candidates in `SYS-VIS-10` and the previous
cycle's out-of-scope section. Recorded here so the bus has the pairing.
**Status:** complete (device look pending)
**Commits:** `2d97c64` (user plan override), `a83164e` (importance
ladder), `6dd3f43` (legacy stubs), `ef348de` (Skipped section + replace-
overdue-duplicate), `bdc05e3` (empty Today fillers), `46bcefc` (condensed
titles), `4656723` (refiner gate, stakes backfill, lead bands,
expressions), `3d3f8fe` (two-clock editor); docs in the report commit.

---

## What changed

Additions (Roman's list):
- `PlanProposalSweep.applyUserPlanOverrides` + `userPlanMatch` — the user's
  own plan deletes app-made sessions for that anchor and marks it
  `userOwned`; runs before every reader pass and after editor saves.
- `EisenhowerScorer.importance` — due-date ladder ahead of the mix
  (`NudgeConfig.dueDatedImportance` 0.6, `dueTodayImportance` 0.9); six
  call sites pass `hasDueDate` / `isDueToday`.
- `NudgeTask.skipCount` / `isSkipCandidate` / `isSkipped`;
  `PlacementRollover` counts skips, reschedules once, releases on the
  second; `TasksTabView` gets the Skipped tab, excludes skipped rows from
  Unscheduled and day lists, resets the count on manual placement or
  dating; the widget hides skipped rows. `HomeTabView` dedupe replaces an
  overdue or skipped duplicate instead of dropping the new task.
- `TasksTabView.todayLensBody` — empty Today lists `fillerCandidates`.
- Capture prompt — TITLES rule (short noun phrases, keep identifiers).
- `TaskEditorSheet` — two clocks for tasks (Reschedule: Day / Time,
  No date / No time; Due date: Due / Due time, No due date / No time),
  touch-flagged writes in `apply`, both clocks on create; events keep one
  Time picker. `TaskDraft` gains `intendedDate`, `plannedStart`, the touch
  flags and their helpers.

Cleanup (Roman-approved candidates):
- Deleted: `TaskScheduler`, `SmartNotificationEngine`,
  `NotificationMessageGenerator`, `FocusSessionManager`, `DayPlanner.swift`,
  `StakesBackfill.swift`.
- `DayPlanRefiner` / `HomeTabView.handlePlanIntent` — Pro/trial gate and
  `notEntitled` removed (columns stay).
- `ClaudeService` — `classifyStakes` and its DTO removed; `prepLeadDays`
  removed from both prompts, `TaskData`, the screenshot DTO and mapping;
  `NudgeConfig` loses the backfill block and `prepLeadBands` /
  `defaultPrepLeadDays`; `ExamPrepSweep.validLeadBand` removed;
  `ScreenshotCalendarImporter` no longer writes the band; `NudgeApp` no
  longer kicks the backfill. `NudgeTask.prepLeadDays` stays as a tombstone.
- `MessageBoxExpression` — `asking` / `pleased` removed.

## Verification

- Both schemes build after every commit; no new warnings in touched files.
- Not run here (no device): the Skipped counter across a real day change,
  the editor's two clocks on a real task, and work-order item 5's arbiter
  before/after for the importance ladder. The ladder changes candidate
  scores for every due-dated item (most rise to 0.6 / 0.9 from the mix's
  0.4–0.9 range), which changes winner selection among discretionary
  nudges. Roman's next device run should dump `[NudgeArbiter]` candidates
  before and after on a day with mixed dated and undated work.
- The title rule and the plan reader prompt have not been sent live.

## Deviations from the plan

- No plan file existed for this batch; Roman directed it in chat. This
  report is the record.
- The Skipped threshold lives on `NudgeTask` (`skipsBeforeSkippedSection`)
  rather than in `NudgeConfig`, because the widget target compiles the
  model without the config; `NudgeConfig` forwards to it.
- Title condensing is prompt-side only. Display-side condensing of stored
  or imported titles was not built: imported items are never altered, and
  a deterministic condenser would guess.
- The legacy write-only Settings toggles had no UI rows to remove; the
  columns stay.
- The per-task Haiku enrichment (`NudgeIntelligence`) was left alone: it
  feeds the undated ranking Roman said to keep.

## Noticed but not done

- Study tasks created by the old sweep before Sep 16 and commitment
  dailies still carry per-day due dates (two-clock rule not applied to
  existing rows).
- `DESIGN.md` "Study tasks from exam events" still describes silent
  creation; Roman's file, flagged.
- The memo's copy fix ("a process for later").
- `SYS-CAL-08` FIG 2 still draws the exam sweep's lead bands; section 4
  records their removal in prose.

## Open questions

- Should a task moved back out of Skipped by Plan my day (auto placement)
  also reset `skipCount`? Today only a manual placement or a date does.
- The fillers list in an empty Today shows due-dated work "that could be
  done early"; whether that should be limited to the next N days is
  Roman's call.
