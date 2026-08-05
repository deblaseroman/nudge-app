# Report — 2026-08-05-01 — Make the planner's state files checkable

**Plan:** `archive/2026-08-05-01-plan.md`
**Status:** complete
**Commits:** `9035ffa` (archive), `c00cf51` (part 1, this file's census), `2a1baaa` (part 2), `8dc16a5` (part 3), `4de6bb4` (part 4), plus this report update.

---

## Part 1 — The census

Enumerated from source at commit `9035ffa` (source tree identical to `590008f`,
the last cycle's final source commit). Every claim below is backed by a named
symbol; greps and reads were run against the working tree, not any document.
Part 1 changes no tree state by design ("no doc edits yet"), so its commit is
this report file itself, written census-first.

### Candidate builders — ten, in `reevaluate` call order

All in `Nudge/Services/NudgeArbiter.swift`; each opens with a
`guard profile.<toggle>` (line refs below are the guard). Kinds are
`NudgeOutcomeKind` cases (`Nudge/Models/NudgeOutcome.swift`). "Exempt" =
`countsAgainstBudget: false`, which also bypasses every shared gate except
fatigue.

| # | Builder | Kind | Fire anchor | Budget | Toggle (default) | Reachable? |
|---|---|---|---|---|---|---|
| 1 | `buildEventBlockCandidates` (:616) | `.eventBlock` | cluster start − `eventReminderLeadMinutes` (60m); clusters gap ≤ `eventBlockGapHours` (2h) | exempt | `eventReminderNotificationsEnabled` (true) | yes |
| 2 | `buildMorningPromptCandidates` (:811) | `.morningPrompt` | wake + `postWakeQuietMinutes` (30m) | exempt | `morningCheckInNotificationsEnabled` (true) | yes; self-gates on day-fullness (`morningPromptBusyDayThreshold`) and fire-moment busy |
| 3 | `buildIdleCandidates` (:1249) | `.idle` | wake + `idleThresholdHours` (3h) | counts | `sessionStarterNotificationsEnabled` (true) | yes; per-day dismissal key `idleDismissedKey` |
| 4 | `buildPrepCandidates` (:1470) | `.prep` | `StartByPlanner` day at wake + `prepAnchorHoursAfterWake` (2h) | counts | `taskDueSoonNotificationsEnabled` (true — the pre-split field name, kept for intent continuity) | yes |
| 5 | `buildDueSoonCandidates` (:1594) | `.dueSoon` | deadline − `dueSoonLeadMinutes` (120m); same-hour deadlines batch (`dueSoonBatchWindowMinutes`) | **exempt** | `dueSoonReminderNotificationsEnabled` (true) | yes; once-per-task via `dueSoonHistory` marker map |
| 6 | `buildFloaterCheckInCandidates` (:1827) | `.floater` | wake + `floaterCheckInHoursAfterWake` (6h) | counts | `floaterCheckInNotificationsEnabled` (true) | yes (rollover fixed Jul 2026; anchor still documented known-bad) |
| 7 | `buildComeBackCandidates` (:2019) | `.comeBack` | lastEngagement + `comeBackAfterDays` (3d) at wake + 2h; evidence-anchored, engagement pushes it forward | counts | `comeBackNotificationsEnabled` (true) | yes |
| 8 | `buildGoalLapseCandidates` (:2190) | `.goalLapse` | (goal `lastActivityAt` ?? `createdAt`) + `goalLapseAfterDays` (30d) at wake + 8h; per-goal monthly cap via `goalLapseHistory`; one candidate per run | counts | `goalLapseNotificationsEnabled` (true) | yes (new, cycle 2026-08-04-03) |
| 9 | `buildPlacementLeadCandidates` (:2322) | `.placementLead` | slot − `placementLeadMinutes` (5m); clusters gap ≤ `placementClusterGapHours` (2h) | counts | `placementLeadNotificationsEnabled` (true) | yes |
| 10 | `buildPlacementMissedCandidates` (:2462) | `.placementMissed` | slot + `placementMissedGraceMinutes` (30m), repeating `placementMissedRepeatMinutes` (120m) × `placementMissedMaxAttempts` (4), clipped to the slot's day | counts | `placementMissedNotificationsEnabled` (true) | yes |

Kind with **no** builder: `.getAhead` — legacy, retired at the Aug 2026
prep/dueSoon split; rows keep their raw value for attribution.

Five profile toggles have **zero readers outside `UserProfile.swift`**:
`eveningCheckInNotificationsEnabled`, `windDownNotificationsEnabled`,
`habitReminderNotificationsEnabled`, `monthlyCheckInNotificationsEnabled`,
`deadlinePrepNotificationsEnabled` (the documented tombstone). They gate
nothing; four of the five are *undocumented* dead fields.

### Gates, in evaluation order

Upstream of the shared gates: the 60s debounce (time-triggered reasons only),
`cancelAll`, and the master `profile.notificationsEnabled` guard
(`reevaluate`, :349). Budget-exempt builders self-gate inside their builders.

`passesGates` (:2640s), per candidate, in order — the first four apply only
when `countsAgainstBudget`:

1. **Active session** — `firesDuringActiveSession(fireDate)`.
2. **Activity cooldown** — `firesInsideActivityCooldown(fireDate)`
   (`recentActivityCooldownMinutes`, 90).
3. **Quiet hours** — `passesQuietHours(fireDate:profile:)`; wrapping
   minutes-of-day interval; zero-length window fails OPEN.
4. **Busy windows** — `BusyWindowResolver.shared.isBusy(at: fireDate)`.
5. **Per-task fatigue — DISABLED.** `NudgeConfig.fatigueGateEnabled = false`
   (:66). When armed it would suppress after `perTaskMaxNudges` (3) ignored
   rows, skipping nil-`taskID` candidates and kinds where
   `successIsObservableInApp == false` (`.eventBlock`, `.dueSoon`).

Every gate reads the candidate's **fire date**, never `now` (the Jul 2026
invariant holds; no regression found).

Downstream, `pickWinners`: exempt candidates pass through; discretionary
grouped by fire day, sorted by `score`, admitted under `dailyNudgeBudget` (10)
and `minNudgeSpacingMinutes` (90), with exempt winners seeded first (an event
heads-up can evict a discretionary neighbor on spacing).

### AI call sites — seven live, one dead

All API traffic goes through `ClaudeService` (Haiku). Per site: what it
reads, what it writes, and whether its product reaches an arbiter decision.

| Caller → method | Reads | Writes | Reaches an arbiter decision? |
|---|---|---|---|
| `HomeTabView` → `sendChat` | dump, history, open-task context, known commitment sizes, active goals (G-refs) | `NudgeTask`s/updates, commitment fields, `goalID` links | Indirectly: creates/edits the data every builder reads; no call in the arbiter's path |
| `ScreenshotCalendarImporter` → `parseScheduleScreenshot` | schedule screenshot | event `NudgeTask`s | Same indirect shape |
| `NudgeIntelligence` → `send(userMessage:)` | one task's fields | `TaskIntelligence` row (`statedUrgency`, `suggestedFirstStep`), `intelligenceCacheDays` (7) TTL, single-flight | **YES — the one direct line.** `cachedIntelligence` is read synchronously (cache-only, no network) inside the idle, prep, and floater builders and its `statedUrgency` feeds `EisenhowerScorer.importance`, hence `score`, hence winner selection |
| `StakesBackfill` → `classifyStakes` (×2) | task titles | `task.stakes` (guarded automation path) | **YES, one hop:** morning-prompt ranking reads `task.stakes` directly (`morningStakesRank`) — allowed by work-order item 1, which keeps stakes out of the *scorer*, not out of the arbiter |
| `NudgeCopyService` → `generateNudgeCopy` | top candidates per kind, absolute due phrases | app-group copy cache | Body-text only: `resolvedBody` swaps cached copy at scheduling; **never timing or selection** |
| `DayPlanRefiner` → `refineDayPlan` | day summary | `plannedStartDate`/`plannedDurationMinutes`/`plannedIsAuto`, rationale | Indirect: placements feed the placement builders and floater exclusion |
| `TasksTabView` → `generateGoalLapseHook` | goal, elapsed phrase, open titles, ignored-count | message-box hook text (per-goal-per-day cache) | No — display only, reads arbiter state, changes nothing |
| `CalendarService` → `generatePrepPlan` | — | — | **DEAD**: referenced only inside a comment block (:456); `ClaudeService.generatePrepPlan` (:649) has no production caller |

So the honest claim is: **no API call in the arbiter's path** (true, load-
bearing, verified) — but AI *products* reach arbiter decisions through two
cached channels: `statedUrgency` → importance → score, and `stakes` → morning
ranking. "Fully deterministic, no LLM anywhere in this path" is only true of
call timing, not of inputs.

