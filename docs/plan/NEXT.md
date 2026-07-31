# NEXT — Fix Plan my day, and plan automatically each morning

**Status:** APPROVED
**Cycle ID:** 2026-08-02-02
**Source:** cycle `2026-08-02-01`'s diagnosis, confirmed on device

> Still on `automation-run-1`. Separate commits per item. Do not push, do
> not merge.
>
> Items 1–2 are the fix. Item 3 changes the planner from a button into
> something that runs on its own — **do that one last**, once the fix is
> verified.

---

## Confirmed on device

```
window: wake+30 8:30 AM → bed−60 11:30 PM, scan from 4:06 PM
❌ EMPTY WINDOW — dayEnd ≤ scanStart. SILENT return.
```

The `11:30 PM` there is **yesterday's** — bedtime 00:30 is computed on
today's date, so bed−60 lands the previous evening. The button has never
worked on this profile.

---

## 1 — Anchor the day to wake time

**Wake is the anchor; bedtime is just how far the day extends.** A day runs
from wake to bed. If bedtime is earlier on the clock than wake, it's late in
*this* day, not early in the previous one — so bed 00:30 with wake 08:00
means 08:30 today → 23:30 today.

Write it that way rather than as a midnight special case. The bug wasn't
midnight arithmetic, it was treating bedtime as a same-calendar-day value.

**One derivation, not several.** `BusyWindowResolver` already reasons about
this and `dayLoad` documents the contract ("a past-midnight bedtime
collapses it — callers should fail OPEN on nil"). `planMyDay()` re-derives
inline and fails **closed and silent**. Consolidate.

**Find every other copy.** `DayPlanRefiner` computes a planning window too.
This codebase has burned repeatedly on duplicated logic drifting — event
durations were implemented four times with two wrong, countdown text twice
and disagreeing. Report every place that derives a day window and which now
share one implementation. Any copy that still has the old math has this bug
and nobody has noticed.

## 2 — Never fail silently

Three outcomes currently produce nothing, or an indistinguishable error
haptic:

- Window collapsed (item 1 fixes it; keep the guard as a backstop)
- No open unplaced tasks — a **correct refusal**
- Tasks exist but no gap fits — also correct, and increasingly likely now
  that a 3-hour lab occupies 3 real hours plus a 1-hour pre-event buffer

Each says what happened, in the **message box** as a new composer state.
`DESIGN.md`: state the fact, never a verdict. "Nothing to plan — your list
is clear" and "No room left today — your calendar is full" are facts. "You
have too much on" is a judgment.

Priority above resting, below overdue. Clears on the next successful plan.

**Also cap prep placements per run.** Prep tasks are dated, exam-category,
~90 minutes, and can outrank everything — so all four slots can become
study blocks. Near an exam that's arguably right; as a general rule it's a
monoculture, not a plan. Constant in `NudgeConfig`; say what you chose.
This caps *placement*, not what `ExamPrepSweep` creates.

## 3 — Plan automatically on the first foreground of a new day

**Do this after 1 and 2 are verified.**

The user should wake to a planned day rather than pressing a button. But
**iOS will not reliably run this app at a chosen hour** — suspended apps
don't execute on a schedule, and background refresh is honored at the
system's discretion. Anchoring to a wall-clock time before wake would be
unreliable by construction.

Instead: run the planner on the **first foreground of a calendar day**,
using the same launch/scene-active hook `PlacementRollover` and the calendar
refresh already use. The morning prompt fires at wake+30 and brings the user
in, so the plan is ready within moments of them looking. Same felt
experience, no dependence on background execution.

Requirements:

- **Once per day.** A date marker in App Group defaults, same shape as the
  rollover's.
- **Never disturbs manual placements.** Auto-planning places into free gaps
  and leaves `plannedIsAuto == false` tasks alone — that distinction exists
  for exactly this.
- **Never silently replaces an existing plan.** If today already has auto
  placements, do nothing; the user can re-plan by hand.
- **Announce it** in the message box: what got planned. That's the surface's
  job, and an auto-plan the user didn't ask for should explain itself.
- The button stays, as a manual re-run. With auto-planning, a second tap
  should clear auto placements and re-place rather than erroring on an
  empty candidate pool. The existing **Clear plan** button now overlaps —
  say whether you merged them and why.
- Order matters: this must run **after** the calendar refresh and
  `PlacementRollover`, or it plans against stale events and stale
  placements. Confirm the ordering in `ContentView`.

## Constraints

- `ROADMAP.md` §1 untouched.
- Items 1 and 3 change what gets placed — before/after per work-order item
  5, on real data, including a past-midnight bedtime profile.
- Item 2's copy is governed by `DESIGN.md`.
- The DEBUG trace must print **dates** on every window boundary. The line
  that made this hard to read said `11:30 PM` when the whole bug was which
  day it belonged to.
- If item 3 turns out to be larger than described — particularly the
  ordering guarantees — ship items 1 and 2 and report rather than guessing.

## Evidence it worked

- Both schemes build after every commit.
- **With bedtime 00:30, Plan my day places tasks.** The headline; it has
  never worked on this profile.
- The trace prints dates and shows a window ending 23:30 *today*.
- Each no-placement outcome produces its own message-box line.
- A day with five prep tasks doesn't fill every slot with study blocks.
- Item 3: a first foreground on a new day produces a plan without a tap,
  runs once, leaves manual placements alone, and announces itself.

## Out of scope

- Errand pairing; schedule-based nudge timing; the Lexend fonts.
- Any AI call in the planning path — `DESIGN.md`, planning is arithmetic.
- Merging or pushing.
