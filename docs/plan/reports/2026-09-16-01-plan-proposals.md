# Report — 2026-09-16-01 — Plan proposals: the app builds the steps, the user says yes

**Plan:** `archive/2026-09-16-01-plan.md`
**Status:** complete (device look pending)
**Commits:** `fa05cbb` (item 1), `d3d5dd5` (item 2), `7c6cf8c` (item 3),
`3350460` (item 4); plan archive, this report, ARCHITECTURE.md, CONTEXT.md
in the report commit

---

## What changed

- `Nudge/Services/PlanProposalSweep.swift` (new) — the reader and the
  writer. `candidates` picks open, due-dated tasks and events inside
  `planProposalHorizonDays` with no decision for their current anchor and
  nothing already pointing at them (user study task by title match, or
  existing sessions). `runIfNeeded` sends one batched Opus call and stores
  verdicts in `PlanProposalStore` (app-group JSON, keyed on the anchor's
  day). `currentProposal` returns the soonest live proposal for the box and
  prunes stale ones. `accept` writes one `NudgeTask` per session with
  `intendedDate`, no due date, `source = "prep"`, `linkedEventId` = parent,
  the parent's category and stakes; tombstone-aware, idempotent.
  `decline` records a No. `requestPlan` is the chat-consent path: builds
  rather than judges, writes at once, announces. `PlanQuestionStore` holds
  the chat's outstanding question for the day.
- `Nudge/Services/ClaudeService.swift` — `proposePlans` (Opus 5, effort low,
  refusal fallbacks, first text block, JSON array, ids filtered to what was
  asked). `ClaudeResponse` gains optional `plan_question` / `plan_consent`.
  Capture prompt: the STUDY PLAN rule and the two optional keys in the
  schema. Removed: `generatePrepPlan`, its prompt, `PrepPlanResponse`,
  `PrepBlockData`, and the two orphaned request/parse helpers.
- `Nudge/Services/NudgeConfig.swift` — `calendarImportHorizonDays` (180),
  `planProposalHorizonDays` (21), `planProposalBatchSize` (5),
  `planProposalCallsPerDay` (2), `planProposalMaxSessions` (8),
  `planSessionMinMinutes` (15), `planSessionMaxMinutes` (120).
- `Nudge/Services/ExamPrepSweep.swift` — the exam half no longer creates
  study tasks; `Decision` and `decide` removed with it. `writeAnnouncement`
  is internal now (the consent path uses it). `recordDeletionIfGenerated`
  stamps `dueDate ?? intendedDate`. Header rewritten. Commitment half
  untouched.
- `Nudge/Services/CalendarService.swift` — `rollingWindowDays` reads the
  config horizon; iCal import and the feed check use it instead of 30;
  `refreshICalFeedIfNeeded` (daily, stamped, retried on failure);
  `resetRollingWindowCursor` also clears the iCal stamp;
  `detectHighPriorityEvents` removed (no caller).
- `Nudge/Views/Components/TasksMessageBox.swift` — composer state
  `planProposal` (above the memo, below tapped nudge and one-time news),
  `planProposalMessage` builder, Yes / No capsules rendered when the
  message is the proposal, `onAnswerPlanProposal`.
- `Nudge/Views/Tabs/TasksTabView.swift` — `planProposal` state read on
  appear, foreground, and the sweep's change notification;
  `answerPlanProposal` accepts (then widget reload + reevaluate) or
  declines.
- `Nudge/Views/Tabs/HomeTabView.swift` — `hasOutstandingModelQuestion`
  includes the plan question; `planParent(named:among:)` resolves the exam;
  after a capture, records the question or acts on the consent; runs the
  reader after a capture that created rows.
- `Nudge/ContentView.swift` — `PlanProposalSweep.runIfNeeded` after
  `ExamPrepSweep.run` in both chains; the iCal daily refresh beside the
  Apple Calendar one.
- `Nudge/Views/Tabs/CalendarTabView.swift`,
  `Nudge/Views/Onboarding/CalendarImportStepView.swift` — the reader runs
  after either import; comments updated.

## Verification

- Both schemes build after every commit (`xcodebuild`, generic iOS
  Simulator destination), no new warnings in touched files.
- **Work-order item 5 (DEBUG before/after on real data): not run here.**
  This session has no device or simulator store to run the app against.
  The arbiter's inputs change in exactly one way: exam events no longer
  produce silent study tasks, so the prep and due-soon builders see fewer
  generated rows until the user says Yes. The change is inert for every
  other builder by construction (no builder reads `PlanProposalStore`,
  and accepted sessions are ordinary `source == "prep"` rows with an
  intended day, which the placement builders already handle). Roman's next
  device run should compare the `[NudgeArbiter]` candidate dump before and
  after a Yes on a real exam; that is the honest evidence this cycle lacks.
- The reader's request shape (Opus 5, `output_config.effort: low`,
  `fallbacks: "default"` + beta header) is the same shape the memo used and
  which was verified live on Sep 16 (~950 in / ~185 out tokens). The
  `proposePlans` prompt itself has **not** been sent live; the first real
  run will print `USAGE ... site=planProposal` and any parse failure
  verbatim under DEBUG.
- Assumed, not verified: that the capture model reliably emits
  `plan_question` in the same turn it asks. If it asks in prose without
  the key, the answer would route to the small-talk lane; the DEBUG
  `[Router]` line makes that visible.

## Deviations from the plan

- **Chat consent skips the second Yes / No** (as written in item 3) but
  the plan said the reader "runs for that item"; implemented as a
  dedicated `requestPlan` that marks the candidate `consented` so the
  model builds rather than judges. Otherwise a consented exam could come
  back "not worth a plan" after the user said yes.
- **Dead code removed beyond the plan's list:** `detectHighPriorityEvents`
  in `CalendarService` and the two orphaned prep-plan helpers. Both had no
  callers and the reader is their replacement; leaving them contradicted
  Roman's "remove what no longer serves".
- **`rollingWindowDays` became a computed property** over the config
  constant rather than a rename, so every existing call site kept
  compiling.

## Noticed but not done

- `DESIGN.md` "Study tasks from exam events" still describes silent
  creation ("create study tasks daily... tell the user in chat"). Roman's
  Sep 16 ruling supersedes it (ask first). DESIGN.md is Roman's file;
  flagged for him rather than edited.
- Existing sweep-made study tasks in stores keep their per-day due dates;
  only new sessions are scheduled-not-due. A migration was out of scope.
- Commitment dailies still carry per-day due dates (plan said Phase 2).
- The Skipped section, the Due Date editor section, the importance
  ladder, title condensing, and the empty-timeline Today list remain
  Phase 2 candidates in the plan's out-of-scope list.
- `AI-BEHAVIOR.md` card 3 and `SYS-VIS-10` / `SYS-CAL-08` updated in the
  report commit (maps stay true).

## Open questions

- Should the message-box proposal also be able to show while the memo is
  cached from before the proposal landed? Today the proposal simply
  outranks the memo, so yes; noting in case the memo's copy fix changes
  the seam.
- The reader's 21-day window versus the new 180-day store: a final six
  weeks out is now in the store but is not proposed until it is 21 days
  away. Roman's three-week-read map (SYS-HRZ-09) is the design for
  advancing that; unchanged here.
