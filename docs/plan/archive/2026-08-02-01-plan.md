# NEXT — Plan my day diagnosis, Refine removal, daily calendar extension

**Status:** APPROVED
**Cycle ID:** 2026-08-02-01
**Source:** user report, `ROADMAP.md` §3, and cycle `2026-08-01-05`'s
findings

> Still on `automation-run-1`. Separate commits per item. Do not push, do
> not merge.
>
> **Item 1 is investigation only.** Do not fix it in this cycle — report and
> stop. Items 2 and 3 are fixes and can land.

---

## 1 — Diagnose "Plan my day" (investigate, change nothing)

The button does not work. I don't know in what way — nothing happens, wrong
results, or an error — so start by establishing what actually occurs rather
than assuming a failure mode.

This matters more than it did a day ago: **Today's empty state is now a
Plan my day button, and Today is the default tab.** A broken planner is the
first thing a user sees.

Trace `planMyDay()` end to end. Rule in or out, explicitly:

- The plan-list/placed-rows split from cycle `2026-08-01-05`
- The placement rollover sweep clearing `plannedStartDate`
- Prep tasks (`source == "prep"`) entering the candidate pool — five or
  more near-identical dated tasks is a new input shape
- The event-duration consolidation: real durations now mean a 3-hour lab
  occupies 3 hours of busy window where it used to occupy 1, so the day may
  genuinely have no free gaps
- `sequenceIndex` plan-first ordering interacting with placement
- Something older that was never working

Add DEBUG tracing that prints, for one invocation: the candidate pool and
why each task was included or excluded, the computed free gaps with their
start and end times, each placement attempt and its outcome, and the final
count placed. That output is the deliverable.

**One hypothesis worth testing directly:** the report notes that with zero
open tasks `planMyDay()` produces only an error haptic. Confirm whether the
observed failure is that path — a correct refusal that looks like a broken
button — before hunting for a bug. If so, the fix is feedback, not logic.

## 2 — Remove the AI Refine button

`ROADMAP.md` §3. The deterministic planner is the always-on path; AI Refine
was unreachable in any fresh install for months and shouldn't be a
user-facing control.

Remove the button and its entry point from the Tasks tab. **Leave
`DayPlanRefiner` and its Pro gate in the codebase** — this removes a
control, not a capability. Report everything else that referenced it,
including the rationale banner if it becomes unreachable.

## 3 — Calendar window extends daily, not weekly

`CalendarService` extends its 21-day rolling window a week at a time, so
the visible horizon oscillates between 21 and 14 days. The prep sweep's
maximum lead band is 14 days — meaning an exam near the far edge can enter
its lead window while still outside what's been imported, and prep tasks
start late on exactly the exams needing the longest runway.

Extend by one day per day instead, keeping the horizon pinned at 21.

**Say whether the current extension is genuinely incremental or re-reads
the whole window and dedupes.** Both are cheap — this is EventKit reading
the local store, no API calls — but they're different code and the answer
determines whether this is a constant change or a rewrite.

Canvas iCal's 30-day horizon is out of scope; leave it.

## Constraints

- Item 1 changes nothing but DEBUG output.
- `ROADMAP.md` §1 untouched.
- Item 3 touches import, not the arbiter — the before/after should show the
  horizon behaviour across simulated days, not candidate lists.
- `DESIGN.md` governs any copy that changes in item 2.

## Evidence it worked

- Both schemes build after every commit.
- Item 1: the DEBUG trace from one real invocation, and a ranked list of
  what could produce the observed behaviour, with confidence.
- Item 2: Refine gone from the Tasks tab; a list of what else referenced
  it.
- Item 3: horizon pinned at 21 days across simulated day advances, and a
  statement of whether the extension was incremental before.

## Out of scope

- **Fixing Plan my day** — diagnosis only this cycle.
- The Events lens gap: medium-stakes events beyond a week stay unseen in
  this tab by design. The Calendar tab is their home. No change.
- Errand pairing; schedule-based nudge timing; the Lexend fonts.
- Merging or pushing.