### Deliberately-not-armed states

- **Stakes → scorer.** `EisenhowerScorer.importance(… stakes: TaskStakes? = nil)`
  (:65–70): every production call site omits it (arbiter :1355/:1531/:1875/:2623,
  `DayPlanEngine` :542, `DayPlanRefiner` :239). Only the DEBUG harness
  (`debugStakesImpact`, :3023) passes it. `NudgeConfig.stakesImportanceBonus`
  and `stakesSignalCombinedCap` exist, consumed by that harness alone.
- **Fatigue gate.** `NudgeConfig.fatigueGateEnabled = false` (:66);
  `perTaskMaxNudges = 3` waits on it. `.ignored` rows are being written and
  observed.
- **Explicit feedback (👎).** Written by the delegate
  (`NudgeNotificationService` :361), read only by the classifier's DEBUG dump
  (`NudgeOutcomeClassifier` :323–335). No behavioral consumer.
- **`NudgeCandidate.receptivity`** — vestigial field, no longer in scoring.
- **`NudgeCandidate.quadrant`** — DEBUG diagnostic only ("step 6" gating not
  built).
- **`NudgeGoal.frequency`** — written at onboarding, zero readers (including
  the new lapse logic, which is flat 30-day).
- **Legacy zero-reader toggles** — the five profile fields listed under
  builders.
