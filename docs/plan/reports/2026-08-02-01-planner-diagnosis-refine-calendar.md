# Report — 2026-08-02-01 — Plan my day diagnosis, Refine removal, daily calendar extension

**Plan:** `archive/2026-08-02-01-plan.md`
**Status:** complete (item 1's on-device trace run outstanding — see Verification)
**Commits:** `1e42e29` (item 1), `b91452d` (item 2), `1aa47aa` (item 3), plus the report commit

---

## What changed

- `Nudge/Views/Tabs/TasksTabView.swift` — (item 1) DEBUG-only trace through
  `planMyDay()`: the day window and the previously **silent** empty-window
  return, merged busy intervals + free gaps, the candidate pool with a
  per-task include/exclude reason, every placement attempt, and the final
  count + which haptic fired. No logic changed. (item 2) Refine button,
  `refineWithAI()`, and `isRefining` removed.
- `Nudge/Views/Tabs/SettingsTabView.swift` — (item 2) DEBUG entitlement
  toggle copy no longer names the removed Tasks-tab button.
- `Nudge/Services/CalendarService.swift` — (item 3) `refreshRollingWindow`
  guard `>= 7` → `>= 1`: the window extends one day per day, horizon pinned.
- `ROADMAP.md` — §3 Refine-retirement marked done; §4 vanishing-task bullet
  corrected (see Deviations — last cycle's report was wrong about it).
- `ARCHITECTURE.md` — TasksTabView, CalendarService, CompletedTaskRecord
  entries updated to match.

## Item 1 — diagnosis (investigation only; nothing fixed)

**Ranked causes for "the button does not work," most likely first:**

1. **The silent empty-window return — high confidence.** `planMyDay()`
   hand-computes wake+30 → bed−60 on *today's* date and bails with
   `guard dayEnd > scanStart else { return }` — **no haptic, no message,
   no state change**. Two triggers:
   - **Bedtime set to midnight or later → the button never works, at any
     hour, permanently.** Bed 00:30 puts `bedToday` at *this morning*
     00:30, so `dayEnd` (−60m) is always in the past. This exact collapse
     is documented in `BusyWindowResolver.dayLoad` ("a past-midnight
     bedtime collapses it — callers should fail OPEN on nil") — but
     `planMyDay()` doesn't use `dayLoad`; it re-derives the window inline
     and fails **closed, silently**. A student profile with a
     past-midnight bedtime is not an edge case for this audience.
   - **Any tap after bed−60** (with default 23:00 bedtime: after 22:00)
     silently does nothing until morning. Developers test in the evening.
2. **Re-tap after a successful plan — medium-high.** Candidates require
   `plannedStartDate == nil`, so once a run places tasks, a second tap
   finds only leftovers that didn't fit and lands in `placed 0 → error
   haptic`. If the observed behavior is "it worked once, never again,"
   it's this. "Replan" is not a thing the button can currently do.
3. **Legitimate zero placements read as a dead button — medium.** Error
   haptic only, no visible feedback, for: zero open unplaced tasks (the
   plan's own hypothesis — a correct refusal that looks broken); or no
   fitting gaps. The gaps case got materially more likely recently: real
   event durations (a 3-hour lab is 3 busy hours now) **plus** the 1-hour
   pre-event buffer per event can zero out a class-heavy day genuinely.
4. **Ruled out, with reasons:**
   - *The 2026-08-01-05 plan/placed split* — presentation only; placement
     writes `plannedStartDate` and rows surface in the Today tab +
     timeline. No path from tab membership back into the planner.
   - *`PlacementRollover`* — clears only placements dated **before
     today** (`< startOfToday`), on launch/foreground, before the arbiter.
     It cannot un-place a fresh result; it only *frees* candidates.
   - *Prep tasks in the pool* — they do enter (non-event, dated, exam
     category, ~90-minute prior) and can outrank everything, so up to all
     4 slots can go to study tasks — a **wrong-results** shape worth
     watching, but not "nothing happens."
   - *`sequenceIndex` plan-first* — behaves as designed: plan tasks place
     first in the user's stated order, then scored tasks.
   - *Something older* — the window math and candidate filter predate all
     of the above suspects; hypothesis 1 is itself the "older" bug.

**The trace decides it.** Every path above prints a distinct line —
`❌ EMPTY WINDOW`, `excluded: … already placed`, `no gap fits`,
`placed 0 → error haptic` — so one tap on the device with the console
open identifies the failure mode unambiguously.

## Item 2 — everything that referenced Refine

- `TasksTabView` — button, `refineWithAI()`, `isRefining`: **removed**.
  `refineRationale` + the `todaysRationale()` pickup on appear + the
  message box's rationale parameter: **kept** — the rationale surface is
  *not* orphaned, because Home chat still produces rationales.
- `HomeTabView` — `isPlanIntent`/`handlePlanIntent` call
  `DayPlanRefiner.shared.refine(force: true)` behind the Pro gate: kept,
  now the capability's only entry point. Its copy referring users to
  "Plan my day in the Tasks tab" stays valid — that's the deterministic
  button, which remains.
- `SettingsTabView` — DEBUG entitlement toggles gate the same capability;
  copy updated, toggles kept.
- `DayPlanRefiner`, `BusyWindowResolver`/`NudgeTask` comments — untouched,
  per the plan (capability stays).

## Item 3 — answer to the plan's question

**The extension is genuinely incremental.** `start = max(now,
syncedThrough)` imports only the missing tail slice past the cursor, and
`importAppleCalendar` dedupes by title+dueDate on top. So this was the
constant change (`>= 7` → `>= 1`), not a rewrite.

## Verification

- Both schemes build after each of the three commits (BUILD SUCCEEDED,
  zero warnings, all six runs).
- Item 3 before/after: simulated 30 daily launches of the exact cursor
  arithmetic (script in session scratchpad, output in full below the
  fold of this cycle's console log). **Old rule: horizon at launch
  oscillates 20→14 days, min 14 — exactly the prep sweep's maximum lead
  band. New rule: 20 at launch, 21 after refresh, every day; a 1-day
  slice per day.** Import-not-arbiter, per the constraint — no candidate
  lists involved.
- Item 1: the trace **has not run against a real store** — no device
  store exists in this environment (same limitation as every real-data
  check on this branch). The ranked list above is from the code trace;
  the console run is the remaining evidence and takes one button tap.
- Item 2: verified by grep that no `refineWithAI`/`isRefining` references
  remain and that the rationale path still has a producer (Home chat).

## Deviations from the plan

- **Correcting my own prior report:** cycle 2026-08-01-05's report and
  ROADMAP edit claimed the placement rollover sweep "still needs to
  exist." Wrong — `PlacementRollover` shipped in batch 2026-07-30-02 and
  runs from `ContentView` on launch and foreground. This cycle's plan
  listing it as a live suspect is what exposed the error; ROADMAP §4 now
  reflects reality (the bullet is done, twice over). The practical
  consequence of my error was nil — the tab-side inclusion of stale
  placements is belt-and-suspenders — but the audit trail deserved the
  correction.
- Item 2 scope grew by two doc touches (Settings DEBUG copy, ROADMAP §3
  strike-through) — both are references to the removed button, which the
  plan asked to be accounted for.
- Otherwise none: item 1 changed only DEBUG output; item 3 was the
  constant change its own question anticipated.

## Noticed but not done

- **`planMyDay()` should probably use the shared window derivation** (or
  at least fail open/loud like `dayLoad`'s contract says) instead of its
  inline wake/bed math — that's the fix the diagnosis points at, held for
  the next cycle per "investigation only."
- The Home-chat `notEntitled` reply and the Settings trial toggle still
  say "AI"-flavored copy that may want a DESIGN.md pass when
  entitlements become real. Left alone.
- The horizon simulation script lives in the session scratchpad, not the
  repo — deliberately: `docs/plan/` is coordination, not code, and the
  repo has no test target to house it.

## Open questions

- Which fix for a confirmed empty-window failure: fail open (plan into a
  clamped window), or fail loud (message-box line saying why nothing was
  placed)? DESIGN.md's assistant-not-authority rule leans loud-but-calm.
- Should a second tap replan (clear auto placements and re-place) rather
  than error? Related to the existing "Clear plan" button — they could
  merge.
- Prep tasks consuming all four Plan-my-day slots: acceptable near an
  exam, or should the planner cap per-source placements?
