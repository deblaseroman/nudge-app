# Report — 2026-07-30-02 — Eleven-item batch

**Plan:** `archive/2026-07-30-02-plan.md`
**Status:** complete — all eleven items done, none skipped
**Commits:** `2db0220` (1), `4269f3d` (2), `a0a9bba` (3), `453df63` (4), `b3fc685` (5), `155e739` (6), `db1f3b5` (7), `b6a68b1` (8), `98c773e` (9), `8414463` (10), `3c5c3a8` (11) — one per item, in plan order, plus the plan-archive commit `8004aaa` before any work and this report after.

---

## What changed

**1 — Vanishing-task rollover.** New `Nudge/Services/PlacementRollover.swift`:
clears every `plannedStartDate` dated before today, called from `ContentView`
on cold launch and foreground, next to `purgePastEvents` and **before** the
arbiter reevaluate. **`plannedIsAuto` decision: manual placements are cleared
too.** A placement is a slot on one specific day; rolling a manual one forward
would be the app re-asserting a plan the user made for a different day, and
keeping it is exactly the bug. The task drops back to Unscheduled, visible to
the user and both planners. Completed tasks are swept as well (their stale
placements are inert; sweeping keeps the invariant "a non-nil placement is
today-or-later" unconditional). Also updated the floater-targeting comment in
`NudgeArbiter` that had documented "placements are never cleared at rollover"
as the reason for its fire-day scoping — the scoping stays, the reason is now
stated correctly.

**2 — Widget event fetch.** Predicate now scopes to what the widget renders —
today (the next-2 events list) unioned with the 5-hour chart window, which can
cross midnight — sorted by `specificTime`, cap still 20. The chart-window
computation moved above the fetch it now bounds. Timeless events drop out of
the fetch; both consumers already guarded on `specificTime`, so nothing
rendered changes for them.

**3 — `inferCategory` can emit "exam".** New `isExamTitle` (exam / quiz /
midterm / final / test — mirroring the chat prompt's rule) is checked before
the school scan, **on the event title only**: a calendar *named* "Exams"
signals school context for its events, not that each one is an exam.

**4 — Idle suppression.** What I concluded the event check was for, before
changing it: the third leg of a "has the user been active in the 3h before
firing" test — but the other two legs measure things the user actually did
(session started, task completed), while this one inferred activity from an
event's *existence*. It cannot even confirm attendance, it suppressed the
paralysis check-in on every school-day morning (any class inside wake→wake+3h),
and after the `fireDate <= now` rollover, *tomorrow's* class suppressed
tomorrow's nudge during today's reevaluate — a failure the real activity
signals can't have, since sessions and completions only exist in the past.
"Don't fire during/near class" was never its job; the busy-window gate in
`passesGates` enforces that against the candidate's fire date. The check is
removed; `hadCalendarEvent` survives DEBUG-only as the before/after seam (the
builder replays the old rule and prints when the verdicts would differ,
without letting it decide anything).

**5 — Break-it-down removed entirely.** Gone: `.breakItDown` kind,
`buildBreakItDownCandidates`, `NudgeOutcomeResult.tappedBreakDown`,
`category.breakDown` (enum case + `UNNotificationCategory` + its slot in
`setNotificationCategories`), the Settings "Break it down" row, and
`deadlinePrepNotificationsEnabled`'s slot in `ContentView.notificationToken`.
The profile field moved into `UserProfile`'s deprecated block as a tombstone
column — kept so existing stores open without a migration plan, consumed by
nothing. The fatigue gate loses its `.breakItDown` *policy* exemption (there
is no escape-hatch nudge left to exempt) — past `perTaskMaxNudges` the arbiter
now simply backs off; the `successIsObservableInApp` correctness exemption is
untouched. Harness fixture "no activity at all" reseats to `.getAhead`, same
branch coverage. `CLAUDE.md` (work-order item 4, known-bugs entry),
`ROADMAP.md` §2, and `ARCHITECTURE.md` updated to record the removal.

**6 — "urgent" priority retired.** Three parts: the prompt no longer offers
it; `HomeTabView` folds `"urgent"` → `"high"` on both capture write paths
(new tasks and `taskUpdates`) in case the model still emits it; and new
`LegacyPriorityNormalizer` sweeps existing rows once at launch — including
`CompletedTaskRecord`, which copies the task's priority and which Stats
renders verbatim. Idempotent and predicate-scoped, so no completion marker.

**7 — One event-duration resolution.** `NudgeTask.eventDurationMinutes` —
explicit → learned `EventDurationStats` → fallback — replaces all four
implementations (resolver, timeline mirror, and the two truncated copies in
`DayPlanRefiner` and the widget chart). Two overloads: `(modelContext:)`
fetches; `(in:)` resolves against an already-fetched array for the timeline's
60s-tick hot path. **The default:** its single source moved to
`NudgeTask.fallbackEventDurationMinutes` (60), because the widget can't see
`NudgeConfig`; `NudgeConfig.defaultEventDurationMinutes` now *forwards* to it
with a comment saying where to tune, so the tunables index stays complete.

**8 — One countdown implementation.** `CountdownState` (pure — display rules,
the 48h boundary, the 11pm–7am night window, `ordinalSuffix`,
`formatClockTime`, time-ago phrasing) moved from `CountdownLabel.swift` to
`Nudge/Models/CountdownState.swift` and into the widget's
`membershipExceptions`. The widget's `remainingLine`/`dueDateLine` now
delegate outright; `countdown()` derives its state from
`CountdownState.compute` — fixing the 72h/48h self-disagreement — while
keeping its deliberately shorter widget phrasing (weekday not full date,
"in N hours" not "N hours left"). Deleted: the widget's private `timeAgo`,
`ordinalSuffix`, `formatClockTime`, both of its night-suppression copies, and
two orphaned cached formatters.

**9 — Comparator onto `NudgeTask`, plan-first built in.** `sortDeadline`,
`isOverdue`, and `TaskSortComparator` moved to `Nudge/Models/NudgeTask.swift`
(ending both the service-on-view dependency and the widget's private copies).
Plan tasks are now bucket 0 in `sequenceIndex` order, ahead of
overdue/dated/floater/completed. Hand-bolted overrides collapsed at five
sites: `ContentView`'s widget-launched session start, `buildIdleCandidates`'
target pick, `pickTopOpenTask`, the widget row sort, and the Tasks-tab session
picker. Two sites keep their own override deliberately — `floaterTargets`
(collapses to plan-next AFTER its placed-on-fire-day exclusion, an ordering
the comparator can't express) and the two planners (rank non-plan tasks by
Eisenhower `planScore`, not deadline buckets). Invariant 1 in
`ARCHITECTURE.md` rewritten accordingly.

**10 — One palette.** The boundary allows one source: `NudgeTheme.swift` is
pure constants plus the `Color(hex:)` extension, so it joined the widget's
`membershipExceptions` (same mechanism as items 8's move). `WidgetColors` is
now widget-local *names* over the shared palette; no raw color literals
remain in it. `goalAccent` joined `NudgeTheme` as `#54A477` (the exact widget
RGB) and replaced both the widget literal and the rounded inline copy in
`TasksTabView.sessionStateTint` (the "line 837" hardcode).

**11 — `#Preview` container re-synced.** Now matches
`SharedModelContainer.schema`'s sixteen entries in the same order, with a
comment naming invariant 2 at the site.

## Verification

- **Both schemes built after every one of the eleven commits** (not just at
  the end) — twenty-two green builds total, via `xcodebuild` (the Xcode MCP
  server disconnected at the start of the run).
- **Item 5 before/after — inert by construction, stated per the template
  rather than skipped silently:** `buildBreakItDownCandidates` opened with
  `guard NudgeConfig.fatigueGateEnabled else { return [] }`, and that flag has
  never been true in production — every prior arbiter log shows
  `breakDown: SKIP — fatigueGateEnabled is off`. The builder therefore
  contributed zero candidates to every reevaluate that has ever run, and
  removing it cannot change any candidate set. Likewise no `.breakItDown`
  outcome row, no `tappedBreakDown` value, and no `category.breakDown` request
  has ever existed in a store; the tolerant `kind`/`result` getters cover
  hypothetical strays. The fatigue-gate exemption removal is inert for the
  same reason (the gate runs only when the same flag is true).
- **Items 1 and 4 before/after — DEBUG seams in place, real-data run needs
  the device**, same standing situation as cycles 1–4 (no real store on this
  machine). Ten-minute pass: (a) place a task on the timeline, move the
  device clock past midnight (or wait a day), launch — console prints
  `🧹 PlacementRollover:` naming each rescued task with `[auto|manual]` and
  "was in no list section", and the task is back under Unscheduled;
  (b) with a school-day calendar imported, trigger a reevaluate — console
  prints `idle: BEFORE/AFTER — old event-window rule would have SUPPRESSED
  this candidate; new rule builds it`, which is the per-candidate old-vs-new
  verdict; confirm the idle nudge then dies at the busy-window gate only when
  its fire moment actually lands in class. (c) `LegacyPriorityNormalizer`
  prints a fold count if any "urgent" rows existed.
- **Item 2:** the fix is visible in the predicate itself (sorted, scoped);
  falsifier on device: with >20 events imported, today's classes appear in
  the widget.
- **Item 7:** falsifier on device — an event with a learned 180-minute
  `EventDurationStats` row and no explicit estimate now draws 3 hours wide in
  the widget chart and reads as 180 minutes in the AI planner's event DTOs,
  matching the busy gate.
- **Item 8:** with a deadline 60 hours out, widget `countdown()` now says
  "· 2 days away" (state from the shared 48h boundary) instead of "in 60
  hours"; `remainingLine` and the app agree by construction.
- **Item 9:** ordering deltas are enumerated under Deviations; the app list
  sections are unchanged because they filter `sequenceIndex == nil` before
  sorting, exactly as before.
- **Item 10:** value changes are enumerated under Deviations; worth one
  glance at the widget on device.

## Deviations from the plan

- **Item 3 went one call site beyond `inferCategory`:** the Canvas iCal path
  hardcoded `category: "school"` for every import, and Canvas is where exams
  come from — fixing `inferCategory` alone would have left the item's stated
  purpose (study tasks from exam events) unmet for its primary source. Both
  paths now share `isExamTitle`. Also, "test" is in the keyword set (the chat
  prompt says "tests"; `inferPriorityFromCanvas` already treats it as high) —
  it's the most false-positive-prone of the five, noted below.
- **Item 6 swept `CompletedTaskRecord` too** — it copies the task's priority
  at completion and Stats renders it verbatim, so normalizing only `NudgeTask`
  would have left "Urgent" pills in Stats history.
- **Item 8 did not unify the widget's countdown *phrasing*** — `countdown()`
  keeps its deliberately shorter formats (weekday, "in N hours") and only the
  state decision is shared. Full text-unification would have changed widget
  copy, which the item didn't ask for; the disagreement it named (72h vs 48h)
  is gone.
- **Item 9's "seven sites" resolved as five collapsed + two deliberately
  kept** (`floaterTargets` and the two planners' `planScore` ranking — the
  comparator can't express either without changing their semantics). One
  behavior delta: widget completed-vs-completed rows now tie-break by newest
  completion (the comparator's rule) instead of deadline — visible only
  during the 1.5-second post-completion animation window.
- **Item 10 chose the "read one source" branch** and it required adding
  `NudgeTheme.swift` to the widget target, which changes invariant 3's "and
  nothing else" (documented). Deliberate visual deltas from adopting theme
  values: widget surface picks up the app's 0.88 alpha, textSecondary/
  textMuted snap to the theme grays instead of ink-at-alpha, `neutral` maps
  to `NudgeTheme.textSecondary` (its old value was a rounded copy of
  textMuted, and mapping it there would have inverted the medium/low pip
  ordering), divider/checkboxBorder unify on `NudgeTheme.border` (α 0.22 vs
  the old ad-hoc 0.14/0.28), chipBackground becomes `surfaceAlt`.
- **Item 1 sweeps completed tasks' stale placements too** — not named in the
  plan; reasoning in the file header (keeps the invariant unconditional,
  changes nothing observable).

## Noticed but not done

- **The task-duration default is still duplicated** — `TodayTimelineView.
  taskMinutes` (30) and the widget's `plannedDurationMinutes ??
  estimatedMinutes ?? 30`. Item 7 covered the *event* lookup; the task-side
  default is a smaller, separate consolidation.
- **`CountdownState`'s night window (23–7) is hardcoded**, not the user's
  quiet-hours setting. Adjacent to the quiet-hours work but a product
  question (should a text label follow notification quiet hours?), left.
- **`WidgetCountdownFormatter.pickPrefix` keyword-scans titles for
  "exam"/"quiz"** — with item 3 landed, imported exams now carry the exam
  *category*, which would be the cleaner signal. Left; copy change.
- **`NudgeOutcome.kind`'s `?? .idle` fallback** silently reattributes any
  unknown stored kind to `.idle`. Harmless today (no unknown values can
  exist), but a future kind removal that *has* fired should think about it.
- **Cycle-ID ordering oddity:** the archive already held `2026-07-31-01`
  (dated tomorrow relative to today, 2026-07-30) when this batch started, so
  this cycle's ID `2026-07-30-02` — assigned per the README's rule — sorts
  *before* an already-completed cycle. Cosmetic, but the audit should know
  the directory's sort order and the actual sequence disagree here.
- **Lexend fonts** (cycle `2026-07-31-01`'s item 2) remain outstanding — out
  of scope for this batch by name.

## Open questions

- The batch's outstanding evidence is one device pass (items 1, 4, 5's
  console seams plus a visual glance at the widget after items 2/7/8/10).
  Fold it into the next device session — the checklist is in Verification.
- Item 1: if a user reports wanting yesterday's *manual* placement to carry
  into today, the answer would be a "re-place for today?" prompt, not
  silent carry-forward — flagging so the decision isn't relitigated from
  scratch.