- **Retired-but-present code** — `NotificationScheduler` (session-start key +
  one-time legacy cleanup only), `SentNotificationFlag` (legacy path only),
  `DayPlanner.swift` (dead), `TaskScheduler`/`SmartNotificationEngine`/
  `NotificationMessageGenerator`/`FocusSessionManager` (cleared stubs).
- **`MessageBoxChatShell`** — visual prototype, all stubs; both goal messages
  currently point users at it ("tap the bubble").

### Contradictions with the current docs

Against **`CONTEXT.md`** (the file this cycle rewrites):

1. "six builders" → there are **ten**; the table lists a builder that no
   longer exists (break-it-down, removed Jul 2026, listed as "paused pending
   removal") and is missing dueSoon, come-back, both placement kinds, and
   goal-lapse entirely.
2. "Get-ahead" row → no builder emits `.getAhead`; it split into `.prep` +
   `.dueSoon` in Aug 2026.
3. "AI appears at exactly two points, both where data enters" → **seven live
   call sites**, and two cached AI products (statedUrgency, stakes) reach
   arbiter decisions; the true invariant is narrower ("no API call in the
   arbiter's path") and stated above.
4. "Budget-exempt builders (event blocks, morning prompt)" → dueSoon is the
   third exempt kind.
5. "The floater check-in has never produced a single outcome row" → stale
   framing; the rollover bug was fixed Jul 2026 and the file itself
   half-acknowledges this ("baseline data should now start accumulating") —
   but a fresh planner reading the first clause plans against dead data.
6. Gates description omits the evaluation order, the fire-date-not-now
   invariant, and that the fatigue gate is disabled by a named flag
   (`fatigueGateEnabled`) rather than absent.
7. "Outcome recording captures … explicit opinion (👍/👎)" → 👍 was removed
   Jul 2026; the channel is 👎 only.

Against **`CLAUDE.md`**:

8. "Rebuilds candidates (event-block reminders, morning prompt, idle,
   get-ahead, floater check-in)" (§the core loop) → five named of ten, one of
   them retired. Not fixed this cycle (`CLAUDE.md` gains exactly one rule per
   the constraints); flagged for a future cycle.
9. "There are exactly two AI touchpoints" appears in **`DESIGN.md`** (Roman's
   uncommitted working copy already revises it to four) — Roman's file, not
   touched; noted so the count gets reconciled with the census's seven
   whenever that edit lands.

Against **`ARCHITECTURE.md`**: no material contradictions found — it was
updated alongside each cycle and matches the census on builders, gates, and
AI sites. (It is also 4× the length a planner can be relayed, which is why
`CONTEXT.md` exists.)

---

## What changed (Parts 2–4)

- `docs/plan/CONTEXT.md` (part 2, `2a1baaa`) — rewritten from the census.
  Builder table (ten rows, kinds named), ordered gate list with the disabled
  fatigue gate and its flag, the AI section restated around the true
  invariant ("no API call in the arbiter's path") with all seven live sites
  and the two cached channels that DO reach arbiter decisions, and the
  not-armed inventory. Header stamp: `Verified against 9035ffa at cycle
  2026-08-05-01`. Census sections marked ⚙ derived/regenerated-by-cycle;
  prose sections unmarked and hand-written. The drift self-warning is
  **dropped** — replaced by the stamp plus the pointer to part 3's standing
  rule, which together make staleness checkable rather than merely
  confessed. The ask-for-relay rule is preserved verbatim, as is the root-doc
  directory.
- `CLAUDE.md` (part 3, `8dc16a5`) — one rule, placed directly after the
  planning-bus paragraph in the Project section: any cycle that adds,
  removes, re-anchors, or disables a builder, a gate, or an AI call site
  updates `CONTEXT.md`'s census sections and stamp **in the same commit**.
  Why there: it's where `CONTEXT.md`'s role is introduced, and it sits in
  the same family as the other keyed-on-the-change disciplines (three
  schema lists, the ARCHITECTURE.md update rule) that CLAUDE.md already
  carries. The work order was the wrong home — it holds sequencing
  constraints that expire; this is a permanent maintenance invariant.
- `docs/plan/README.md` + `CONTEXT.md` pointer line (part 4, `4de6bb4`) —
  the reader-side completion rule, verbatim from the plan, at README step 6
  (with the failure it closes named: archive-by-copy leaves a finished plan
  looking live) and in the Decisions paragraph that defines `NEXT.md` as a
  mutable pointer. `CONTEXT.md`'s protocol pointer now carries the check
  inline.

## Verification

- **Inert by construction for the app** — no file under `Nudge/`,
  `NudgeWidget/`, or the project was touched this cycle (git diff confirms:
  only `docs/plan/*` and `CLAUDE.md`), so no arbiter behavior can differ and
  work-order item 5 does not apply. Said here rather than silently skipped,
  per the plan.
- Both schemes build (`BUILD SUCCEEDED` × 2) after the final commit — the
  floor. Intermediate commits touched no buildable file, so per-commit
  builds would have re-verified an identical tree; the closing pair covers
  them.
- **The real test:** the census (this file) and the rewritten `CONTEXT.md`
  agree — ten builders, five gates in the same order with fatigue disabled,
  seven live AI sites — and every `CONTEXT.md` claim traces to a named
  symbol in the census tables.
- The contradictions list is non-empty (nine items), as the plan predicted
  it must be.

## Deviations from the plan

- **Part 4's "the `NEXT.md` row of the role table" doesn't exist** — the
  role table's rows are Planner/Implementer/Approver. The rule went to the
  two places that actually define `NEXT.md`'s semantics: cycle step 6 and
  the Decisions paragraph that names it a mutable pointer. Same effect,
  honest placement.
- **Part 1's commit is the report file itself** — the plan forbids doc edits
  in part 1, so there was nothing else to commit; the census was written
  into the report first and committed before any derived doc changed, which
  also timestamps ground truth ahead of its consumers.
- Otherwise none; all four parts shipped at described scope, including
  dropping the drift warning (part 2's conditional), since part 3 shipped in
  full.

## Noticed but not done

- **`CLAUDE.md`'s core-loop sentence is itself stale** — "(event-block
  reminders, morning prompt, idle, get-ahead, floater check-in)" names five
  of ten builders, one retired. The cycle's constraint was "CLAUDE.md gains
  one rule and nothing else," so it stands; it's contradiction #8 in the
  census and a one-line fix for a future cycle.
- **Four undocumented dead profile toggles** (evening check-in, wind-down,
  habit reminder, monthly check-in) — write-only fields with no tombstone
  comment, unlike `deadlinePrepNotificationsEnabled` which is documented.
  Out of scope (Swift); reported in the census.
- **`ClaudeService.generatePrepPlan` is dead code** (comment-only caller).
  Out of scope (Swift); left alone.
- **`DESIGN.md`'s "exactly two AI touchpoints"** — Roman's uncommitted
  working copy already revises it to four; the census counts seven live
  sites. Not touched (his file, this cycle explicitly); the census is the
  reference whenever that edit lands.

## Open questions

- **Who regenerates the ⚙ sections when the stamp ages without any
  builder/gate/AI change?** The part-3 rule fires on drift-causing changes;
  slow rot (renamed constants, retuned values) has no trigger. A cheap
  option: a periodic "re-census" item whenever the stamp is >N cycles old —
  planner's call whether that's worth a standing rule.
- **Cleaner mechanism considered and not built** (per the plan's invitation):
  having Claude Code append a `**Status: complete**` line to `NEXT.md` at
  report time would make completion visible in the file itself — but it
  gives a second party write access to `NEXT.md`, exactly what the plan
  rules out. The reader-side rule was implemented instead; noting the
  alternative here for the record.
