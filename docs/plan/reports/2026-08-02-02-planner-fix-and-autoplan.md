# Report — 2026-08-02-02 — Fix Plan my day, and plan automatically each morning

**Plan:** `archive/2026-08-02-02-plan.md`
**Status:** complete (device evidence outstanding — see Verification)
**Commits:** `7dfb35d` (item 1), `eac9318` (item 2), `5cdf8b3` (item 3), plus the report commit

---

## What changed

- `Nudge/Services/DayWindow.swift` (new) — the one derivation of a day's
  planning window, wake-anchored: a bedtime at or before wake on the clock
  belongs to the next calendar date, so bed 00:30 / wake 08:00 runs
  08:30→23:30 *today*. Written as the plan asked: a property of what "day"
  means, not a midnight special case.
- `Nudge/Services/DayPlanRefiner.swift`, `Nudge/Services/BusyWindowResolver.swift`,
  the planner (`planMyDay`, now `DayPlanEngine`) — all three inline window
  copies replaced with `DayWindow.resolve`.
- `Nudge/Views/Components/TasksMessageBox.swift` — `PlanOutcomeContext`
  (App Group, today-scoped) + a new composer state for planner outcomes.
- `Nudge/Services/NudgeConfig.swift` — `planMaxPlacementsPerRun = 4`
  (hoisted from the inline literal) and `planMaxPrepPlacementsPerRun = 2`.
- `Nudge/Services/DayPlanEngine.swift` (new) — the planner, extracted from
  `TasksTabView` so the morning auto-run can plan without the view;
  `planToday(clearAutoFirst:)` + `autoPlanIfNewDay`.
- `Nudge/Views/Tabs/TasksTabView.swift` — `planMyDay()` is now a thin
  delegate (replan semantics); `recordPlanOutcome` wires refusals to the
  message box; ~280 lines of planner code moved out.
- `Nudge/ContentView.swift` — auto-plan runs in the scene-active Task,
  after the awaited calendar refresh.
- `ARCHITECTURE.md` — new/updated entries throughout.

## Item 1 — every place that derives a day window

The census the plan demanded, with dispositions:

| Site | Had the bug? | Now |
|---|---|---|
| `planMyDay` (TasksTabView) | yes — the confirmed device failure | shares `DayWindow.resolve` |
| `DayPlanRefiner.refine` | yes — identical copy; collapse mislabeled `.noTasks` | shares `DayWindow.resolve` |
| `BusyWindowResolver.dayLoad` | yes — collapse returned nil, so its callers failed open | shares `DayWindow.resolve` |
| Quiet hours (`passesQuietHours` + `UserProfile` fields) | no — rewritten Jul 2026 as a wrapping clock-minutes interval precisely because of this class of bug | left alone deliberately: it is an interruption window that *wraps* midnight, not a same-day span; consolidating it into `DayWindow` would re-conflate what Jul 2026 unconflated |
| Arbiter wake-anchored fire times (morning prompt, idle, floater, prep) | n/a — wake-only offsets, no bedtime pairing, no window | left alone |

**A consequence to flag under work-order item 5:** `dayLoad` feeds the
morning prompt's day-fullness gate. For past-midnight profiles it used to
return nil and the gate silently failed open (never skipped the prompt);
those profiles now get a real window, so the gate can evaluate for the
first time. Structurally this only enables a documented gate on profiles
where it was inert, and normal profiles are bit-identical — but it is an
arbiter behavior change on exactly the device profile, and the next device
console will show it.

## Item 2 — outcomes and the cap

- New composer state sits below the two prep states, above the rationale
  and resting — within the plan's "above resting, below overdue" bound.
- `noRoom` uses the plan's copy verbatim. `windowCollapsed` states the
  window rule and points at Settings. `noCandidates` headline is **not**
  the plan's example ("your list is clear") — see Deviations.
- A successful manual plan writes no message (the placements are the
  feedback) and clears any earlier refusal, per "clears on the next
  successful plan."
- **Prep cap: 2 of 4.** Near an exam, study still claims half the proposed
  day (two ~90-minute blocks is real study time); two slots always remain
  for the rest of life. The inline `4` was hoisted to `NudgeConfig` at the
  same time — the cap needed a named sibling. Placement only;
  `ExamPrepSweep` untouched.

## Item 3 — the morning auto-run

