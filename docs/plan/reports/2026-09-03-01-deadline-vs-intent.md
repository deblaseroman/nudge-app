# Report — 2026-09-03-01 — A deadline is not an intention

**Plan:** `archive/2026-09-03-01-plan.md`
**Status:** complete (device verification pending — see Verification)
**Commits:** `2aff7a1` (archive), `147f18e` (item 1), `83d4cf0` (item 2),
`83d98d7` (item 3 + census), `81434bc` (item 4), plus the ARCHITECTURE.md
update in the report commit

---

## What changed

- `Nudge/Models/NudgeTask.swift` — new `intendedDate: Date?` (day the user
  means to do the work; never a deadline; survives its day passing; never on
  events) and `hasDeadline` convenience. Additive field, no migration, no
  change to the three hand-synced schema lists.
- `Nudge/Services/ClaudeService.swift` — `chatSystemPrompt` requires
  `dueKind: "deadline" | "start"` on every dated task, with the category rule
  (owed vs meant-to-do) and the asymmetric default (uncertain → start);
  `TaskData` gains the field.
- `Nudge/Views/Tabs/HomeTabView.swift` — capture write site: `deadline` →
  dueDate/dueTime/specificTime exactly as before; `start` → `intendedDate`
  (+ manual placement `plannedStartDate` when a clock time was stated,
  `plannedIsAuto` false); missing/unknown kind reads as start. Deadline
  fields stay nil on intents.
- `Nudge/Services/NudgeArbiter.swift` — `floaterTargets` fetch: no deadline
  AND no fire-day-or-future `intendedDate` (slipped intents are targets).
  The population fix the floater baseline was waiting on.
- `Nudge/Services/DayPlanEngine.swift` — today's intents are must-place
  candidates: after `sequenceIndex` plan tasks, ahead of score-ranked fill,
  oldest-first within the group; DEBUG candidate dump prints them.
- `Nudge/Views/Tabs/TasksTabView.swift` — intent-only rows show a muted day
  label ("Tomorrow"/"Sat"/"Sep 12"); past intent days stay muted
  (never-shame), no countdown/coral/overdue possible without a deadline.
- `Nudge/NudgeApp.swift` — `TEMP-INTENT-AUDIT` DEBUG launch dump proposing a
  classification for every open dated task; writes nothing; no auto-apply
  path exists. Grep the tag to remove.
- `docs/plan/CONTEXT.md` — census: floater row targeting, capture site
  description, not-armed floater prose, stamp → `83d4cf0` @ 2026-09-03-01
  (same commit as the floater change, per CLAUDE.md).
- `ARCHITECTURE.md` — NudgeTask entry: three scheduling concepts, deadline
  fields now mean only owed work.

## Verification

- Both schemes built clean (no errors, no warnings) after each of the four
  item commits — eight builds.
- **Work-order item 5 applies and is NOT yet satisfied**: items 2–3 change
  what the arbiter sees (captured placements feed placementLead/Missed; the
  floater fetch changed). The before/after tooling exists (floater SKIP/
  target prints, DayPlanEngine candidate dump, TEMP-INTENT-AUDIT), but the
  comparison must run on the real store on Roman's device. Until that run,
  this cycle is code-complete, not evidence-complete. Concretely: launch in
  DEBUG, read TEMP-INTENT-AUDIT and the arbiter's floater lines, then
  re-dump the canonical phrases ("study python for an hour tomorrow at 7" →
  intent + placement, no countdown; "essay due Friday 11:59pm" → deadline
  with countdown).
- Old rows are untouched by construction: nothing writes `intendedDate` on
  existing data, and the audit dump is print-only.

## Deviations from the plan

- The floater's "today-or-future" exclusion is evaluated against the FIRE
  day (which is tomorrow after the builder's rollover), not calendar-today —
  a task intended tomorrow is excluded from tomorrow's check-in, which is
  the plan's intent stated more precisely than the plan stated it.
- None otherwise. All four items shipped at the described size.

## Noticed but not done

- **The dedupe guard now has a new blind spot variant**: an incoming intent
  task stores `dueDate` nil, so the guard's nil-date fallthrough suppresses
  any title-matching re-dump regardless of day. Pre-existing shape (guard
  redesign already deferred by cycle 2026-08-05-02), but the intent split
  widens the nil-date population; the drop logs from -02 will show it if it
  bites.
- Generated prep/commitment rows still use `dueDate` as "their day" —
  semantically closer to intent, deliberately untouched: `ExamPrepSweep` and
  `DayPlanEngine` key on it, and those rows never show countdowns in
  practice (day labels replaced their countdown in cycle 2026-08-03-02).
  Worth folding into a later cycle if their overdue behavior ever grates.
- The widget shows nothing for intent-only tasks' day (its `dayName` reads
  deadline fields). Harmless — day-organized views are next cycle's work.
- `send(userMessage:context:)`'s "default dueDate to today" line (flagged in
  the -02 report) is now doubly wrong under the split; still out of scope,
  still queued.

## Open questions

- When day-organized tabs land (next cycle), should "Today" mean
  `intendedDate == today OR placed today OR due today`? That union is the
  natural reading, but it needs Roman's eye on what the plan list becomes.
- Should the item-4 classification ever get a one-shot apply, or is
  hand-fixing the handful of rows the end state? Roman decides after reading
  the audit table on device.
