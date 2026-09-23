# Report — 2026-09-13-02 — The Nudge calendar

**Plan:** `archive/2026-09-13-02-plan.md`
**Status:** complete (device look pending)
**Commits:** `777d3a9` (implementation + editor), plan + this report in
the report commit

---

## What changed

- `Nudge/Models/NudgeTask.swift` — `scheduledDay` hoisted to the model
  (intent day ?? placement day ?? nil); TasksTabView's private helper now
  forwards to it.
- `Nudge/Views/Tabs/TasksTabView.swift` — `TaskEditorSheet.apply(draft:
  to:modelContext:)`: the ONE draft-application, intent-aware (intent-only
  task → picker moves `intendedDate` + placement-on-time, never a
  deadline; "No date" releases to floater; both-fields tasks edit the
  deadline). Picker label is kind-aware ("Time"/"Planned"/"Due"); draft
  seeds from intent+placement so the sheet shows the current plan. The
  Tasks-tab edit call site now delegates to `apply`.
- `Nudge/Views/Tabs/CalendarTabView.swift` — the month view: navigation +
  Today jump, weekday grid with per-day dots (event=stone `eventSlot
  Accent`, scheduled=blue `primary`, due=amber), legend, selected-day
  list, tap → shared `TaskEditorSheet` (save path: apply → save → widget
  reload → refreshSoon → arbiter reevaluate, mirroring the Tasks tab).

## Verification

- Both schemes build clean after the implementation commit.
- **Work-order item 5**: the cycle adds no arbiter input and changes no
  builder/gate; the editor's intent routing changes WHAT data an edit
  writes (intendedDate vs dueDate), which the arbiter then reads — but
  that is the deadline/intent split's existing semantics applied to a new
  write path, not new arbiter behavior. Stated rather than skipped.
- Pending device look (plan's evidence list): dots match items; moving an
  intent task's day via the calendar changes `intendedDate` with no
  countdown appearing; an event edit moves its time; a deadline task
  keeps countdown semantics.

## Deviations from the plan

- **Deadline tasks appear on the calendar** (amber "Due") although day
  lenses exclude them — deliberate, argued in the plan itself: an
  orientational month view omitting the essay due Friday reads as broken.
  This is the one place "owed" and "scheduled" both render.
- None otherwise.

## Noticed but not done

- `dayCell` calls `dayItems(on:)` per cell (42 × task-count scan per
  render). Fine at current store sizes; memoize per month if the tab ever
  stutters.
- The editor's create path (`.create`) still writes deadline fields
  directly at its call site — only the edit path went through `apply`.
  Harmless today (create has no intent affordance) but a second writer;
  fold into `apply` when the convert-kind question gets decided.
- Completed items are hidden from the calendar entirely; a "show
  completed" toggle may be wanted someday.

## Open questions

- The floater-given-a-date default (mints a deadline, field says "Due")
  — the standing convert-kind question, now the last place the editor
  can create time pressure by default.
- Whether This-week lens folds into the calendar once Roman has used
  both (his earlier lean: lenses = this week, calendar = past it).
