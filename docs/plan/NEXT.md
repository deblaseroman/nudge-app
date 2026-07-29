# NEXT — Notification cleanup batch

**Status:** awaiting approval
**Cycle ID:** 2026-07-29-01
**Source:** `ROADMAP.md` §2 (arbiter, ready to build)

> Seeded as the protocol's first worked example. Template:
> [`_PLAN_TEMPLATE.md`](_PLAN_TEMPLATE.md).

---

## What to build

Four independent changes to what notifications *contain*. None of them change
which notifications get scheduled or when.

1. **Remove all action buttons from event reminders.** The event-block category
   keeps its tap-to-open behavior; the buttons go.
2. **Drop `markedHelpful`.** Remove the 👍 action from every category that
   carries it, and stop writing that value to `NudgeOutcome.feedback`. 👎
   (`markedUnhelpful`) stays.
3. **Remove the Break-it-down action** from wherever it's offered. The
   break-it-down *kind* and its builder stay for now — see Out of scope.
4. **Three-state morning check-in, with copy to match the states.**

**Item 4 is not fully specified and should be before this is approved.** The
three states aren't recorded in any doc reachable from here, and guessing them
would put invented product copy in front of users. Name the three states and
their copy in this section, or split item 4 into its own cycle and approve
1–3 now. Items 1–3 are independently shippable.

Smallest complete version: items 1–3, which are pure removals.

## Why

Every one of these is a channel that costs the user attention and returns
nothing.

- Event reminders are the one budget-exempt kind that fires whether or not the
  user wants a decision from them — they're an FYI before a class. Buttons
  invite an interaction the notification has no use for.
- `markedHelpful` has **no consumer**: nothing reads `NudgeOutcome.feedback`
  today. It's also the wrong half to keep — `DESIGN.md` names the explicit
  opinion channel as 👎 *and conversational questions in chat*, not a thumbs-up.
  A 👍 that changes nothing is a request for unpaid labor.
- The Break-it-down action offers a feature that is paused pending removal.
  Shipping a button for it is worse than shipping nothing.
- The morning check-in is the daily anchor and the only nudge that routes into
  Home chat. Its states should match what the user can actually answer.

Design principle served: **never shame the user**, and the app is an assistant
that proposes rather than an authority that demands a response. Fewer buttons
is fewer implied obligations.

## Constraints

- **Work-order item 4 (break-it-down paused pending removal).** Removing its
  action is a step *toward* removal, not building on it — but the kind, the
  builder, and `deadlinePrepNotificationsEnabled` all stay this cycle. Confirm
  that reading is right before approving.
- **Work-order item 3 (`fatigueGateEnabled` off).** This is what makes dropping
  `markedHelpful` safe — no gate consumes feedback, so nothing changes behavior
  when the value stops being written.
- **Stored raw values.** `NudgeOutcome` appears to persist its enums as raw
  strings (`resultRaw` is queried as a string in predicates). If `feedback` is
  stored the same way, **existing rows already hold `markedHelpful`** and
  removing the enum case must leave those rows decodable — verify before
  deleting the case, and prefer keeping the case decodable while stopping all
  writes if that's cheaper.
- **`DESIGN.md` applies to all of item 4.** New copy must not promise an
  outcome, must not imply failure for missed work, and must read as a proposal.
- **This changes the shape of outcome data mid-collection.** Section 1 of the
  roadmap is waiting on baseline rows, and removing action paths changes what
  those rows can contain. Doing it *now*, before the floater baseline
  accumulates, is cleaner than doing it halfway through — but either way the
  pre- and post-change rows are not directly comparable, and whoever reads that
  baseline needs to know the cut point. Note the date in the report.
- **`ARCHITECTURE.md`** gets updated if any file's responsibility shifts.
- Both schemes build. Notification categories are app-side, so the widget
  should be unaffected — build it anyway.

## Evidence it worked

**Work-order item 5 does not apply in its usual form, and the report should say
so rather than skipping it silently.** Item 5 covers changes that alter what
the arbiter *does* — which candidates are built, which survive the gates, when
they fire. None of that changes here: the builders, the gates, and winner
selection are untouched, so a before/after candidate dump would print two
identical columns. What changes is payload content and the delegate's action
paths.

The evidence that fits:

- **Both schemes build** — the floor, not evidence.
- **Deliver one of each kind and look at it.** Event reminder shows no buttons.
  No 👍 anywhere. No Break-it-down action. Morning check-in shows three states
  with the approved copy. This is the only real proof; there are no test
  targets.
- **Outcome rows still get written.** Tap and dismiss one notification of each
  kind and confirm `NudgeOutcome` still records `result`. The failure mode this
  catches is removing an action and breaking the delegate path that writes the
  row — which would silently stop the data collection section 1 depends on.
- **No new row carries `markedHelpful`**, and old rows holding it still load.
- **A by-kind outcome dump before and after**, to confirm the only difference
  is the removed channels and not a change in what's being scheduled.

Falsifiers, stated so the report can answer them directly: an outcome row that
still records `markedHelpful` after the change; a notification rendering a
stale action because a category identifier was updated in one place and not the
other; a kind that stops producing outcome rows entirely.

## Out of scope

Deliberately left alone, several of them things the implementer will be
tempted to fix while in the file:

- **Removing the break-it-down kind, builder, or `deadlinePrepNotifications-
  Enabled`.** Separate `ROADMAP.md` §2 item; the toggle is misnamed and gates
  break-it-down rather than deadline prep, and it should be retired *with* the
  kind, not before it.
- **`hadRecentActivity` evaluating against `now`.** Known bug, in the
  neighborhood, its own item. Leave it wrong on purpose.
- **Anything in `ROADMAP.md` §1.** No arming stakes, no fatigue gate, no
  retuning the floater anchor or `morningPromptBusyDayThreshold`.
- **The morning prompt's own gating** — day-fullness threshold, busy checks,
  budget exemption. Item 4 changes its copy and states, not when it fires.
- **Custom quiet hours swallowing the morning prompt.** Real, adjacent, and a
  separate item.
