# Report — 2026-08-05-01 — Make the planner's state files checkable

**Plan:** `archive/2026-08-05-01-plan.md`
**Status:** in progress (Part 1 committed; Parts 2–4 and final verification follow)
**Commits:** `9035ffa` (archive), this file (Part 1 census), then one per part.

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

*Parts 2–4 and final verification are appended below as they complete.*
