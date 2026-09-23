# Report — 2026-08-04-02 — Placement lifecycle nudges, budget to 10

**Plan:** `archive/2026-08-04-02-plan.md`
**Status:** complete
**Commits:** `1bce328` (item 2), `1cc0017` (item 3); diagnosis (item 1) changed nothing, archive committed as `02788c2`

---

## What changed

### Item 1 — Diagnosis (no code)

Confirmed: **nothing was built for those tasks.** No candidate builder fires on
a placement passing unstarted. Walking all seven builders:

- `eventBlock` — only `isInformationalEvent` calendar events.
- `morningPrompt` — names the biggest open task at wake+30; it fired (the one
  notification that day).
- `idle` — asks generically at wake+3h; blind to placements.
- `prep` / `dueSoon` — both require a `dueDate`; even for a dated task,
  neither reads the placement slot.
- `comeBack` — absence-based, irrelevant here.
- `floater` — the only builder that reads `plannedStartDate` at all, and it
  reads it to **exclude** tasks placed on the fire day (Jul 2026, so the
  check-in wouldn't announce "still open" hours before the task's own slot).

So the sharper form of the finding: **placing a task on the timeline
*reduced* its notification coverage.** An undated open task was at least a
floater target; placing it removed that and added nothing. No gate rejection
was involved — the candidates never existed. The plan's hypothesis was right.

### Item 2 — Placement lifecycle (commit `1bce328`)

**Two kinds, not one.** `.placementLead` (A) and `.placementMissed` (B).
They share a target but "does a heads-up help the user start on time" and
"does a follow-up recover a missed slot" are separate questions wanting
separate baselines — this is exactly the lesson of the `.floater`/`.getAhead`
and `.prep`/`.dueSoon` splits, where two moments summed under one kind
produced rows that measured neither. Both `successIsObservableInApp == true`
(starting or completing is in-app), per the plan's constraint.

**A — heads-up, 5 min before the slot** (`buildPlacementLeadCandidates`).
Clusters placements with the *same* `clusterEvents` chaining event blocks use,
under a **new constant `placementClusterGapHours` (2h)** — the plan asked
whether the event window suits placements: the *value* does (a 10/11/13/15
plan yields two clusters, two warnings 3h apart), but planner slots pack
tighter than calendar events, so the two need to be tunable apart; reusing
`eventBlockGapHours` directly would couple them. Body: "“Laundry” is set for
10:00 AM, then “Reading” at 11:00 AM." — facts only. No ASAP fallback and no
delivered-marker map: once the fire time passes the candidate simply isn't
rebuilt, and everything past the slot belongs to B. Actionless category
(due-soon reasoning: a batch makes Start ambiguous).

**B — follow-up after the slot passes unstarted**
(`buildPlacementMissedCandidates`). The proposed and implemented schedule:
**slot + 30 min grace, then every 2 hours, capped at 4 attempts, clipped to
the slot's own day.** Not hourly — `minNudgeSpacingMinutes` (90) evicts any
series denser than itself, so "hourly" would really deliver every other
attempt at random; 2h is the honest version. Four attempts span ~6.5h past
the slot, and `PlacementRollover` ends any survivor at midnight by clearing
the placement, so the series is same-day by construction. The whole series is
handed to the OS up front, so it keeps delivering when the app never runs
again that day — the exact user this kind exists for. "Missed by ten minutes
vs. four hours" falls out of the anchoring: the 30-min attempt is the fresh
case, the later fixed anchors are the stale one.

**Catch-up:** a slot that passed with *no* attempt delivered (e.g. a task
placed onto an already-past slot) fires one ASAP attempt, guarded by a
`placementMissedHistory` delivered-marker map (the eventBlock/dueSoon
pattern) and skipped when the next scheduled attempt is already inside the
spacing window (an ASAP inside it would only evict that attempt in
`pickWinners`).

**Ending the series:** completing the task, unscheduling it, or starting a
session all trigger data-driven reevaluates; the rebuild drops the task from
the predicate (complete/unplaced) and `cancelAll` wipes the pending
remainder. An active session also blocks attempts that would land inside it,
and the 90-min activity cooldown covers "just started working".

**Copy (B):** "“Laundry” was set for 10:00 AM and is still open. Just 25 min
— start there?" — the slot time is the fact, "still open" is app state, no
verdict (`DESIGN.md`). The minutes figure is the plan's own
`plannedDurationMinutes` when present, capped at 25 like prep/floater.

**Both discretionary in every dimension** (budget, quiet hours, busy windows,
spacing), with urgency floored at a new `placementUrgencyFloor` (0.75) — the
user's own plan slipping is the urgency signal (the prep-floor precedent,
stronger). That floor is how B is "the kind most willing to spend budget"
without ignoring any gate.

