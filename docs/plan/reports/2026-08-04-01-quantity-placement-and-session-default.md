# Report — 2026-08-04-01 — Quantity-task placement diagnosis + Start Session default

**Plan:** `archive/2026-08-04-01-plan.md`
**Status:** complete (on-device confirmation of the item-1 diagnosis outstanding — see Verification)
**Commits:** `8e879f3` (item 1), `00b19d8` (item 2), plus the report commit

---

## What changed

- `Nudge/Services/DayPlanEngine.swift` — (item 1) new `BandRefusal` struct;
  both silent band-refusal sites (band closed for the day; gaps exist but
  only out-of-band) now record `(title, band)` instead of only printing in
  DEBUG. `.placed` and `.noRoom` carry the list; the auto-run writes it
  into `PlanOutcomeContext`. **Placement decisions are unchanged.**
- `Nudge/Views/Components/TasksMessageBox.swift` — (item 1)
  `PlanOutcomeContext` gains `outOfBandTitles`/`outOfBandBands` (parallel
  string arrays, App Group keys). The composer names the refused task, the
  rule (hours pulled from `NudgeConfig`, so copy can't drift), and the
  escape hatch (manual placement has no band gate). Three render paths:
  appended to the auto-run announcement; a dedicated message on a manual
  run that placed things but refused one (previously fully silent); and a
  corrected `noRoom` message — "your calendar is full" was wrong when the
  free time simply sits outside the task's hours.
- `Nudge/Views/Tabs/TasksTabView.swift` — (item 1) `planMyDay()` writes the
  refusal context instead of clearing on a manual success that refused
  something; `recordPlanOutcome` passes refusals through. (item 2)
  `suggestedSessionTask` rule + `SessionTaskPickerSheet` rework: opens on
  one suggested task (primary-tinted card, tap to start, a context line
  saying why it's the one) with a **Change** button revealing the rest;
  full list when Today is empty. The idle sheet's "pick something else"
  path deliberately skips the suggestion (new `sessionPickerShowsFullList`
  flag) — the user just declined a single proposed task.

## Item 1 — diagnosis (the plan's two candidates)

**Candidate (a) — "the placement path doesn't handle quantity tasks" — is
false.** Traced end to end:

- A `targetCount == 3` task is a commitment daily (`source == "commitment"`;
  the sweep is the only writer of `targetCount`). It passes the planner's
  candidate filter on its own day (due 23:59 of that day → `isDateInToday`
  true), is never excluded for being a count task, and the manual placement
  sheet lists it with no gates at all — `placeTask` writes
  `plannedStartDate` unconditionally.
- It has a duration: `estimatedMinutes` is nil for quantity dailies (the
  sweep sets `dailyMinutes` only for rate shapes), so `planningMinutes`
  falls back to the category prior (`work` → 60 m) or 30 m.

**Candidate (b) — the time window — is the failure, and it was silent in
exactly the way the plan suspected.** Two silent shapes, both previously
DEBUG-print-only:

1. `bandBounds` returns nil — the band's hours are over for today, or it's
   a weekend for `businessHours`. "Apply to three jobs" plausibly carries
   an AI-assigned `businessHours` window (inherited from the commitment
   parent's capture classification; the deterministic fallback would say
   `anytime`), and the band closes at 17:00 — any evening test refuses it.
2. Gaps exist but only out-of-band — free space is visible on the timeline
   right there, and the planner correctly won't use it, which reads as a
   bug until the rule is named.

Whenever anything else placed, the run reported success and the refusal
vanished; even a zero-placement run said "no room," not "wrong hours."
Fix per the plan: tell the user why, don't loosen the rule. Both shapes
now surface through the message box with the task name and the hours.

A third silent path noted but left alone: a commitment whose start day
resolved to *tomorrow* has no daily due today, so Plan-my-day excludes it
as "generated for another day." That's the sweep's date arithmetic doing
its job, and the commitment announcement already says "for tomorrow …".

**The duration question:** a quantity daily currently plans as its
category prior (60 m for `work`-category, else 30 m), and a *manually*
placed one draws on the timeline at 30 m (`plannedDurationMinutes` is only
stamped by the engine). So "three applications" gets the same block as
one. Not sensible long-term — the honest model is per-unit minutes ×
`effectiveTargetCount` — but that needs a per-unit estimate the capture
flow doesn't collect yet, so it's reported here rather than invented.
Also noted: the engine and the timeline disagree about a manually placed
task's width (prior vs 30 m) — cosmetic, listed under Noticed.

## Item 2 — the "next" rule, as stated

Suggested task = the earliest placement on **today's timeline** whose slot
hasn't fully passed (start + duration > now — a block in progress *is*
"now"), else the first open task in **Today's ordered plan**, else no
suggestion → the sheet opens on the full list, exactly the old behaviour.
Slot end uses the same duration resolution the timeline draws with, so the
suggestion can't disagree with the strip.

## Verification

- Both schemes build after each commit (`xcodebuild … Nudge` and
  `… NudgeWidgetExtension`, generic iOS Simulator destination): four runs,
  all `BUILD SUCCEEDED`, zero warnings in the filtered output.
- **Work-order item 5 (before/after on real data): skipped as inert by
  construction, deliberately.** Item 1 adds bookkeeping on the two refusal
  paths and threads it outward; every guard, continue, and placement write
  is untouched, so no run can place a different set of tasks than before.
  (One previously-DEBUG-only `earliestGapStart` probe now also runs in
  release on the no-gap path — compute, not behaviour.) Item 2 touches no
  arbiter or planner path at all.
- **Not verified here:** which of the two band-refusal shapes actually hit
  the device task — that needs one Plan-my-day tap on the device. The
  DEBUG trace now also prints `band-refused N` in the result line, and the
  message box itself now reports the answer in release.
- Empty-Today fallback and the Change reveal are code-path-verified
  (suggestion nil ⇒ the old list body renders); not exercised in a
  simulator run this cycle.

## Deviations from the plan

- The plan's diagnosis framing assumed one cause; the answer is "(a) false,
  (b) confirmed as the only refusing gate, with two distinct silent
  shapes" — both now surfaced, since either could have been the device
  case and they're the same fix.
- Item 2's "Change" button: after tapping Change the suggestion card stays
  on top with the list beneath it, rather than being replaced — the
  proposed default remains one tap away while browsing. The plan didn't
  specify either way.
- The idle "pick something else" path skips the suggestion. The plan
  didn't mention it, but opening on a single suggestion right after the
  user declined a single proposal (possibly the same task) would
  contradict the tap that got them there.

## Noticed but not done

- **Quantity dailies have no count-aware duration** (see above) — needs a
  per-unit estimate; planner decision, roadmap-adjacent.
- **Manual placements draw at 30 m but plan as the prior** —
  `placeTask` doesn't stamp `plannedDurationMinutes`; the engine's busy
  math then uses `planningMinutes` while the timeline draws
  `estimatedMinutes ?? 30`. Same task, two widths. Small, cosmetic-ish,
  but it also shifts what the next plan run thinks is free. Left alone:
  out of this cycle's scope.
- `SessionTaskPickerSheet.durationLabel` says "60 min session" for any
  task with nil `estimatedMinutes` (picker default 60 vs planner default
  30 vs timeline default 30). Left alone, same reason.
- The auto-run still writes nothing on a zero-placement morning (including
  band refusals) — deliberate per its "narrating 'I did nothing' every
  quiet morning is noise" rule; a manual tap the same day does surface
  them.

## Open questions

- Should quantity capture ask (or the AI estimate) minutes-per-unit, so a
  count task's block scales with its target? That's the real fix behind
  the duration question.
- Is `businessHours` the right band for job applications at all? Applying
  online has no "staff on the other end." If the AI classification proves
  over-eager on device, the capture prompt's band examples are the lever —
  the placement rule itself behaved correctly.
