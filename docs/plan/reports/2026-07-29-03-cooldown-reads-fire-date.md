# Report — 2026-07-29-03 — The activity cooldown reads the fire date

**Plan:** `archive/2026-07-29-03-plan.md`
**Status:** complete
**Commits:** third commit on `automation-run-1`

---

## What changed

- `Nudge/Services/NudgeArbiter.swift`
  - `hadRecentActivity(now:)` → **`firesInsideActivityCooldown(_ fireDate:)`**.
    Renamed rather than re-parameterised: the old name asserts a fact about
    the past ("activity happened recently"), and the question the gate is
    actually asking is about the future ("will this nudge arrive while the
    user is plausibly still working"). Keeping the old name would have left
    the next reader with the same wrong mental model that produced the bug.
  - `passesGates` calls it with `candidate.fireDate`. Position in the gate
    order is unchanged.
  - `floaterGateBlockReason` (DEBUG) updated — its message previously *told
    the reader about the bug* ("this gate reads `now`, not the fire date"),
    so leaving it would have been actively misleading.
  - `debugRecentActivityImpact` — new before/after dump, per work-order item 5.
- `CLAUDE.md` — the `hadRecentActivity` entry moves out of "Known bugs, not
  yet fixed" (struck through with what replaced it). One new known bug added,
  see Noticed but not done. Work-order item 1 gains a clarifying sentence
  about cycle 2 reading `task.stakes` directly without arming the scorer.
- `ROADMAP.md` — both shipped §2 items removed per the file's own rule ("an
  item leaves this list when it ships"): the notification cleanup batch
  (cycle 1) and this one. The break-it-down removal item gains a note that
  its action and `tappedBreakDown`'s only writer are already gone.

## The rule I chose, and why

**A candidate is blocked exactly when its fire date falls inside
`[lastSessionStart, lastSessionStart + recentActivityCooldownMinutes)`.**

The plan asked for a rule that "only bites for candidates firing soon" and
said to state it. This *is* that rule, and it needs no separate soon-ness
threshold — the window is bounded by construction, so anything scheduled past
its end passes automatically, and only candidates within the next 90 minutes
of a session start can ever be caught. Adding a second threshold on top would
have been a knob with no job.

The reasoning behind the cooldown is "don't nudge someone who just started
working". That's a property of **the moment the nudge arrives**, not of the
moment the arbiter happens to run — the arbiter's run time is an artifact of
when the user opened the app. So the fix isn't "compare against the fire date
instead", it's "the window belongs to the session, and membership is a
question about the fire date".

Half-open at the top end: a candidate firing exactly as the cooldown expires
passes. That mirrors the old form's strict `lastStart > cutoff` comparison at
the other end of the same window.

## Verification

**Both schemes build.** `** BUILD SUCCEEDED **` for both.

**Before/after gate verdicts, per work-order item 5 — actually run.** I
extracted the OLD `hadRecentActivity` from `git show HEAD:…` and the NEW
`firesInsideActivityCooldown` from the working tree, both **by line range,
verbatim**, into a scratch file with stubbed defaults storage (the real
`recentActivityCooldownMinutes = 90`), and evaluated both against the same
candidates:

```
now=14:00  lastSessionStart=13:50  cooldown=90m → window [13:50, 15:20)

  BEFORE  AFTER   candidate
  BLOCK   BLOCK   fires in 20m  (inside cooldown)
  BLOCK   BLOCK   fires at 15:19 (1m before end)
  BLOCK   pass    fires at 15:20 (exactly at end)
  BLOCK   pass    fires at 16:00 (after cooldown)
  BLOCK   pass    floater, wake+6h TOMORROW
  BLOCK   pass    get-ahead, 3 days out

now=14:00  lastSessionStart=11:00 (3h ago) → window [11:00, 12:30) closed

  BEFORE  AFTER   candidate
  pass    pass    (all six — identical verdicts)

no session ever started
  BEFORE=pass  AFTER=pass
```

The third and fifth rows of the first table are the bug and its fix: a session
started ten minutes ago used to drop a floater check-in scheduled for
*tomorrow afternoon*, which it has no bearing on.

**The change is strictly permissive**, which I want on the record because it
bounds the blast radius. For any candidate firing in the future: if the new
rule blocks, then `fireDate < lastStart + cooldown`, and since `fireDate > now`
it follows that `now < lastStart + cooldown` — which is exactly the old rule's
block condition. So *new-block ⟹ old-block*: this can free candidates, never
block ones that previously passed. Every candidate the arbiter builds fires in
the future (each builder either rolls forward or skips a past anchor), so the
implication holds everywhere it's applied. The table is consistent with it.

**The ongoing dump ships too.** `debugRecentActivityImpact` prints the same
comparison per reevaluate on real data — the per-candidate BLOCK/pass columns
plus a count of how many the fix freed — and collapses to a single line on the
common case where no session has started recently, so it doesn't bury the
other dumps.

**Not verified here:** the plan's third item, *start a focus session on device,
trigger a reevaluate, confirm future-day candidates are no longer blocked*.
Same environment limit as cycles 1 and 2 — no real store on this machine. The
truth table above covers the same logic with the real code; what the device run
adds is confirmation that `lastFocusSessionStartedAtKey` holds what we think it
holds when a real session starts. `debugRecentActivityImpact` prints
`lastSessionStart` explicitly so that's a one-glance check.

## Deviations from the plan

**One, and it's a rename the plan didn't ask for.** `hadRecentActivity` →
`firesInsideActivityCooldown`. The plan said "evaluate the cooldown against the
candidate's fire date instead", which a minimal edit could have done by
changing the argument. I renamed because the old name is the bug's origin
story: it describes a fact about the past, and a function named that way
invites exactly the `now`-shaped call site it had. Private, single production
call site, one DEBUG call site — cheap to reverse if you disagree.

Otherwise the plan is implemented as written. No session log was built (the
constraint was explicit); the gate still reasons about one window, which is all
the app group stores.

## Noticed but not done

- **The active-session gate has the identical bug, one line above the one I
  just fixed.** `if SessionCoordinator.shared.isSessionActive { return false }`
  is the first line of `passesGates` and drops **every** candidate in that
  reevaluate — tomorrow's, next week's, and event-block reminders too, which
  every *other* gate in the function deliberately exempts via
  `countsAgainstBudget`. So a user in a focus session at 14:00 loses the 15:00
  pre-class heads-up they'd otherwise get, and it comes back only because the
  next reevaluate rebuilds it. Left alone: "any other gate" was explicitly out
  of scope, and unlike the cooldown it needs a product decision (what *should*
  an active session mean for a nudge three days out — and separately, should it
  reach factual event reminders at all?). Added to `CLAUDE.md`'s known-bugs
  list so it isn't rediscovered as noise. **This is the natural next item.**
- **`recentActivityCooldownMinutes` (90) and `minNudgeSpacingMinutes` (90) are
  the same number by coincidence**, not by derivation, and nothing says so.
  Not touched.
- **The cooldown only ever knows about one session.** Documented on the
  function; the plan forbade building a log and I agree with the reasoning. The
  failure direction is permissive, which is the safe one while nothing consumes
  outcome data.
- **`NudgeConfig.recentActivityCooldownMinutes`' doc comment claims the gate
  also covers task completion** ("If the user started a session OR completed a
  task within this window"). It never did — the implementation only ever read
  the session-start key, before my change and after it. Left the comment alone:
  correcting it is either a doc fix or a missing feature depending on which half
  was intended, and that's a decision, not a typo.

## Open questions

- **Does the active-session gate get its own cycle, or fold into a broader
  "gates should reason about the fire date" pass?** Both it and the cooldown
  were the same mistake; there may not be a third instance, but a sweep would
  say so definitively rather than by inspection.
- **Was the cooldown supposed to cover task completions?** See the last item
  above. It changes what the gate does, so it needs a decision plus a
  before/after, not a comment edit.
