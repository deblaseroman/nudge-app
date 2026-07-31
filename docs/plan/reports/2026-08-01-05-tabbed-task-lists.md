# Report — 2026-08-01-05 — Tabbed task lists

**Plan:** `archive/2026-08-01-05-plan.md`
**Status:** complete
**Commits:** see branch `automation-run-1` (single commit for this cycle)

---

## What changed

- `Nudge/Views/Tabs/TasksTabView.swift` — everything below Start Session
  replaced by a horizontal capsule tab strip (Unscheduled / Today / Events /
  Overdue), one list visible at a time. Nothing above Start Session touched.
  Details:
  - **Unscheduled**: open non-plan tasks not on *today's* timeline — undated,
    unplaced, **or placed on a non-today day**. That last case is new: a
    stale placement used to belong to no section (the vanishing-task shape);
    it now shows here. Prep tasks (`source == "prep"`) group per exam
    (`linkedEventId`): the comparator-first row (nearest study day — today's,
    when the sweep is current) renders normally at its sort position, the
    exam's remaining days collapse behind one "Show N more study days"
    control styled identically to the Events show-more button.
  - **Today**: the numbered drag-reorderable plan list (unchanged
    `List`/`.onMove` machinery, its "Today's plan" label dropped since the
    tab is the label) followed by placed-today rows, in one tab. The two sets
    never overlap (`sortedTasks` already excludes plan tasks). Empty state:
    a lone Plan my day button calling the same `planMyDay()`.
  - **Events**: two lens chips, This week (day ≤ today+7, no lower bound so
    past-day incomplete events stay visible; dateless events pass — they park
    under today as before) and Important (`stakes == .high`, any date). Same
    day-group rendering + show-more-days collapse as before, applied per
    lens; `eventDayGroups` became a function taking the lens's event list.
  - **Overdue**: open, past due, `stakes != .low` (nil counts — the row
    treatment's exact rule), including plan tasks so the count never
    understates. Label + count badge in `NudgeTheme.overdue` red.
  - **Completed (N) control deleted**, along with `WeeklyCompletedSheet`,
    `thisWeekCompleted`, and its sheet presentation — that sheet's only entry
    point was the deleted button, and completed history remains fully
    reachable in the Stats tab, so no feature was orphaned. The weekly
    `purgeOldCompletedRecords` sweep (and the `weekStart` helper it needs)
    stays — it keys on tab appear, not the button.
- `ARCHITECTURE.md` — `TasksTabView` entry rewritten for the tab layout.
- `ROADMAP.md` — §4's section-restructure bullet marked superseded-and-done
  by this cycle; the vanishing-task bullet reworded (presentation half fixed
  here — no longer data-loss-shaped — but the stale `plannedStartDate` data
  still needs the rollover sweep). §1 untouched.

## Decisions the plan delegated

- **Default tab on open: Today.** The landing spot never moves, which
  matters for the audience (predictability over cleverness), and the red
  badge already does Overdue's "look here" job from any tab.
  Overdue-when-non-empty would additionally land the user on a red list at
  every open — close to the wall of DESIGN.md's never-shame rule.
- **Tab state on relaunch: not persisted.** `@State` only — survives tab
  switches within a session, resets to Today on launch. Same for the events
  lens and the prep-expansion set.

## Verification

- Both schemes build: `xcodebuild … -scheme Nudge` and
  `… -scheme NudgeWidgetExtension` → **BUILD SUCCEEDED**, zero warnings
  (grepped for `warning:` per the isolation-warning precedent).
- **Work-order item 5 (arbiter before/after): skipped as inert by
  construction.** No candidate builder, gate, scorer, or `NudgeConfig` value
  was touched; every edit is view-layer list membership and styling in
  `TasksTabView.swift` plus docs. The arbiter never reads this view's
  computed lists.
- **Coverage audit (by construction, not run):** every open non-event task
  is `sequenceIndex != nil` (→ Today), or placed today (→ Today), or
  neither (→ Unscheduled); Overdue is a bonus lens on top. Events all belong
  to the Events tab, **but see the lens gap under Deviations**.
- Not verified here (needs the device pass): each tab rendering with real
  data, badge count correctness, Important-vs-This-week behavior on a real
  far-out exam, prep collapse per exam, drag-to-reorder in Today. The
  reorder machinery is byte-identical to the pre-tab plan section, so risk
  is low, but "verified" would be a lie.

## Deviations from the plan

- **The prep-task grouping did not exist to "still apply."** The plan's
  "Prep-task grouping still applies inside whichever tab holds them"
  implies an existing behavior; there was none — prep tasks rendered as
  flat rows. I built the grouping new, in Unscheduled (the tab that holds
  prep tasks), reusing the Events collapse idiom as instructed. Overdue
  does *not* group: an overdue prep task there renders as a plain row,
  since that tab's job is to show exactly what's late.
- **Overdue tab is red only when non-empty.** The plan says label and badge
  in overdue red, full stop; with a zero count I drop to standard chip
  colors and hide the badge. Red with nothing behind it is alarm without
  cause, and one color must not carry two meanings — including "urgent" and
  "fine."
- **Events lens gap, reported as instructed:** an event dated beyond 7 days
  with stakes below high appears under *neither* lens. It's in the Events
  tab's data and the Calendar tab still shows it, but within this tab it's
  invisible. The plan's own example (exam three weeks out → Important)
  assumes far-out events are high-stakes; a medium-stakes event four weeks
  out is the case that falls through. Tasks have no such gap. I did not
  invent UI to patch it — flagging for the planner instead.
- **The Today "merge" is plan-list-then-placed-rows in one tab**, not one
  interleaved reorderable list. Interleaving would have put non-plan rows
  inside the `.onMove` ForEach, where a drag would have to invent
  `sequenceIndex` semantics for placed tasks. The gesture survives intact
  because it stays scoped to the plan rows — this is the merge *with* the
  escape hatch's concern designed out, not the fallback.

## Noticed but not done

- `DEVICE-CHECK-automation-run-1.md` §0/§1 references the old "Unscheduled,
  Scheduled" sections; post-build, the resurrect check should read "appears
  in the Unscheduled tab." Left the checklist untouched — it's mid-flight.
- Today's empty-state Plan my day button with zero open tasks produces only
  an error haptic (existing `planMyDay()` behavior). The spec said "a Plan
  my day button, nothing else," so nothing else it is.
- "Plan my day" now appears twice on screen when Today is empty (header row
  above the timeline — untouchable scope — plus the empty state). Cosmetic.
- `routineRepeatedTitles` still counts over ALL events, not per-lens —
  deliberate: that's the population the routine rule was validated against.
- The old full-screen "No tasks yet" onboarding copy now lives only in the
  Unscheduled tab (shown when there are no tasks, events, or plan at all).

## Open questions

- Does the Events tab need a third treatment for the lens gap (non-high
  events beyond 7 days), or is the Calendar tab their designated home?
- Should the device checklist be regenerated for this cycle's UI, or
  amended in place?
