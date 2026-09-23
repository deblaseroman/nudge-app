# Report — 2026-08-01-03 (item 2 of 4) — Stop conflating body-taps with starting work

**Plan:** `archive/2026-08-01-03-plan.md` (§2)
**Status:** complete
**Commits:** see the item-2 commit on `automation-run-1` (this report is committed with it)

---

## What changed

- `Nudge/Models/NudgeOutcome.swift` — new `NudgeOutcomeResult.tappedOpen`
  ("came to look": body tap, or the idle "Not yet" reply). `tappedStart`'s
  doc comment now states it means the explicit Start action ONLY, and
  carries the cut date: rows before Aug 2026 (this cycle) blend the two
  meanings; rows after mean what they say. Additive — no raw value changed.
- `Nudge/Services/NudgeNotificationService.swift` — two writer branches
  changed:
  - `UNNotificationDefaultActionIdentifier` (body tap) → `.tappedOpen`.
  - `idleNotYet` → `.tappedOpen` (see decisions below).
  - `startSession` remains the only writer of `.tappedStart`.

## Decisions reviewed, per the plan's ask

- **Default-action path** → `.tappedOpen`. The mandated change.
- **`idleNotYet`** → `.tappedOpen`, not left at `.tappedStart`. It is an
  explicit button, but by the user's own statement nothing has started —
  it opens a proposal sheet. "Reserve `.tappedStart` for the explicit Start
  action" reads as excluding it. If the user starts a session from the
  sheet, that lands after the row is resolved and is not re-attributed;
  under-crediting is the safe direction while outcomes are
  observation-only. (A dedicated `.tappedNotYet` value was considered and
  skipped — third value, no consumer that would distinguish it yet; a
  later cycle can add it additively if the idle data needs the split.)
- **`idleYesGood`** — still records `.tappedSnooze` ("best existing
  match" per its comment). Also semantically wrong, but out of this item's
  scope; listed under Noticed.
- **Classifier `.acted` inference** — reviewed, no change needed: the
  sweep's predicate is `resultRaw == "pending"`, and every tap resolves
  the row synchronously, so no `tapped*` value ever reaches the classifier.
  Its `.acted` comes from `performedAction` (session start / completion in
  the response window), which is orthogonal to this split.
- **Consumers matching `tappedStart`** — searched the repo: the only
  result-matching consumer anywhere is the fatigue gate's
  `taskFatigueCount`, whose predicate matches `"ignored"`/`"dismissed"`
  only. The DEBUG outcome dump prints raw values and tallies by grouping,
  so `tappedOpen` appears automatically. No consumer migrates.

## Verification

- Both schemes build (`xcodebuild`, iOS Simulator): **Nudge** ✅,
  **NudgeWidgetExtension** ✅.
- Work-order item 5 (DEBUG before/after): inert by construction for the
  arbiter — this item changes what the delegate *writes*, not what the
  arbiter *reads* (`fatigueGateEnabled` is false, and the gate's predicate
  doesn't match tap values anyway). No notification decision changes.
  The next device outcome dump will show `tappedOpen` rows as body taps
  occur.

## Deviations from the plan

- None beyond the `idleNotYet` interpretation recorded above.

## Noticed but not done

- `idleYesGood` records `.tappedSnooze`, which misfiles "I'm already
  working" as "asked to be reminded later." A truthful value (e.g.
  `.tappedAlreadyDone` or similar) would be additive; left for the planner
  since it changes the meaning of `.tappedSnooze` baselines for `.idle`.
- Snoozed re-fires (`<originalID>.snoozed`) create no outcome row at all —
  a snoozed nudge's second delivery is invisible to the data. Pre-existing;
  out of scope.

## Open questions

- None.