**Toggles: two, not one** — `placementLeadNotificationsEnabled` and
`placementMissedNotificationsEnabled` ("Timeline heads-up" / "Timeline
follow-up" in Settings). The persistent follow-up is the likeliest opt-out,
and silencing it must not cost the 5-minute warnings.

Files: `NudgeOutcome.swift` (kinds + observability), `NudgeConfig.swift` (6
constants), `NudgeNotificationCategories.swift` (2 categories, registered),
`UserProfile.swift` (2 toggle fields), `SettingsTabView.swift` (2 rows),
`ContentView.swift` (notificationToken entries so a toggle flip reevaluates),
`NudgeArbiter.swift` (builders, marker map + prune, schedule() marker write,
`debugPlacementImpact`), `TasksMessageBox.swift` + `TodayTimelineView.swift`
(exhaustive kind switches), `ARCHITECTURE.md`.

### Item 3 — Budget 3 → 10 (commit `1cc0017`)

`dailyNudgeBudget = 10`, documented as an observation setting, not a final
value.

**What it changes downstream — spacing is now the binding constraint.** With
the default profile (wake 8:00, bed 23:00) the discretionary window is
08:30–22:00 = 810 min; 90-min spacing fence-posts that at **10 slots/day**.
Budget-exempt winners (morning prompt, event blocks, due-soon) are seeded
into the winner set first and each consumes a spacing slot discretionary
candidates can't use, so the **effective discretionary ceiling ≈ 10 minus the
day's exempt count** — e.g. a day with the morning prompt, two event-block
reminders and one due-soon caps out around 6. The budget of 10 is therefore
reachable only on an empty-calendar day with perfectly spread candidates;
on real days spacing binds first. `debugBudgetImpact` prints this per run:
the winner pick replayed under the old budget of 3 beside the actual one,
plus the day's effective ceiling.

**Event reminders cannot be crowded out at any budget** — they bypass the
budget and pass straight through `pickWinners` before any discretionary
candidate is considered. That evidence item holds by construction; the
winner-list dump on a real day will show it.

Stale "~3 a day can fire" comments on the copy-generation caps updated.

## Verification

- **Builds:** both schemes (`Nudge`, `NudgeWidgetExtension`) build after each
  commit — exit 0, and full-log grep for `warning:` clean (edited files
  force-recompiled to make the grep meaningful).
- **Work-order item 5:** `debugPlacementImpact` and `debugBudgetImpact` are
  in place and run on every DEBUG reevaluate — placement candidates with
  per-candidate verdicts (scheduled / lost pickWinners / gate-blocked), the
  pre-placement winner set beside the actual one with DISPLACED rows named,
  and the old-budget replay with FREED rows named. **The real-data run
  itself needs the app launched on a device/simulator with the real store,
  which I can't do from here** — the next DEBUG launch prints both
  comparisons; nothing goes live before they're read since nothing else
  consumes these kinds yet.
- **Verified by construction, not observed:** "a task placed an hour ago and
  untouched produces a nudge" — the catch-up path fires ASAP when the slot
  passed with nothing delivered, or the next series attempt is already
  pending within 90 min. "The nudge names the task and the time" — body
  template. Both want a device pass to confirm end-to-end.
- The `#Preview` container in `ContentView` was already missing four models
  and gains nothing new (no new `@Model`; the three schema lists are
  untouched).

## Deviations from the plan

- **Two per-kind toggles instead of the plan's singular "its own per-kind
  toggle"** — follows from choosing two kinds (the plan left one-vs-two to
  me); one switch over two features is the exact mistake the floater/get-ahead
  toggle split fixed.
- **The "five-edit pattern" is really field + Settings row + builder guard +
  `notificationToken` + category registration here** — no `init` parameters,
  matching the newer convention (`dueSoonReminder`, `comeBack` rely on
  property-level defaults only; property default is what protects existing
  stores).
- **The plan's evidence section says "Budget of 5"** where the item says 10.
  Treated 10 as authoritative (it's the item text); the 5 reads as a draft
  leftover. Flagging rather than silently reconciling.
- Fixed in passing: `ARCHITECTURE.md`'s floater note still claimed
  "placements are never cleared at day rollover", which `PlacementRollover`
  made false — corrected while editing the adjacent text.

## Noticed but not done

- **The morning prompt can evict a placement heads-up by spacing.** Default
  wake 8:00 → prompt at 8:30; a first slot at 10:00 puts the lead at 9:55,
  85 min later — inside the 90-min window, so the heads-up loses (the prompt
  is budget-exempt and seeded first). First slots ≥ 10:05 clear it. Left
  alone: retuning spacing or exempting the pair is a decision for after the
  first outcome rows exist.
- **Placement kinds get template copy only** — not added to
  `NudgeCopyService.buildRequests`. Deliberate: their bodies embed exact
  clock times computed at scheduling (the eventBlock/dueSoon reasoning), and
  B's persistence makes stale AI copy riskier than a plain template.
- **B can't tell "started a session on this task" from "never touched it"**
  once the session ends — the app-group record holds only the most recent
  session start, with no per-task history. An attempt after an
  unfinished-but-worked-on slot still fires. Permissive direction, matches
  the user's stated preference; a session log is out of scope (same note as
  the activity-cooldown limitation).
- `ROADMAP.md` §1 untouched — fatigue gate off, stakes not armed anywhere
  (the new builders derive importance through the same no-stakes call path
  as idle/prep/floater).

## Open questions

- After a week of `.placementLead` / `.placementMissed` rows: is 4 × 2h the
  right persistence, and does the catch-up read as helpful or as noise?
- The budget of 10 is explicitly provisional — what number do the observed
  winner lists argue for, and should spacing (now the binding constraint)
  be retuned instead?
- Should the placement heads-up win against the morning prompt inside the
  spacing window (see Noticed)?
