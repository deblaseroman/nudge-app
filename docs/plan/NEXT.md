# NEXT — The day model (remodel, cycle 1 of 4)

**Status:** SHIPPED — commit 3673a3d, Sep 30 2026; report at
`reports/2026-09-30-01-day-model.md` (the phone audit section is filled at
the next unlocked launch). Approved by Roman's "go along with that plan"
after the revert point `pre-remodel-2026-09-30` (tag + `archive/` branch,
both on origin) was confirmed saved. Cycle 2 (the planner as the brain) is
next; see the outline below and the report's open question.
**Cycle ID:** 2026-09-30-01
**Source:** Roman, Sep 30 2026: "if it can't even tell the difference
between a task or event, or understand how to organize the timeline, what
use does it have?" Written by Claude Code directly against the working
tree after a full inventory of the scheduling-field readers (40 files) and
the notification system (10 live kinds).

> On `main`. Both schemes build after every commit. Every commit is pushed.
> This cycle is the foundation; cycles 2–4 below are outlined so the
> foundation is laid for them, and each gets its own NEXT.md when it starts.

---

## The remodel, in one page

Every bug of the last two weeks lived in one layer: what a task IS on a
given day. Rent was owed today but not scheduled today. Anthropic reading
was placed today, intended for Sep 24, overdue, low stakes, and four rules
each hid it from one list. The work shift got split because a task rule
reached an event. None was one bad rule; each was two sensible rules
meeting for the first time. The fix is fewer concepts and one answer to
"what is today", not more rules.

**Two facts per item**, everything else derived:

1. **The anchor** — when it happens (event: `specificTime`) or when it is
   owed (task: `dueDate` / `specificTime`). Optional on tasks.
2. **The plan** — the day the user will work on it (`intendedDate`, now
   read as *plan day*) and optionally the time (`plannedStartDate`,
   `plannedDurationMinutes`, `plannedIsAuto`). A day without a time is
   legal. A time without a day is not.

Fields keep their names (the model header forbids renames and the eval
corpus asserts on the observable names). What changes is the meaning of
`intendedDate` — from "the day the user once meant, kept as history" to
"the day this task is currently planned for, today or later" — and the
single membership rule every surface reads.

**Five rules** replace the ones in force:

- R1 **Day membership.** A task belongs to day D if its plan day is D or
  its anchor day is D. An event belongs to its anchor day only.
- R2 **Overdue** is an open task whose anchor has passed. No stakes filter.
  Stakes changes ranking and tone, never visibility.
- R3 **Unscheduled** is an open task with no plan day. Overlap with
  Overdue is allowed; hiding is not. Nothing is ever hidden by a rule,
  only sorted by day.
