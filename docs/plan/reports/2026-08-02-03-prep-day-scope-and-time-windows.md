# Report — 2026-08-02-03 — Prep tasks place on their own day, and tasks get appropriate hours

**Plan:** `archive/2026-08-02-03-plan.md`
**Status:** complete (device evidence outstanding — see Verification)
**Commits:** `b85ac9a` (item 1), `da99126` (item 2), plus the report commit

---

## What changed

- `Nudge/Services/DayPlanEngine.swift` — (item 1) a `source == "prep"` task
  is a placement candidate only when its `dueDate` is today; the trace
  names the exclusion ("prep for another day (due X)"). (item 2) placement
  clamps the gap search to each candidate's band; no in-band gap leaves
  the task unplaced, and the trace distinguishes "gaps exist but only
  OUT-OF-BAND" from "no gap fits". Candidate lines print the band.
- `Nudge/Models/TaskTimeWindow.swift` (new) — the band enum
  (`anytime`/`daytime`/`businessHours`), tolerant `parse`, and the
  deterministic `infer(title:category:)` fallback.
- `Nudge/Models/NudgeTask.swift` — `timeWindowRaw` (additive, nil
  default), typed `timeWindow`, and `effectiveTimeWindow` (explicit ??
  inferred — the value the planner reads).
- `Nudge/Services/NudgeConfig.swift` — band boundaries: daytime 9–21,
  businessHours 9–17 weekdays. Round numbers on purpose.
- `Nudge/Services/ClaudeService.swift` — capture prompt rule + example
  JSON + `TaskData.timeWindow`. Same classification call as stakes and
  `prepLeadDays`; no second round trip.
- `Nudge/Views/Tabs/HomeTabView.swift` — maps `taskData.timeWindow` onto
  new non-event tasks.
- `Nudge.xcodeproj/project.pbxproj` — `TaskTimeWindow.swift` added to the
  widget's membershipExceptions (invariant 3; `NudgeTask` references the
  type, so the widget build needs it).
- `ARCHITECTURE.md` — engine + new model entries.

## Item 1 — answers to the plan's questions

- **The cap stays.** Day-scoping means at most one prep candidate *per
  exam* per day — but three concurrent exams still put three study blocks
  in one day's pool, and that cross-exam pile-up is exactly the
  monoculture `planMaxPrepPlacementsPerRun` was built for. It changed
  meaning (within-one-exam → across-exams) without changing value.
- **The broader leak is real but deliberate.** The planner does pull
  future-dated ordinary tasks into today — that is working ahead, the
  point of planning; urgency scoring already ranks nearer deadlines
  higher. Prep was pathological only because its dates *are* the
  spreading. No general change made or recommended.
- One spec-faithful edge worth knowing: an **overdue** prep task
  (yesterday's study day, never done) now never places — its due date is
  not today. It stays visible in Unscheduled/Overdue; whether missed study
  days should roll forward is a planner question, not a placement one.

## Item 2 — answers and design decisions

- **Away-from-home wants its own field, not `timeWindow`.** The band
  answers "when is this appropriate" — a time constraint. Errand pairing
  needs "does this happen out in the world" — a place property. The two
  correlate but don't coincide: "Call Grandma" is daytime-at-home; "buy
  groceries" is daytime-out; "study at the library" would be
  anytime-but-out. Folding location into the time band would force those
  apart or invent false pairings. Recommend a sibling field (same
  classification call, same additive pattern) when errand pairing starts.
- **Resolution is read-time, not stamped.** `inferStakes` stamps its
  fallback into the store; `effectiveTimeWindow` computes it on read
  instead. Reason: the stored value stays exclusively "what the
  classifier said," so nil still means "never classified" and any later,
  better pass (a `StakesBackfill` equivalent) can target unclassified
  rows without a flag dance. Reported as a deviation from "following
  `inferStakes`' pattern" — the *inference* follows the pattern
  (deterministic keyword scan, conservative); the *storage* deliberately
  doesn't.
- **Calendar/screenshot imports untouched** — they create events, the
  planner never places events, and every unclassified *task* (manual
  quick-adds, pre-existing rows, prep tasks) gets the read-time inference
  uniformly. Prep tasks infer `anytime` (study), which is correct.
- Conservatism, per the plan: `businessHours` requires a contact word AND
  an institution word ("call the bank", "schedule dentist appointment");
  bare "call X" is `daytime`; everything unmatched is `anytime`.

## Verification

- Both schemes build after each commit (four runs, zero warnings) — the
  widget build doubling as proof the membershipExceptions edit took.
- **Compiled-source evidence** (real `TaskTimeWindow.swift` + a verbatim
  copy of `earliestGapStart`, script in session scratchpad):
  - Inference over a ten-item mixed dump: Call Grandma → daytime; study /
    essay / reading / laundry → anytime; groceries, return package,
    vacuum → daytime; call-the-bank, schedule-dentist → businessHours.
  - Evening-only day (free 9:30 PM–11:30 PM): "Call Grandma" — OLD placed
    9:30 PM, NEW **unplaced, "gaps exist but only OUT-OF-BAND"**. "Write
    essay draft" (anytime) places 9:30 PM in both.
  - businessHours task on a weekend: bounds nil → unplaced.
- **Outstanding for the device pass:** the two-prep-tasks scenario on the
  real store, the live trace with bands and reasons, and the AI's actual
  `timeWindow` assignments on a real mixed brain dump (no API access in
  this environment — the deterministic inference table above is the
  fallback's evidence, not the classifier's).

## Deviations from the plan

- Read-time resolution instead of stamped fallback (rationale above).
- The plan's "deterministic fallback for calendar imports" reduces to
  no-op by construction (imports create events); reported rather than
  built.

## Noticed but not done

- The `noRoom` message-box copy ("your calendar is full") can now fire
  when the day has room but only out-of-band room for every remaining
  candidate. The trace tells the truth; the user-facing copy slightly
  overclaims. Worth a copy pass if it shows up in practice.
- `TaskUpdate` (the AI's task-edit DTO) carries no `timeWindow`, so a
  chat edit can't reband a task. Fine while bands are placement-only.
- No editor UI for the band — a wrong `businessHours` classification
  can't be corrected by the user yet. If added later it wants a
  user-set guard like `stakesIsUserSet`.

## Open questions

- Should a missed (overdue) prep day roll its study time forward, or is
  unplaced-and-visible the right behavior?
- When errand pairing starts: confirm the sibling-field recommendation
  (location-ish, same classification call) before any prompt work.
