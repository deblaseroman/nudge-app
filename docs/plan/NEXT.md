# NEXT — Two small fixes before merge

**Status:** APPROVED
**Cycle ID:** 2026-07-31-01
**Source:** cycle `2026-07-30-01`'s report, plus a console finding

> Still on `automation-run-1`. Commit, do not push, do not merge.

---

## What to build

**1 — The no-repeat rule can name a `.low` task.** From the last report:
with a high-stakes undated task and "Clean my desk" open, every third morning
reads *"Biggest thing on your list: Clean my desk."* That isn't variation,
it's the app contradicting its own ranking in its best delivery slot.

Fix: the step-aside only happens when the replacement is **within one stakes
tier** of the task stepping aside. Otherwise name the same task again — a
repeat is better than a false claim. Use the existing `morningStakesRank`
ordering so `nil` and `.low` stay one tier apart as designed.

This also settles cycle `-02`'s open question about `nil` ranking above
`.low`: keep it. Nil is absence of evidence, `.low` is a statement that the
item is minor.

**2 — `Lexend-Bold.ttf` is declared but not shipped.** The console prints
`GSFont: file doesn't exist` for it at every launch, so anything asking for
bold silently falls back to the system font. Check whether other weights in
the family have the same problem — report what you find before changing
anything, since the fix is either adding a missing font file (which I'd have
to supply) or correcting a name in `NudgeTheme`.

## Why

Item 1 is the sharpest edge the last cycle's report flagged, and it's in the
one notification the user reads first each day. Item 2 is a rendering bug
that's probably been there for months and takes one console line to spot.

## Constraints

- `ROADMAP.md` §1 stays untouched.
- Item 1 changes what the arbiter does — before/after per work-order item 5,
  showing the named task across several mornings with and without the tier
  constraint. `debugMorningPromptImpact` already prints most of this.
- Don't set `taskID` on the morning prompt — see cycle `-02`'s report.
- For item 2, don't add binary assets. Report what's needed.

## Evidence it worked

- Both schemes build.
- Simulated mornings showing a `.low` task never taking the slot from a
  high-stakes one, while same-tier rotation still happens.
- The single-open-task fallback still stands down rather than going silent.
- For item 2: what's missing, and what I need to do about it.

## Out of scope

- Everything in `ROADMAP.md` §1.
- The study-task feature — next cycle, and it's larger.
- Merging or pushing.

---

# ⚠️ EVERYTHING BELOW IS COMPLETED WORK — DO NOT WORK IT

Cycle `2026-07-30-01` and everything before it already shipped on
`automation-run-1`. Plans are in `archive/`, reports in `reports/`. Ignore.

## (completed) What to build

Two code changes, then a verification pass I run on device.

**1 — Morning prompt horizon.** Cycle 2's report flagged that stakes with no
horizon means a high-stakes task months out gets named every morning until
it's done. An unchanging daily notification is how a channel gets ignored.
Add a rule so the named task varies: either a deadline horizon on selection,
or a "don't name the same task more than N days running" constraint. You pick
which — say why, and put the constant in `NudgeConfig`. Undated high-stakes
tasks must still be nameable; they're the ones most likely to rot.

**2 — Active-session gate reads the fire date.** Cycle 3 found the identical
bug it was sent to fix, one line above: `if SessionCoordinator.shared
.isSessionActive { return false }` drops every candidate in the reevaluate,
including ones firing days out, and including event blocks — which every
other gate exempts via `countsAgainstBudget`. A focus session at 2pm kills
the 3pm class heads-up.

The product decision, so you don't have to ask: an active session should
suppress a nudge **only if that nudge would arrive during the session** —
same reasoning as the cooldown fix, and the session has a known end time.
Event blocks should be exempt entirely, matching every other gate: a factual
pre-class reminder is exactly what someone heads-down in a session needs.

**3 — Then I verify on device.** Tell me precisely what to do and what I
should see. All three prior cycles' evidence is outstanding for the same
reason — no real store on this machine — and it's one pass, not three.

## Why

Item 1 is a design flaw in the plan cycle 2 was given, caught by the report
rather than the planner. Item 2 is the last instance of a bug class already
fixed twice. Item 3 closes out three cycles of unverified work; nothing
should merge without it.

## Constraints

- `ROADMAP.md` §1 stays untouched — no arming stakes, no fatigue gate.
- Don't set `taskID` on the morning prompt. Cycle 2's report explains why:
  `.morningPrompt` passes `successIsObservableInApp`, so the named task would
  accumulate fatigue and the highest-stakes task would get pushed toward a
  break-it-down offer the day `fatigueGateEnabled` flips.
- Item 2 changes what the arbiter does, so it needs a before/after per
  work-order item 5. Item 1 does too — show which task gets named across
  several days with and without the rule.
- `DESIGN.md` applies to any copy change in item 1.

## Evidence it worked

- Both schemes build.
- Before/after dumps for items 1 and 2, run on real data during item 3.
- Item 3 produces a checklist I can work through in about ten minutes: which
  notifications to trigger, what each banner should show, what to long-press,
  and which console lines confirm it. Include the three falsifiers from cycle
  1's report — no row records `markedHelpful`, no stale actions render, no
  kind stops producing outcome rows.