- `autoPlanIfNewDay`: once per calendar day via an App Group marker
  (stamped even when the pass refuses — one *attempt* per day, not one
  success, so a no-room morning doesn't retry all day). Skips without
  planning if today already has auto placements. Never touches manual
  placements — `clearAutoFirst: false`, and the engine plans around them.
- **Ordering, confirmed in `ContentView`:** the scene-active branch runs
  purge → `PlacementRollover` → `ExamPrepSweep` synchronously, then the
  arbiter, then a `@MainActor` Task that awaits the calendar refresh and
  only then auto-plans. A placement triggers a second, data-driven arbiter
  reevaluate. Cold launch is covered because scenePhase transitions to
  `.active` on launch — the same reliance the calendar refresh has always
  had.
- **Announcement:** placements write `PlanOutcomeContext(.planned,
  isAuto: true)`; the message box announces the count and titles and notes
  that the user's own placements were untouched.
- **The button is now a replan:** it releases today's auto placements and
  re-places (release happens *after* the window guards, so a late-night
  tap can't strip the day's plan and then place nothing). **Clear plan was
  NOT merged** — the button is the re-roll, Clear plan is the undo; merging
  them would leave no way to remove an unwanted auto plan without creating
  a new one.
- The marker is a start-of-day `Date` (the calendar refresh's
  `syncedThrough` shape). The plan said "same shape as the rollover's,"
  but the rollover has no marker — it's idempotent by construction; the
  refresh cursor was the nearest real precedent.

## Verification

- Both schemes build after each of the three commits (six runs, zero
  warnings).
- **Item 1 before/after — the real `DayWindow.swift` compiled against a
  stub config and run over five profiles** (script in session scratchpad):
  - device profile (wake 8:00, bed 00:30): OLD window ended Aug 1 11:30 PM
    → silent fail at a 4:06 PM tap; NEW ends **Aug 2 11:30 PM → plans**.
  - default (bed 23:00): OLD and NEW identical to the minute.
  - bed 00:00 exactly: OLD silent fail → NEW plans (ends 11:00 PM today).
  - wake 10:30 / bed 02:00: NEW ends 1:00 AM *next day*, correctly rolled.
  - degenerate (bed 45 min after wake): OLD silent fail → NEW nil, loud at
    every caller.
- **Outstanding for the device pass:** the headline itself (bedtime 00:30,
  tap, tasks place), the dated trace lines, each refusal's message-box
  line, the prep cap against the real five-prep-task day, and one real
  morning auto-run. No device store exists in this environment; the
  compiled-source test is the strongest evidence available here and the
  planner should treat the headline as unverified until the device run.

## Deviations from the plan

- **`noCandidates` headline diverges from the plan's example copy.** "Your
  list is clear" is false when tasks exist but all are already placed —
  the same refusal fires for both sub-cases. It now reads "Nothing to plan
  right now." with the detail carrying both facts ("finished or already on
  today's timeline"). DESIGN.md's state-the-fact rule outranked the
  example copy.
- **Auto-run refusals are silent.** The plan says "announce it: what got
  planned" — read as: announce *placements*. A quiet morning with nothing
  to place produces no unprompted "I did nothing" message; the refusal
  messages exist for the button, where the user acted and deserves an
  answer. If the planner wants morning refusals surfaced too, it's a
  one-line change in `autoPlanIfNewDay`.
- **One `windowCollapsed` kind covers two sub-cases** (unresolvable
  profile, day already over) with one message stating the window rule plus
  a Settings pointer. Splitting them bought no user-meaningful distinction.
- The `dayLoad` consolidation's arbiter-side effect (item-5 flag) is
  described under item 1.

## Noticed but not done

- `DayPlanRefiner` still owns private copies of `planningMinutes` and
  `freeGaps` — the same shape of duplication one level up, now that the
  deterministic engine is a service. Consolidating refiner input assembly
  onto `DayPlanEngine` helpers is a clean future item.
- `DayPlanner.swift` remains dead code; with `DayPlanEngine` now existing
  the name collision got worse. Deleting it is pre-release cleanup
  (ROADMAP §6 dead-code wave).
- The morning prompt (wake+30) and the auto-plan announcement can land in
  the same first-open moment; the prompt names the biggest task while the
  box explains the plan. Not obviously wrong — but worth watching on
  device for whether it reads as two voices.

## Open questions

- Should the auto-plan announce refusals on mornings where the day is
  genuinely full (the no-room case arguably *is* morning news)?
- `DayPlanRefiner`'s `.noTasks` still mislabels the day-over case in Home
  chat copy ("nothing open to schedule") — tolerable, but is a dedicated
  outcome worth it?
