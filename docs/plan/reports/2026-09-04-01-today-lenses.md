# Report — 2026-09-04-01 — Today / Tomorrow / This week lenses

**Plan:** `archive/2026-09-04-01-plan.md`
**Status:** complete (device look pending)
**Commits:** `c5d6c78` (archive), `92973e2` (implementation), plus
ARCHITECTURE.md + this report in the report commit

---

## What changed

- `Nudge/Views/Tabs/TasksTabView.swift` only (pure presentation):
  - Day membership helpers: `scheduledDay(of:)` (intent day ?? placement
    day; nil for deadline-only — owed ≠ scheduled), `planDay(of:)`
    (dateless plan task = today), `planTasks(on:)`, `dayTasks(on:)`,
    `dayEvents(on:)`.
  - `TodayLens` enum + chip strip (the `EventLens` pattern, not
    persisted). Today lens = reorderable plan (today's slice) → today's
    events → today's tasks, slot-tinted, Plan-my-day empty state kept.
    Tomorrow = static numbered plan rows, events, tasks, no tints. This
    week = days +2..+7 grouped under `eventDayHeader`.
  - `planSection` takes the day's tasks; `movePlanTasks` reorders today's
    slice with global renumbering (today leads, other days keep their
    relative order among themselves).
  - Old `scheduledTasks` var replaced by `dayTasks(on:)` — membership
    WIDENED from "placed today" to "intended or placed that day", so an
    intended-today-unplaced task now shows under Today (it was
    Unscheduled-only before).
  - `tabHasContent(.today)` = any lens content (plan, any day-task within
    +7, or this-week events).
- `ARCHITECTURE.md` — Today-tab entry rewritten.

## Verification

- Both schemes build clean after the implementation commit.
- **Work-order item 5 does not apply** — pure list presentation; no
  arbiter input changed. (The glue cycle 2026-09-13-01, committed
  earlier the same day, is what changed arbiter behavior; its device
  before/after is tracked separately.)
- Pending Roman's device look: the canonical dump's tomorrow tasks under
  Today→Tomorrow with numerals; Today→Today clean; an event tonight
  above today's task rows; drag-reorder still working in the Today lens.

## Deviations from the plan

- The plan's Today lens said "the existing rows"; membership widening
  means intended-today-unplaced tasks ALSO appear there. Judged the
  plan's own day-rule applied consistently rather than a deviation —
  flagging because those tasks now show in two tabs (Unscheduled +
  Today), which the plan accepted as the known overlap.
- Multi-day plan renumbering semantics (drag on today shifts future
  days' numerals but never their relative order) were unspecified; the
  simplest coherent rule was chosen and documented at `movePlanTasks`.
- None otherwise.

## Noticed but not done

- Lens day-membership calls recompute per render (each is an
  actionableTasks scan); acceptable at one user's task counts, worth a
  memo pass if the tab ever feels slow.
- The Tomorrow empty line says "Nothing scheduled yet." — copy might
  want a day name; left minimal.
- Unscheduled/Today overlap for intended-today tasks (per plan: revisit
  after Roman sees it in practice).

## Open questions

- When the Nudge calendar (step 3) lands, does This week stay a lens or
  collapse into the calendar's week view? Roman leaned "lenses = this
  week, calendar = past this week" — revisit after both exist.
