# Report — 2026-07-30-01 — Morning-prompt repetition, active-session gate, device pass

**Plan:** `archive/2026-07-30-01-plan.md`
**Status:** complete (items 1 and 2 shipped; item 3 delivered as a checklist to run)
**Commits:** fourth commit on `automation-run-1`

---

## What changed

**Item 1 — morning prompt repetition**

- `Nudge/Services/NudgeConfig.swift` — `morningPromptMaxConsecutiveDays = 2`.
- `Nudge/Services/NudgeArbiter.swift`
  - `morningPromptHistory` — App Group dictionary, fire-day stamp → named task
    UUID. Pruned to 7 days in `cancelAll` next to `eventReminderHistory`.
  - `wasNamedOnRecentMornings(_:before:)` — the rule.
  - `morningPromptRanking` gains the exclusion, its fallback, and an
    `includeRepeatNamed:` parameter so the DEBUG dump can print the
    unfiltered ranking beside the real one.
  - `NudgeCandidate.namedTaskID` — new. The morning prompt's `taskID` is nil by
    design (fatigue coupling, per the last cycle and this plan's constraint), so
    `schedule()` had nothing to record. This field carries the attribution
    `taskID` must not; nothing else reads it.
  - `schedule()` writes the history entry for `.morningPrompt`.
  - `debugMorningPromptImpact` prints whether the rule bit, and the last 7 days
    of named tasks.

**Item 2 — active-session gate**

- `Nudge/Services/NudgeArbiter.swift`
  - `firesDuringActiveSession(_:)` replaces the unconditional
    `if SessionCoordinator.shared.isSessionActive { return false }`. Called with
    `candidate.countsAgainstBudget &&` in front, so budget-exempt kinds skip it
    entirely.
  - `floaterGateBlockReason` updated to match.
  - `debugActiveSessionImpact` — new before/after dump.
- `Nudge/Services/SessionCoordinator.swift` — `sessionEnd` is now computed
  **before** `startSession` triggers its reevaluate. See Deviations; this one
  isn't cosmetic.

**Item 3** — `docs/plan/DEVICE-CHECK-automation-run-1.md`.

**Docs** — `CLAUDE.md` (active-session bug removed from known-bugs; the
cooldown entry now records that no gate in `passesGates` reads `now` any more),
`ARCHITECTURE.md` (morning-prompt paragraph, and the fire-date invariant on the
gates).

## Verification

**Both schemes build.** `** BUILD SUCCEEDED **` for `Nudge` and
`NudgeWidgetExtension`.

### Item 1 — which task gets named across several days, with and without

Extracted `wasNamedOnRecentMornings`, `morningStakesRank` and `stamp`
**verbatim by line range** from `NudgeArbiter.swift`; the eligibility/fallback
wrapper and the day loop are re-created in the harness because the real one
does a SwiftData fetch. So the *rule* below is the shipped code; the scaffolding
around it is not.

Three open tasks — `Study for the MCAT` (high, **undated**), `Passport renewal`
(high, dated, further out), `Stats problem set` (medium, due soon):

```
[WITHOUT — cycle 2 behaviour]        [WITH the no-repeat rule]
  Aug 3: Passport renewal              Aug 3: Passport renewal
  Aug 4: Passport renewal              Aug 4: Passport renewal
  Aug 5: Passport renewal              Aug 5: Study for the MCAT
  Aug 6: Passport renewal              Aug 6: Passport renewal
  Aug 7: Passport renewal              Aug 7: Passport renewal
  Aug 8: Passport renewal              Aug 8: Study for the MCAT
```

The left column is the flaw cycle 2's report flagged: six identical mornings.
The right column cycles 2-on / 1-off.

The fallback, with a single open task — the case where the rule must stand
down rather than silence the day's anchor:

```
ONE open task            HIGH-stakes undated + a .low task
  Aug 3..8: Study for the MCAT    Aug 3: Study for the MCAT
                                  Aug 4: Study for the MCAT
                                  Aug 5: Clean my desk
                                  Aug 6: Study for the MCAT
```

- **Undated high-stakes tasks stay nameable**, as the plan required — columns 2
  and 4 both name `Study for the MCAT`, which has no deadline at all. This is
  the specific thing a horizon rule could not have delivered.
- The rule never produces silence.

### Item 2 — before/after gate verdicts

`firesDuringActiveSession` extracted verbatim; BEFORE is the old rule (`if
isSessionActive { return false }`, applied to every candidate regardless of
kind). A 60-minute session running until 15:00:

```
  BEFORE  AFTER   candidate
  BLOCK   pass    eventBlock  15:00 class heads-up   (fires 14:00)
  BLOCK   pass    eventBlock  tomorrow 09:00
  BLOCK   pass    morningPrompt tomorrow 08:30
  BLOCK   BLOCK   getAhead    14:30 (in session)
  BLOCK   pass    getAhead    15:00 (at the end)
  BLOCK   pass    floater     16:00 (after)
  BLOCK   pass    floater     TOMORROW 14:00
  BLOCK   pass    getAhead    3 days out
```

Row 1 is the plan's motivating case and it now passes. Row 4 is the one that
should still block, and does. Same strictly-permissive property as the cooldown
fix: nothing that used to pass now blocks.

### Item 3

`DEVICE-CHECK-automation-run-1.md` — six sections, ~10 minutes, ordered so §0
captures the BEFORE outcome dump before the app writes anything (that snapshot
is unrecoverable once you launch). It covers all four cycles, includes the
long-press instruction (action buttons are invisible on an unexpanded banner,
which would otherwise make §2 prove nothing), and carries all three of cycle
1's falsifiers plus one per new item. Expected console output is quoted inline
so each check is a comparison rather than a judgement call.

**Everything in items 1 and 2 above was verified against extracted code, not on
device.** The device pass is item 3's job and it hasn't been run.

## Deviations from the plan

1. **One change outside the two items: `SessionCoordinator.startSession` now
   sets `sessionEnd` before it triggers its reevaluate.** Not cosmetic — item 2
   is broken without it. `startSession` calls `cancelSession()` first, which
   resets `sessionEnd` to `.distantPast`, and the `.sessionStarted` reevaluate
   fired *before* the new `sessionEnd` was computed. So the new gate would have
   read `isSessionActive == true` alongside an end instant in the distant past
   and suppressed **nothing**, on the one reevaluate whose entire purpose is
   clearing nudges out of the session you just started. Moving three lines up
   fixes it; nothing in between touches `sessionEnd`. The old unconditional gate
   never noticed because it didn't read the value.
2. **The `countsAgainstBudget` exemption also exempts the morning prompt**, not
   just event blocks. The plan named event blocks and described the mechanism as
   "every other gate exempts via `countsAgainstBudget`" — I used that flag rather
   than special-casing `.eventBlock`, since a kind-keyed gate would be the only
   one in the function. The morning prompt is budget-exempt for the same
   "anchor, not a nudge" reason, and it fires at wake+30 where an active session
   is unlikely. Flagging it because it's a real widening of what the plan asked
   for; special-casing the kind is a one-line change if you'd rather.
3. **I chose the no-repeat rule over a deadline horizon, as invited.** The
   reasoning is in `wasNamedOnRecentMornings`' doc comment and worth restating:
   a horizon can't reach undated tasks, which the plan explicitly required stay
   nameable — so the exact case that motivated the rule is the one a horizon
   would have missed. A horizon also doesn't make anything *vary*: a task due in
   four days still wins four mornings running.

Design detail the plan left open, decided rather than asked: the rule is "named
on **every** one of the last N mornings", not "any of". A missing day counts as
a break, because a day with no prompt (busy day, phone off) isn't evidence the
user saw the task.

**No copy changed**, so `DESIGN.md`'s copy constraint didn't bind this cycle —
the same sentence renders with a different task in it.

## Noticed but not done

- **The rule can hand the morning slot to a `.low` task.** Visible in the fourth
  column above: with only a high-stakes undated task and `Clean my desk` open,
  every third morning names the desk. Arguably the step-aside should be limited
  to same-tier replacements, or `.low` should be excluded from being named at
  all. Left as-is because the plan asked for variation and this *is* the user's
  list; but it's the sharpest edge of the rule and worth a decision.
- **The third-ranked task never gets named.** When the top task steps aside, the
  next *highest-stakes* one takes the slot — so with three tasks the rotation is
  between two of them, not all three. Correct per the ranking, but "the named
  task varies" is satisfied more narrowly than it might sound.
- **`morningPromptHistory` records what was scheduled, not what was delivered.**
  If the prompt is scheduled and then cancelled before firing (a mid-evening
  reevaluate that finds the day newly busy), the history still counts it as
  named. Rare, self-correcting within a day, and the alternative is
  write-back from the delegate, which is a much bigger change.
- **`recentActivityCooldownMinutes`' doc comment still claims the gate covers
  task completions.** Explicitly out of scope this cycle. Still true, still
  wrong.
- **`NudgeCandidate` now has one `var` among fourteen `let`s.** Purely so the
  synthesised memberwise init keeps working at the five call sites that don't
  set `namedTaskID`. Noted in the field's comment.

## Open questions

- **Should `.low` be nameable at all?** See the first item above. It interacts
  with cycle `-02`'s open question about `nil` ranking above `.low`, and the two
  should probably be decided together.
- **Does the morning prompt want the active-session exemption?** Deviation 2. My
  read is yes-by-consistency, but it's your call.
- **After the device pass, does this branch merge as one unit or land in
  pieces?** Four cycles are stacked on it now, and the only thing standing
  between it and a merge is `DEVICE-CHECK-automation-run-1.md` coming back
  clean.