## Out of scope

- Everything in `ROADMAP.md` §1.
- Removing the break-it-down kind or `deadlinePrepNotificationsEnabled`.
- `recentActivityCooldownMinutes`' misleading doc comment — it's a decision,
  not a typo.
- Merging or pushing the branch.

---

# ⚠️ EVERYTHING BELOW IS COMPLETED WORK — DO NOT WORK IT

Cycles 2026-07-29-01 through -03 already shipped on `automation-run-1`. Their
plans are in `archive/`, their reports in `reports/`. This text survives only
until the next planner turn overwrites the file. Ignore it.

## (completed) What to build

Four independent changes to what notifications *contain*. None of them change
which notifications get scheduled or when.

1. **Remove all action buttons from event reminders.** The event-block category
   keeps its tap-to-open behavior; the buttons go.
2. **Drop `markedHelpful`.** Remove the 👍 action from every category that
   carries it, and stop writing that value to `NudgeOutcome.feedback`. 👎
   (`markedUnhelpful`) stays.
3. **Remove the Break-it-down action** from wherever it's offered. The
   break-it-down *kind* and its builder stay for now — see Out of scope.
**Item 4 (three-state morning check-in) is cut.** The design decision went
another way — Cycle 2 below replaces it. This cycle is items 1–3: three pure
removals.

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
- **Stored raw values — resolved, no verification needed.** Every outcome dump
  to date ends with `feedback: none given yet`, so no row has ever held
  `markedHelpful`. The `feedback` getter also runs
  `NudgeOutcomeResult(rawValue:)` inside a `guard`, so an unknown raw string
  reads as nil rather than throwing. Delete the case outright; don't spend a
  turn checking.
- **`DESIGN.md` applies to Cycle 2's copy.** New copy must not promise an
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
  No 👍 anywhere. No Break-it-down action. This is the only real proof; there
  are no test targets.
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

---

# CYCLE 2 — Morning prompt names the day's biggest task

**Status:** APPROVED
**Cycle ID:** 2026-07-29-02

## What to build

The morning prompt asks "What do you want to get done today?" — an open
question that returns nothing the app can use. Replace it with a statement of
the day's highest-stakes open task, so the user knows what's coming before the
day starts.

- Body names the specific task.
- Selection: highest `stakes`, ties broken by deadline proximity. Reuse
  existing scoring rather than inventing a second ranking.
- **If no open task qualifies, do not fire.** A contentless morning
  notification is worse than silence.
- Tap still routes to Home chat.

## Why

`DESIGN.md`: the app proposes rather than demands. Stating a fact the user can
act on beats asking a question that costs attention and returns nothing. This
is also the best delivery slot in the app — budget-exempt, highest morning
capacity — so it should carry the day's most consequential item.

## Constraints

- No new notification kind. Copy and targeting change to
  `buildMorningPromptCandidates` only.
- **`stakes` is NOT armed in scoring** (`CLAUDE.md` work order item 1). Read
  `task.stakes` directly for selection; do not wire it into
  `EisenhowerScorer`.
- Keep existing gating: per-kind toggle, day-fullness, fire-moment busy.
- The morning prompt's `taskID` is currently nil. Setting it changes the shape
  of the classifier's `.acted` branch — check `performedAction` before
  assuming that's free, and report what you found.
- `DESIGN.md` tone: state the fact. No verdict, no promise, no implied failure.

## Evidence it worked

- Both schemes build.
- Arbiter log shows the morning prompt naming a specific task, and it's the
  highest-stakes open one.
- With no open tasks, no morning prompt candidate is built.
- Before/after showing which task gets named.

## Out of scope

- Arming stakes in scoring.
- The morning prompt's gating thresholds.
- The three-state check-in — dropped.

---

# CYCLE 3 — hadRecentActivity evaluates against the fire date

**Status:** APPROVED
**Cycle ID:** 2026-07-29-03

## What to build

`hadRecentActivity` in `passesGates` measures against `now` rather than the
candidate's fire date. A focus session started within
`recentActivityCooldownMinutes` drops every budget-counting candidate in that
reevaluate — including ones scheduled for tomorrow, which the session has no
bearing on.

Evaluate the cooldown against the candidate's fire date instead.

## Why

Listed in `CLAUDE.md` under known bugs. It produces intermittent gate blocks
unrelated to any candidate's own timing, and it muddies the floater baseline
that four `ROADMAP.md` §1 items are waiting on. Doing it early shortens that
wait.

## Constraints

- The cooldown means "don't nudge someone who just started working." Against a
  fire date days out that reasoning doesn't apply, so the gate should only
  bite for candidates firing soon. State the rule you chose and why.
- Session-start state is a single value in App Group defaults (most recent
  only), so historical accuracy isn't available. **Do not build a session log
  for this.**

## Evidence it worked

- Both schemes build.
- Before/after gate verdicts per candidate, per work-order item 5.
- Start a focus session, trigger a reevaluate, confirm candidates scheduled for
  future days are no longer blocked.

## Out of scope

- Everything in `ROADMAP.md` §1.
- Any other gate.