- R4 **Kind is decided once** at capture (or by the user's one-tap flip)
  and no downstream rule branches on it silently. Cycle 2 enforces this
  in the planner; this cycle only removes kind-dependent hiding.
- R5 **The planner is the only automatic writer of plans.** User writes
  (editor, chat, drag) are manual; import and capture write the stated
  day; everything else asks the planner.

**Cycle order** (each its own NEXT.md; this file is cycle 1):

1. **Day model** (this cycle): the rules above on the model, every reader
   and writer moved to them, the rollover rewritten, Skipped folded into
   Unscheduled, capture's due-today rule, eval cases, before/after on the
   phone.
2. **The planner is the brain**: `DayPlanEngine` the sole automatic plan
   writer; anchor-today and plan-today tasks are must-place; the model
   orders candidates into gaps with reasons (promote `DayPlanRefiner` from
   a daily-cached refiner to the planner's ordering step, validated
   against the constraints before writing); the work-shift bug fixed at
   the root (a rule that reads kind cannot reach an event). Roman's
   post-office note is the acceptance case.
3. **Notifications carry the plan**: the ten kinds collapse to three
   (morning plan, one mid-day check only if nothing started, anchor
   reminders); copy written at scheduling time from the candidate list
   with real context and swapped into the pending requests by identifier;
   the arbiter keeps timing, budget, spacing, quiet hours. placementMissed
   (30 of the last 48 deliveries) is retired.
4. **Message box on triggers**: not a daily memo; speaks when the plan
   changed, something slipped, an anchor enters the next two days, or the
   app opens after ignored nudges. Otherwise quiet.

---

## Cycle 1 — what to build

### Item 1 — The rules live on the model

`Nudge/Models/NudgeTask.swift` (the widget compiles Models only, so the
rules must live here):

- **Plan invariant helpers**, the only way to write a plan from now on:
  `setPlan(day:start:durationMinutes:auto:)` (normalizes `intendedDate` to
  startOfDay; a `start` forces `intendedDate` to its day; `auto` writes
  `plannedIsAuto`), `clearPlanTime()` (keeps the day), `clearPlan()`
  (clears day and time, resets `plannedIsAuto`). Events: `setPlan` is a
  no-op in release and an assertion in DEBUG.
- **`planDay`** — the day-granular read of `intendedDate` (name the
  concept; keep the column). `scheduledDay` stays as an alias of
  `planDay` for the eval observable, documented as such.
- **`belongs(to day:)`** — R1. **`isUnscheduled`** — R3. `isOverdue`
  unchanged (R2 is a reader change).
- **`TaskList`** enum (`today(day)`, `unscheduled`, `overdue`) and
  **`lists(on today:now:)`** returning the set a task appears in. This is
  the single membership function; the Tasks tab, the widget, the calendar
  and the harness call it.
- `dayTasks` / `planTasks` / `dayLens` keep their signatures and read
  `belongs(to:)` instead of `scheduledDay`. A plan task with no plan day
  no longer "reads as today" on the read side — capture gives dateless
  plan items today's plan day (item 3), which is the same behavior with
  one writer instead of a read-side exception.
- `isSkipped` / `isSkipCandidate` — **removed** from every filter. Keep
  `skipCount` (data) and one read helper `slipCount` for the row label.
  `intentIsFuture(asOf:)` keeps its name and semantics (plan day after the
  reference day).

### Item 2 — Every reader moves to the rules

From the inventory (`docs/plan/reports/2026-09-30-01-*.md` will carry it):

- `Nudge/Views/Tabs/TasksTabView.swift`: `unscheduledTasks` = R3;
  `overdueTasks` = R2 (drop `stakes != .low`); `sortedTasks` drops the
  `isSkipped` filter; **the Skipped tab is removed** (`TaskListTab.skipped`,
  `skippedTasks`, `skippedTab`, its chip and `tabHasContent` case);
  Unscheduled rows get a muted "slipped N days" line when `skipCount > 0`;
  `fillerCandidates` reads `lists`; `tabHasContent(.today)` reads
  `belongs`; `rowTreatment` keeps stakes for the RED treatment only (row
  color is tone, not visibility — allowed by R2).
- `NudgeWidget/NudgeWidget.swift`: drop the `isSkipped` pool filter;
  `dayLens` unchanged in name.
- `Nudge/Views/Tabs/CalendarTabView.swift`: `dayItems` uses `belongs`; an
  item whose plan day is D draws as scheduled, else its anchor day draws
  as deadline (same two kinds as today, one rule underneath).
- `Nudge/Services/DistractionMonitor.swift`: `dayLens` — unchanged.
- `Nudge/Services/DayPlanEngine.swift`: `intentCandidates` = tasks that
  **belong to the planning day** (plan day OR anchor day = D); `
  belongsElsewhere` = plan day ahead and not D. Nothing else this cycle
  (the planner rewrite is cycle 2).
- `Nudge/Services/NudgeArbiter.swift`: `floaterTargets` = open, undated,
  **no plan day** (was: plan day before the fire day — a slipped intent
  now becomes today's plan or Unscheduled, never a stale past day);
  morning / idle glue (`intentIsFuture`) unchanged.
- `Nudge/Views/Components/TasksMessageBox.swift` `whenPhrase` — reads
  `planDay`; no semantic change.

### Item 3 — Every writer goes through the helpers

- `Nudge/Services/CaptureWriter.swift`: `dueKind == "deadline"` → anchor;
  **if the due day is today, plan day = today** (the rent rule; the narrow
  version — a later due day does not glue). `"start"` → `setPlan(day:,
  start:)`. **Plan items (`sequenceIndex != nil`) with no stated day get
  plan day = today.** Floater rule unchanged.
- `Nudge/Views/Tabs/HomeTabView.swift` task_updates `"start"` path →
  `setPlan`. `"deadline"` → anchor, plus the due-today rule.
- `Nudge/Views/Tabs/TasksTabView.swift` `TaskEditorSheet.apply` and the
  create path → `setPlan` / `clearPlan`; the "due follows a later plan
  day" rule stays; `placeTask` / `unscheduleTask` / `clearPlan` →
  helpers (clearPlan on auto placements clears day and time: the planner
  gave the day, undo takes it back; manual placements untouched).
- `Nudge/Services/TimelineReflow.swift`, `DayPlanRefiner.swift`,
  `CalendarService.swift` (`applyImportedSchedule` + backfill),
  `PlanProposalSweep.swift` (`accept`) → helpers. No semantic change.
- **`Nudge/Services/PlacementRollover.swift`** rewritten around I3 (a plan
  is today-or-later): a time earlier than today is cleared (manual
  included, as now); an open task whose plan day is earlier than today:
  `skipCount += 1`; below `skipsBeforeSkippedSection` → plan day = today
  (Roman's one retry, Sep 16), else → `clearPlan()` (Unscheduled, labeled).
  Applies to **every** open task with a slipped plan day, owed or not
  (owed ones also sit in Overdue — R3 overlap). `source == "prep"` keeps
  the missed-session rule; `source == "commitment"` keeps its carry rules
  (excluded from the skip counter as today).

### Item 4 — Evidence

- **DEBUG visibility audit** (`NudgeApp.swift`, beside the two TEMP
  dumps): for every open task, the lists it is in under the OLD rules
  (computed inline from the old predicates, frozen in the dump) and under
  `lists(on:)`. Run on Roman's phone via the console launch **before** the
  readers switch (only item 1 landed) and **after** (everything landed);
  both outputs go in the report. Work-order item 5 satisfied on real data.
- **Eval**: `EvalHarness.actualFields` gains `lists` (sorted, comma-joined
  names for today) and `slipCount`; keeps every existing observable.
  Cases added to `eval/cases.json` (local kinds, free): the Anthropic shape
  (owed −6d, plan day −6d, placed today, low stakes → after the sweep:
  `today,overdue`, skipCount 1); owed today, no plan (→ `today`); slipped
  twice, undated (→ `unscheduled`, never hidden); dateless plan item (→
  `today`); an event never gains a plan (`editor` case); rent as a
  `capture` case (paid, `unverified: false` once run). `eval/run.sh
  --local-only` passes; the capture half runs once and its `CACHE` line
  is reported.

### Item 5 — Docs, same commit

`CLAUDE.md` (work order: the day model is in force; the "owed ≠ scheduled"
constraint is retired; Skipped tab gone), `ARCHITECTURE.md` (NudgeTask,
TasksTabView, PlacementRollover, CaptureWriter entries), `DESIGN.md` (new
section "The day model": two facts, five rules — product intent, so it
lives here), `docs/plan/CONTEXT.md` (census: floater targeting, the
Skipped counter; stamp), `ROADMAP.md` (the remodel's cycles 2–4 at the top
of section 2; "gates find the next viable slot" and "schedule-based nudge
timing" fold into cycle 3).

## Scope boundary

In: the model rules, readers, writers, rollover, Skipped removal, capture's
due-today and dateless-plan rules, audit, eval, docs. Out: the planner's
ordering step (cycle 2), any nudge kind change (cycle 3), the message box
(cycle 4), the Screen Time restart suspicion (separate, unconfirmed).

## Why

DESIGN.md: "design for someone at their least capable" — the user said
"today" and the app filed it where they must go find it. "The app should
create a plan for the user" — it cannot plan a day it cannot define.
Roman's Sep 28 import ruling already put both clocks on imported rows;
capture and the lists now agree with it. Conflicts: the Sep 4 "owed is not
scheduled" rule and the Sep 16 Skipped tab are reversed by Roman's Sep 30
decision; both recorded in the report.

## How to verify

Both schemes build; `eval/run.sh --local-only` green; the phone audit
before/after; the arbiter's console on the phone after (no new kinds fire,
placementMissed keeps its behavior until cycle 3); Anthropic reading
visible in Today and Overdue; rent-shaped capture lands in Today.
