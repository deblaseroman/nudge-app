# Nudge at the edges: a notification system from scratch

Sep 25 2026. Read-only proposal, nothing built. Designed without the
arbiter as a given; it reuses the app's data and several of its parts,
but the shape is different.

## The idea in one sentence

The app only speaks at the edges of things the user planned: the start
of a block, the end of a block that did not happen, the last moment an
owed thing can still be done, the start of the day, and the end of the
week. Never in the middle of anything, never on a clock of its own.

Today the arbiter runs ten independent builders that each propose
moments, then a budget, spacing, and gates arbitrate between them. Most
of that machinery exists to stop the kinds from colliding. In this design
they cannot collide, because every message hangs off a block on the
timeline and blocks do not overlap once the reflow has run. So the budget,
the spacing gate, and the busy gate disappear; quiet hours matter for only
two message types; and the day's count is set by the day's plan, not by a
cap.

## The unit is the block

Everything the user means to do becomes a block with a start and a
length, on the day it belongs to:

- A placement the user made, or the planner made: already a block.
- An intent with a day but no time: the planner gives it a block the
  morning of that day, inside the day window, around the anchored items.
- An owed task (due date): gets a block on its **last feasible day**, the
  latest day the work still fits before the deadline given its length and
  the day window, if the user has not placed it sooner.
- A floater: no block until the planner has room for it; then a block.
  Until then it is silent, and appears only in the morning message.

Blocks are the thing the reflow already moves. Events are anchored blocks.

## The six messages

| When | Message | Decided from |
|---|---|---|
| Wake + 30, or the first app open after wake if earlier | **The day**: the plan in one line, first block named. The only unsolicited message of the day by default. | the day's blocks, ordered; days since last open (folds the come-back in: after N absent days, the line says what is waiting) |
| Five minutes before a block | **Start**: the block's name and length. | the block |
| Block end passed with no session and no completion | **Missed**: once, at end + a short grace; names the block. If a later block is coming, the missed line is folded into that block's start instead of firing alone. | sessions, completions, the block |
| The last feasible block of an owed task | **Last chance**: fires at that block's start in place of the plain start line. | deadline, length, day window |
| Bed − 60, off by default | **Close**: only if something moved to tomorrow; says what. | the reflow and rollover results |
| Sunday, bed − 120 | **Week**: done, missed, longest session, what is owed next week; opens the Tasks-tab memo. | daily stats, completion records |

Everything else the arbiter sends today folds in: idle and floater become
"the planner gives it a block" plus the morning line; due-soon becomes
last chance; prep sessions are blocks; goal lapse becomes one line in the
week message; come-back is the morning line after an absence.

## Silence is respected

- An ignored start line suppresses that block's missed line.
- Two ignored messages in a day drop the rest of that day's start lines;
  the morning line stays.
- Two such days in a week halve the week's lines by dropping starts for
  blocks under 30 minutes. A tapped line resets the count.

This is the outcome data the app already records, finally consumed.
There is no per-task fatigue counter; the unit is the day.

## Presence, not messages, during a block

A running session updates the Live Activity at its midpoint and at ten
minutes left. Nothing is sent as a notification while a session runs.
This is the body-doubling finding in its smallest form.

## Quiet hours

Only two message types can reach the window: **Start** and **Last chance**,
and only for blocks the user placed there by hand or events, which is the
rule already in force. Everything else is placed inside the day window by
construction.

## Copy

One voice, tone from `coachingStyle`. Written at delivery when the proxy
and push exist (a service extension reads the block from the App Group
and asks for one line), otherwise pre-generated the evening before for
the next day's blocks. Facts only, never shame: the block's name, its
time, its length. The morning and week lines are the only ones longer
than a sentence.

## Optional trigger, off by default

If the user opts in to Screen Time, thirty minutes in the apps they named
inserts a **Start** for the next block early, once per day, with the same
copy. No new message type; the trigger only moves an existing one
forward.

## How it is decided, end to end

1. Morning (background refresh at 6am, or first open): rollover, planner
   gives today's intents and eligible floaters their blocks, last-feasible
   blocks are computed for owed tasks, reflow settles overlaps.
2. From the settled day: one Start per block, one Last-chance where it
   applies, the Day line, and (if on) the Close line are scheduled as
   locals. That is the whole day's schedule, in one pass.
3. During the day: a session or completion marks its block done and
   cancels its missed line; a reflow (duration change, session start)
   re-schedules only the blocks it moved. Outcomes update the silence
   counters, which prune the remaining starts.
4. Sunday: the Week line from the stats.

## What it keeps from today, and what it retires

Keeps: the task model and two clocks, `DayWindow`, the planner,
`TimelineReflow`, the placement builders (they become Start and Missed),
the morning prompt (becomes Day), the outcome recording, the copy
service, the Live Activity, sessions, the eval.

Retires as separate machinery: the daily budget, spacing, the busy gate,
the per-task fatigue gate, and the idle, floater, due-soon, come-back and
goal-lapse builders.

## Apple's lines

Locals for every scheduled line (a day's blocks are a handful, well under
the 64 pending cap); push plus a service extension for at-delivery copy
when the server exists; Live Activity for presence; background refresh
for the morning pass, with the first open as the reliable fallback; the
Screen Time extension only for the optional trigger.

## What it costs to build

A rewrite of the arbiter's builder set into the six messages, reusing
the pieces named above. The eval's arbiter cases become cases about
blocks and messages; most of the current ones carry over with new
expected fields. Roughly two weeks of cycles, and it can ship in stages:
Day and Start and Missed first, which is most of the value, then
Last chance, Week, presence, Close.
