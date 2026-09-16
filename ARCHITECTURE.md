# Nudge — Architecture Map

A file-level map of the project. Each entry is one responsibility + key
relationships + any rule you must not break. History and rationale live in
`docs/plan/reports/` and git — not here. The arbiter's builder/gate/AI-site
census lives in `docs/plan/CONTEXT.md` and is stamped against a commit; for
"what does the arbiter do", that file outranks this one.

## Data flow (overview)

1. **User input** — brain dump in `HomeTabView` chat, task edits in `TasksTabView`, calendar/screenshot import.
2. **Parsing** — `ClaudeService` turns free text into structured tasks/events (capture on Opus 5, everything else Haiku); deterministic helpers (`DurationModel`, `EisenhowerScorer`, `StartByPlanner`) score/estimate without the LLM.
3. **SwiftData** — items persist as `@Model`s in the app-group container from `SharedModelContainer`.
4. **Enrichment** — `NudgeIntelligence` caches per-task AI signals; `DayPlanEngine` (deterministic) or `DayPlanRefiner` (AI, Pro-gated) place tasks onto today's timeline.
5. **Arbiter** — on data change / foreground, `NudgeArbiter.reevaluate` reads data, applies gates, decides which notifications should exist.
6. **Notifications** — the arbiter registers every request; `NudgeNotificationService` handles taps/actions and writes `NudgeOutcome`; untouched nudges are resolved later by `NudgeOutcomeClassifier`.
7. **Sessions** — `SessionCoordinator` runs focus sessions and drives `LiveActivityManager`.
8. **Widgets** — the extension reads the shared store; App Intents write completions back.
9. **Feedback loop** — `NudgeOutcome` (behavioural `result` + independent explicit `feedback`, 👎 only) and `CategoryDurationStats` feed future decisions. **Outcome data is RECORDING ONLY**: `fatigueGateEnabled` is false and nothing reads `feedback` yet.
10. **UI never schedules notifications directly** — it mutates data and calls the arbiter.

---

## Cross-cutting invariants

Four things you cannot reconstruct from any single file. Read these first.

### 1. Ordered plans: stated order outranks Eisenhower score

`NudgeTask.sequenceIndex` (1-based, nil = not in a plan) is a numbered,
reorderable list — **never a placement**. At every "what should I start?"
decision point the plan's next item wins over score. The rule is built into
`TaskSortComparator` (`Nudge/Models/NudgeTask.swift`, both targets) — plan
tasks are bucket 0 — so comparator consumers get it for free. Two sites
implement the override themselves, deliberately: `floaterTargets` (collapses
to plan-next AFTER its placed-on-fire-day exclusion) and
`DayPlanEngine`/`DayPlanRefiner` (plan tasks lead, then today's intents,
then `planScore` order). **One active plan at a time:** a new ordered plan
from capture clears `sequenceIndex` on all surviving tasks first.
`sequenceIndex`, `plannedStartDate`, and `intendedDate` are mutually
independent.

### 2. Schema registration: three lists, synced by hand

Adding or removing a `@Model` requires editing three lists; a mismatch is a
**runtime crash**, not a build error:

| List | Location |
|---|---|
| `SharedModelContainer.schema` | `Nudge/Services/SharedModelContainer.swift` (the app) |
| `widgetSchema` | `NudgeWidget/NudgeWidget.swift` (widget re-declares its own schema/container) |
| `#Preview` container | `Nudge/ContentView.swift` (previews only) |

### 3. Target boundaries are directory boundaries — with one hand-kept exception list

File-system-synchronized groups: a `.swift` file dropped in `Nudge/` or
`NudgeWidget/` auto-joins that target. The widget additionally compiles all
of `Nudge/Models/`, `SharedModelContainer.swift`, and `NudgeTheme.swift` via
a **hand-maintained `membershipExceptions` list in `project.pbxproj`** — and
nothing else from `Nudge/` (no `NudgeConfig`, no services). A NEW file under
`Nudge/Models/` is invisible to the widget until added to that list; the
failure mode is a widget-only build error naming the missing type.

### 4. NudgeOutcome lifecycle

`NudgeArbiter.cancelAll` runs on every reevaluate. Its deletion rule:
**future** pending rows are deleted (they mirror requests just cancelled);
**past** pending rows are kept (the only evidence a nudge fired — the
classifier resolves them); anything older than 14 days is deleted. A row
leaves `pending` exactly once: synchronously via `NudgeNotificationService`
(tap/dismiss) or later via `NudgeOutcomeClassifier` on foreground (`.acted`
/ `.engaged` / `.ignored` from the response window).
`outcomeClassificationGraceMinutes` **must stay greater than**
`outcomeActionWindowMinutes` so no window is judged before it closes.

- **`.ignored` is meaningless for kinds whose success needs no app open**
  (event blocks, dueSoon). `NudgeOutcomeKind.successIsObservableInApp` marks
  them; every fatigue consumer must skip their rows. Correctness exemption,
  not policy.
- **Two columns, two signals:** `result` is behavioural; `feedback` is
  explicit opinion (👎 only), written by `recordFeedback`, which leaves
  pending rows pending and doesn't stamp `AppOpenLog`. A row can be
  `.acted` + `markedUnhelpful` at once.
- **One `NudgeOutcomeKind` per feature — the kind IS the analytics
  identity.** Two builders sharing a kind produce unmeasurable rows. Kind
  changes are additive; old rows keep their raw values (`getAhead` survives
  as a legacy case).
- **New-kind checklist:** the enum, `successIsObservableInApp` (exhaustive
  switch — compiler-checked), and if it has buttons `NudgeNotificationCategoryID` + the array passed to
  `setNotificationCategories` (**not** compiler-checked). Tap routing
  special-cases `.morningPrompt` only; everything else falls through to the
  Tasks tab.
- Past-due rows surviving means one `notificationID` can match several
  rows; the delegate takes the newest still-pending match.

---

## App entry & root views

- `Nudge/NudgeApp.swift` — `@main`: container, notification delegate, background refresh, `StakesBackfill` kickoff. DEBUG launch dumps: `TEMP-STAKES-DUMP` and `TEMP-INTENT-AUDIT` (proposes deadline-vs-intent for old rows; prints only, never writes).
- `Nudge/ContentView.swift` — Root router (onboarding vs `MainTabView`); deep links, scene phase, the debounced `reevaluate`, and the foreground sweep (`AppOpenLog` stamp → classifier → DEBUG dump). Foreground ordering: purge → `PlacementRollover` → `ExamPrepSweep` → `PlanProposalSweep` (async) → arbiter → calendar refresh (Apple rolling window or the daily iCal re-fetch) → auto-plan → arbiter again if placed.
- `Nudge/Views/Tabs/MainTabView.swift` — Tab shell; reacts to `deepLinkTab`; consumes the one-shot post-onboarding land-on-Goals flag.
- `Nudge/NudgeTheme.swift` — Every color + Lexend font; **compiled into the widget too** (`WidgetColors` aliases it — never hand-copy values). Owns the day-slot tints: `daySlotFills`/`daySlotAccents` (six pairs, wrapped lookup), `eventSlotFill`/`Accent`, and computed `…Completed` variants (mixed 72% toward grey — a finished row recedes but stays matchable to its block). Slot tints are deliberately light and fully opaque: wayfinding, never urgency — `overdue`/`coral` alone mean urgency.
- `Nudge/NudgeFeedback.swift` — Haptics, animation constants, and the completion-effect system (`.taskCompletionEffect`, `.checkboxBounce`, strikethrough, particles).
- `Nudge/Views/MainAppMockView.swift` — Dead shim (`typealias` to `MainTabView`).

## Tabs

- `Nudge/Views/Tabs/HomeTabView.swift` — Brain-dump chat → `ClaudeService.sendChat` → task writes → arbiter. Owns plan supersession and the capture write rules: **DUE vs START** (`dueKind: "deadline"` → `dueDate`/`specificTime`; anything else with a date → `intendedDate` + manual placement when a time was stated + 1-hour default length via `NudgeConfig.defaultTimedIntentMinutes`); timeless events stay events; floaters require `!isEvent` and no date; a bare due date resolves to **23:59, not midnight**. `isPlanIntent()` routes "plan my day"-shaped messages to `DayPlanRefiner` instead of capture. The STUDY PLAN question (cycle 2026-09-16-01): a dated exam with no user study task ends the reply with "Want me to build a study plan for X?" (`plan_question`, recorded in `PlanQuestionStore` so the one-word answer routes to capture); the answer (`plan_consent`) runs `PlanProposalSweep.requestPlan` on Yes or records a No. Every model-returned item that doesn't become a row is logged with a reason and reconciled (`CAPTURE: returned/inserted/dropped`); the post-insert save is a real do/catch that tells the user on failure. The catch's error copy states only what's known — the sole throwing call precedes every insert, so an error bubble means zero tasks were created.
- `Nudge/Views/Tabs/TasksTabView.swift` — The biggest file. Layout: header → `TasksMessageBox` → Today row (label + compact Plan my day capsule + Clear plan; Sep 2026) → timeline → Start Session full-width at 38pt (the active-session banner keeps its taller live-content form) → tab strip → one list at a time. Four tabs: **Unscheduled** (open tasks not placed today; includes stale non-today placements so nothing vanishes; prep tasks collapse per exam), **Today** — since cycle 2026-09-04-01 THREE day-lenses (Today / Tomorrow / This week chips, the `EventLens` pattern, not persisted). Membership is day-based: `scheduledDay(of:)` = intent day ?? placement day; deadline-only tasks stay in Unscheduled (owed ≠ scheduled); a dateless plan task reads as today. Each lens shows its day's EVENTS (via `EventRowView`, no routine detection) between the plan rows and the task rows. Today keeps the reorderable plan + slot tints + Plan-my-day empty state; Tomorrow's plan rows are numbered but static (a sequence spanning days can't be reordered from one day's slice) and untinted; This week groups days +2..+7 under `eventDayHeader` headers. `movePlanTasks` drags today's slice with global renumbering (today leads; other days keep their relative order). **Events** (two lenses: This week ≤7 days, Important = high stakes), **Overdue** (past due, open, `stakes != .low`; red badge). Day-lens task rows sort by `plannedStartDate`, not the comparator — the list must read in the same order the strip above draws. Completed rows sink to the bottom with greyed tints; `scheduledTasks` builds off `actionableTasks` so completed placements stay visible. `movePlanTasks` renumbers by display order. `planMyDay()` delegates to `DayPlanEngine` as a replan; `clearPlan()` is the undo — deliberately separate. `TaskEditorSheet` has a Duration chip section (writes `estimatedMinutes`, guarded by `durationUserPicked`; a hand-set EVENT duration also feeds `BusyWindowResolver.recordDuration`) and, since cycle 2026-09-13-02, the **intent-aware shared `apply(draft:to:modelContext:)`** — the one draft-application used by the Tasks tab AND the calendar view: an intent-only task's date picker (labeled "Planned"; events "Time"; deadline tasks "Due") moves `intendedDate` + the placement when a time is chosen and can never mint a deadline; the draft seeds from intent+placement. The `.create` path still writes deadline fields at its own call site — fold into `apply` when the convert-kind default gets decided. Intent-only rows show a muted day label — never a countdown or urgency color.
- `Nudge/Views/Tabs/CalendarTabView.swift` — **The Nudge calendar** (cycle 2026-09-13-02) + calendar connect + screenshot import. The month view is a read-only glance over everything in the store carrying a day — events (stone dot), scheduled tasks (blue, via the shared `NudgeTask.scheduledDay`), and deadline tasks (amber "Due" — included here though day lenses exclude them; an orientational surface omitting the essay due Friday would read as broken). Pure display, downstream of the store, never an AI input (Roman's constraint). Tap an item → the shared `TaskEditorSheet` with the intent-aware `apply`. Import half: the link source is generic "Calendar Link (iCal)" — Canvas, Google, Outlook, any `.ics` through one path — with an in-UI format note and a Check Link dry-run sharing the import's exact validation; legacy "Canvas iCal" values map forward via `normalizedSource`.
- `Nudge/Views/Tabs/StatsTabView.swift` — Reads `DailyStats` / `CompletedTaskRecord` / `EngagementState`.
- `Nudge/Views/Tabs/SettingsTabView.swift` — Edits `UserProfile`; changes reach the arbiter via `ContentView.notificationToken`. Hosts the DEBUG sections (entitlement overrides, classifier harness).
- `Nudge/Views/Tabs/GoalsTabView.swift` — Active `NudgeGoal`s with add/edit/remove; subtitle from `lastActivityAt` with the deliberate "Set N ago" zero case — never a false lapse.
- `Nudge/Views/Tabs/AccountTabView.swift` — Plan (Pro/trial) status from `UserProfile`.

## Onboarding

- `Nudge/Views/Onboarding/OnboardingCoordinatorView.swift` — Drives the step sequence; owns `OnboardingViewModel`.
- `Nudge/Views/Onboarding/OnboardingViewModel.swift` — Draft state → `UserProfile`/habits/goals on completion.
- `Nudge/Views/Onboarding/OnboardingChatShell.swift` — Chat-style shell for each step's mascot dialogue.
- `Nudge/Views/Onboarding/OnboardingMessage.swift` — One onboarding chat message.
- `Nudge/Views/Onboarding/SplashView.swift` — Launch splash.
- `Nudge/Views/Onboarding/WelcomeStepView.swift` — Name/intro step.
- `Nudge/Views/Onboarding/WakeUpStepView.swift` — Wake time → `UserProfile`.
- `Nudge/Views/Onboarding/BedtimeStepView.swift` — Bedtime → `UserProfile`.
- `Nudge/Views/Onboarding/RoutineStepView.swift` — Routines → `NudgeHabit`s.
- `Nudge/Views/Onboarding/GoalsStepView.swift` — Goals → `NudgeGoal`s.
- `Nudge/Views/Onboarding/CoachingStyleStepView.swift` — Tone → `UserProfile`.
- `Nudge/Views/Onboarding/CalendarImportStepView.swift` — Optional calendar connect.
- `Nudge/Views/Onboarding/OnboardingCompleteView.swift` — Notification permission + completion flag.
- `Nudge/Views/Onboarding/Components/` — `ChatBubbleView`, `MascotAvatarView`, `TypingIndicatorView`, `OnboardingProgressBar`.

## Components

- `Nudge/Views/Components/AppTabBar.swift` — Floating tab bar; morphs into a send button via `ChatComposerStore`.
- `Nudge/Views/Components/CountdownLabel.swift` — App-side renderer of `CountdownState`; used by rows and the editor.
- `Nudge/Views/Components/ScreenHeader.swift` — Reusable tab header.
- `Nudge/Views/Components/TasksMessageBox.swift` — The read-only message surface at the top of the Tasks tab — **the app's only place to speak**. Display-only (Home owns capture); works offline because every AI message here has the deterministic ladder as its fallback. `TasksMessageComposer.compose` is a first-match priority chain: tapped-nudge explanation → overdue → high-stakes approaching → prep-tombstone note → prep announcement → commitment announcement → goal invite → AI Refine rationale → resting (never blank). One-time states are consumed on first RENDER (equality-checked statics) with freshness windows so they don't vanish mid-read. An `aiMessage` seam runs ahead of every deterministic state — used by the goal-lapse hook (live `generateGoalLapseHook`, per-goal-per-day cached; deterministic fallback until it lands). **A plan proposal** (`planProposal:`, cycle 2026-09-16-01) sits above the memo and below the tapped nudge and one-time news: Opus's sentence as headline, a deterministic session summary as detail, Yes / No capsules (rendered by equality against `planProposalMessage`); `onAnswerPlanProposal` hands the answer to the Tasks tab. **The Opus memo** (Sep 2026, `memo:`) sits just below it: the box's standing voice, written by `ClaudeService.generateTasksMemo` from `TasksMemoContextBuilder` (open tasks, today/tomorrow events, goals, 7-day completion habits, every date pre-phrased), cached by `TasksMemoCache` per (day, SHA-256 fingerprint of those facts) with a `tasksMemoMaxPerDay` cap; it yields to any pending one-time news so those still render once, and replaces overdue / approaching / rationale / invite / resting. Both goal states carry a one-tap accept that creates a small undated goal-linked task. Tapped-nudge context arrives via app-group keys written by `NudgeNotificationService`, freshness-windowed rather than one-shot. `MessageBoxChatShell` is **read-only by ruling** (talk only, no input — the prototype's reply options, text field, and corner bubble were removed Sep 2026); it shows the composed message in full. `MessageBoxExpression.image` is the one mapping real mascot art lands in.
- `Nudge/Views/Components/TodayTimelineView.swift` — Horizontal day timeline (events, placed tasks, now-line; the pending-nudge markers under the axis were removed Sep 2026 — the strip shows the day's shape, not when the app will speak — and the strip shrank from 156 to 108pt, which is what moved Start Session up); mutation goes through callbacks to `TasksTabView`. The task `@Query` is **bounded in a custom init** (300) because the view re-reads on every 60s tick. Empty-space tap gesture lives on the container (parent gestures lose to child buttons). Event lengths come from the shared `NudgeTask.eventDurationMinutes(in:)` so the drawn block and the busy window can't disagree. Task blocks are slot-tinted from the `slots` map passed in by `TasksTabView` (see `DaySlotPalette`); events take the one stone tint; completed blocks use the greyed variants at 0.75 opacity. **Two windows** (Sep 2026): the BASE window (wake−30m → bed) bounds task placement — empty-space taps clamp into it — while the RENDER window additionally stretches to cover every one of today's events, so an early shift or late event draws at its real time instead of being silently clipped. Tasks outside the day's bounds are a deliberately deferred question.

## Services

- `Nudge/Services/SharedModelContainer.swift` — App-group `ModelContainer` + shared `UserDefaults` (use `appGroupDefaults`; never construct `UserDefaults(suiteName:)` inline). Compiled into both targets but only the app uses it (invariant 2).
- `Nudge/Services/ClaudeService.swift` — All Anthropic calls. **Per-call-site model tiering** (cost rule): `captureModel` = Opus 5 (adaptive thinking on by default; server-side refusal fallbacks; response parsing selects the first TEXT block because thinking blocks lead the array) and `memoModel` = Opus 5 at effort low for the daily Tasks-tab memo (`generateTasksMemo`, `TasksMemoContext`) and the plan reader (`proposePlans`: batched candidates → per-item verdict + sessions, JSON array, ids filtered to what was asked) — everything else `model` = Haiku. `ClaudeResponse` carries optional `plan_question` / `plan_consent` for the capture-side study-plan ask. The dead `generatePrepPlan` endpoint is gone (Sep 2026). The brain-dump `chatSystemPrompt` is a **behavioral contract**: task-vs-event classification, DUE-vs-START (`dueKind`), ordered plans (order suppresses inference, never stated information), capture-first, commitment shapes with exactly two permitted follow-ups, span→`estimatedMinutes` computation, floater rules, and a generated 21-day weekday→date table (the model must never compute "next Thursday" itself). `stakesRuleText` is the single stakes definition, shared with `classifyStakes` (which matches responses by index and requires exact coverage — truncation is otherwise undetectable). Parse layer logs every discarded fragment (extra blocks, content outside the first balanced JSON object, missing `new_tasks` key). **Edit this prompt carefully; it defines app-wide capture behavior.** The legacy `send()` path still carries a contradictory "default dueDate to today" line — known stale, queued.
- `Nudge/Services/NudgeIntelligence.swift` — Cached per-task AI signals (`TaskIntelligence`, 7-day TTL, single-flight); read synchronously by arbiter/scoring.
- `Nudge/Services/NudgeArbiter.swift` — The decision engine; the only scheduling site. **The census in `docs/plan/CONTEXT.md` is the authority on its ten builders, five gates, and their anchors** — this entry keeps only the standing rules. Every reevaluate: cancel owned requests (IDs `nudge.arb.`, tracked synchronously in App Group defaults — never via async `pendingNotificationRequests()`), rebuild candidates, gate, pick winners. **Every gate reads the candidate's fire date, never `now`.** Budget-exempt kinds (event blocks, morning prompt, dueSoon) bypass the shared gates and must self-gate in their builders, per-kind toggle included. Discretionary fire times are wake-anchored offsets with a shared rollover idiom (`if fireDate <= now`, add one day); prep generalizes it to a bounded walk that stops at the deadline. Floater targeting: no deadline AND no fire-day-or-future `intendedDate` AND not placed on the fire day; collapses to the plan's next item. Morning prompt: names the day's biggest task by reading `stakes` directly (never through the scorer), steps aside after `morningPromptMaxConsecutiveDays`, repeats rather than downgrading more than one stakes tier, `taskID` deliberately nil (attribution rides `namedTaskID`). Each behavior-changing cycle keeps a `debug*Impact` before/after dump — use them (work-order item 5).
- `Nudge/Services/NudgeConfig.swift` — Every tunable constant. Change behavior here, not inline.
- `Nudge/Services/NudgeCopyService.swift` — AI nudge copy generated AHEAD and cached (App Group JSON blob, 3-day validity) because iOS fixes text at scheduling time. **The arbiter only reads it, synchronously** — body-only swap, validated per read (age, task still open, deadline unchanged); any miss falls back to the deterministic template. eventBlock and dueSoon are never generated (their bodies embed exact clock times). Generation triggers: first foreground of a day, calendar import, prep sweep; throttled by day marker + min-gap + daily cap.
- `Nudge/Services/EisenhowerScorer.swift` — Pure urgency×importance + quadrant. `importance` accepts an optional `stakes:` term that **no production call site passes** (work-order item 1 — do not arm). `explicit` urgency + positive stakes are capped as a pair (`stakesSignalCombinedCap`); `.low`'s negative term sits outside the cap.
- `Nudge/Services/StartByPlanner.swift` — Recommended start-by + deep-work classification. **`startBy` answers WHICH DAY, not what time** — both branches inherit the deadline's clock time. `prepFireDate` re-anchors it; never use `startBy` directly as a fire time.
- `Nudge/Services/DurationModel.swift` — Deterministic effort estimate (category prior + learned stats).
- `Nudge/Services/BusyWindowResolver.swift` — Event busy windows (+buffers, merged) and `dayLoad` (day-fullness; events only, placements excluded; nil only on a degenerate sleep window). `recordDuration` writes the learned per-title event duration; its sole caller is the editor's save path.
- `Nudge/Services/DayWindow.swift` — **The one derivation of a day's planning window** (wake+30m → bed−60m, wake-anchored so past-midnight bedtimes work). Derive the window here or not at all — three drifted inline copies caused the bug that created this file.
- `Nudge/Services/DayPlanRefiner.swift` — AI layer over Plan-my-day; writes only placement fields, never notifications. Pro/trial gated, cached daily unless forced. Runs from Home chat's plan intent.
- `Nudge/Services/PlanProposalSweep.swift` — **Plan proposals** (cycle 2026-09-16-01, Roman's realignment): for a due-dated task or event worth preparing for, the app builds the steps and asks. The READER (`runIfNeeded`) picks anchored candidates deterministically (inside `planProposalHorizonDays`, no decision for the current anchor, no user study task by title match, no existing sessions), sends one batched Opus call (`ClaudeService.proposePlans`, capped per day), and stores verdicts in `PlanProposalStore` (app-group JSON keyed on the anchor's day; a moved anchor voids them). The WRITER (`accept`) runs only on the user's Yes: one `NudgeTask` per session, **scheduled (`intendedDate`), never due** (the two-clock rule; only the parent is owed), `source = "prep"`, `linkedEventId` = parent, tombstone-aware and idempotent. `requestPlan` is the chat-consent path (builds rather than judges, writes at once, announces); `PlanQuestionStore` holds the chat's outstanding "want a study plan?" for the day. Runs after `ExamPrepSweep` in both foreground chains, after a capture, after either import. No key: nothing proposed, nothing written.
- `Nudge/Services/ExamPrepSweep.swift` — Since cycle 2026-09-16-01 the exam half **no longer creates study tasks** (a study plan is proposed by `PlanProposalSweep` and written on the user's Yes). What stays: the shared machinery — `userStudyTaskMatch` (the user's own study task always wins), the (parent, day) stamps, `PrepTombstone`, the announcement — and the commitment half, which expands captured commitments (`commitmentPhase`: shape + answered numbers → `NudgeCommitment` row + dailies; the parent capture task is deleted). Idempotent by (parent, day-stamp); `PrepTombstone` blocks recreation of user-deleted days (stamp = `dueDate ?? intendedDate`). Commitment dailies are still due **23:59 of their own day** (`sessionDueDate`); plan sessions are not. Start-day (today vs tomorrow) is decided app-side from room/growth arithmetic — the model only maps the user's answer. Split work generates once (front-loaded, half-hour blocks); rate/quantity top up a rolling 14-day window; quantity carries missed units forward, capped. Runs on launch/scene-active before the arbiter, and after capture turns.
- `Nudge/Services/DayPlanEngine.swift` — **The deterministic planning engine, day-parameterized** (cycle 2026-09-13-03): `plan(day:)` is the primary, `planToday` delegates. Window via `DayWindow.resolve(on: day)`, fills gaps around that day's events/placements (1h pre-event buffer), max 4 placements (≤2 generated), 15-min spacing, never overwrites a manual placement; band bounds use the planning day's hours and weekend-ness. Candidate order: plan tasks whose plan-day is this day (dateless plans are today's only) → **tasks intended for this day** (the user decided the day; the planner places, it doesn't re-decide) → score-ranked, excluding anything that *belongs elsewhere* (a still-ahead intent on a different day; slipped intents are fair game, deadline work stays eligible early). Generated dailies place only on their own day. **Staleness rule:** future-day placements are marked `plannedIsAuto = false`, so that day's morning auto-run respects them and refills remaining gaps — respect + refill, never silent deletion; displacement (≤1 strictly-lower-stakes auto eviction) is today-only. Doors: Plan my day (Today row), "Plan tomorrow" (Tomorrow lens), "Plan this day" (future calendar day). `autoPlanIfNewDay` runs once per calendar day on first foreground (marker stamped even on refusal). Zero AI anywhere in this file.
- `Nudge/Services/NotificationScheduler.swift` — **Retired as a scheduler.** Survives only for the shared session-start key and the one-time cleanup of old `nudge.daily.*` repeating requests. Do not add scheduling back.
- `Nudge/Services/NudgeNotificationService.swift` — Notification delegate: tap/action routing + `NudgeOutcome` write-back (body taps write `.tappedOpen`; `.tappedStart` is the explicit Start action). Durable-intent pattern: cold launches can't rely on transient posts, so tap context is written to app-group keys (idle "Not yet"; which-nudge-was-tapped for the message box, freshness-windowed). `pickTopOpenTask` is plan-first.
- `Nudge/Services/NudgeNotificationCategories.swift` — All `UNNotificationCategory` definitions. Every category carries `.customDismissAction` (without it `.dismissed` never fires). The 👎 feedback action is non-`.foreground` (rating must not stamp `AppOpenLog`) and always listed last (iOS renders max four actions). `.eventBlock` is deliberately actionless. **The array passed to `setNotificationCategories` is not compiler-checked** — omit a category and its buttons silently vanish.
- `Nudge/Services/NudgeOutcomeClassifier.swift` — Foreground sweep resolving delivered-untouched rows (invariant 4). Owns the DEBUG 7-day dump (by-kind breakdown iterates `allCases` so silent kinds show as `—`). Split into `sweepableRows` + `resolve` so the harness can drive each.
- `Nudge/Services/NudgeOutcomeClassifierHarness.swift` — **DEBUG only.** Seeds backdated rows, runs the real `resolve`, prints expected-vs-actual, cleans up. Uses `debugResolve` on its own rows — never `classifyPending` — because the classifier's shared-state inputs would judge the user's real pending rows against fake state, permanently.
- `Nudge/Services/AppOpenLog.swift` — Capped app-foreground timestamps in App Group defaults, solely so the classifier can answer "was the app open in this window". Deliberately not a `@Model` (schema list + hot-path fetch) and not `EngagementState` (single overwritten value).
- `Nudge/Services/CalendarService.swift` — Apple Calendar / iCal-feed import (Canvas, Google, Outlook — any `.ics`; `webcal://` rewrites to https; non-iCal content is rejected with a format message instead of importing zero). Both doors import to `NudgeConfig.calendarImportHorizonDays` (180; cycle 2026-09-16-01): Apple Calendar extends one day per day past the `calendarSyncedThrough` cursor, and the iCal feed refreshes once a day (`refreshICalFeedIfNeeded`, stamped) instead of being a one-time 30-day snapshot. Fully deterministic — `inferStakes` and real durations stamped with **no AI call**; import cost is zero tokens by design.
- `Nudge/Services/ScreenshotCalendarImporter.swift` — Vision OCR → `ClaudeService` → events. Dedupe is same-day + same-title (start time ignored — known open bug: drops the second shift of a double).
- `Nudge/Services/LegacyPriorityNormalizer.swift` — One-shot idempotent fold of retired `"urgent"` priority into `"high"`.
- `Nudge/Services/PlacementRollover.swift` — Day-rollover sweep clearing placements dated before today, **manual included** (a placement is a slot on one specific day). Keeps the invariant: a non-nil placement is always today-or-later. Runs before the arbiter on launch/scene-active.
- `Nudge/Services/StakesBackfill.swift` — One-shot AI repair of stakes on existing rows (never-classified + calendar-stamped). **Atomic** — any failure abandons the pass with nothing written. Never touches `stakesIsUserSet` rows; writes via `setStakesFromAutomation`. `.dryRun` prints and writes nothing, repeatable.
- `Nudge/Services/SessionCoordinator.swift` — Runs a focus session (state, timers, widget publish); drives `LiveActivityManager`; calls the arbiter.
- `Nudge/Services/LiveActivityManager.swift` — Focus-session Live Activity lifecycle.
- `Nudge/Services/CountdownClock.swift` — Single 60s ticker publishing `now`.
- `Nudge/Services/EngagementTracker.swift` — App opens, streaks, escalation → `EngagementState`.
- `Nudge/Services/ChatComposerStore.swift` — Bridge between the Home composer and the tab-bar send button.
- `Nudge/Services/FocusSessionIntents.swift` — Focus-session App Intents, **app-target copy** — a separate widget-target copy exists in `NudgeWidget/`. Check which you're editing.

## Models (SwiftData `@Model` unless noted)

- `Nudge/Models/NudgeTask.swift` — The central task/event record. **Three independent scheduling concepts:** placement (`plannedStartDate`/`plannedDurationMinutes`/`plannedIsAuto` — a slot on a specific day), plan order (`sequenceIndex`, invariant 1), and intent day (`intendedDate` — the day the user means to do it, never a deadline; survives its day passing; never on events). None implies another; none touches `dueDate`/`specificTime`, which mean **only owed work** — capture writes them solely on `dueKind: "deadline"`, and `hasDeadline` is the one-word read-site question. Countdown, overdue, dueSoon, and urgency all key off deadline fields, so an intention cannot fabricate time pressure. Owns `eventDurationMinutes` (explicit → learned `EventDurationStats` → 60-min fallback; two overloads, the `(in:)` one for hot paths), `sortDeadline`/`isOverdue`, and `TaskSortComparator` (plan-first built in; lives here so the widget compiles one copy). Stakes: `stakesRaw`/`stakes` + `stakesIsUserSet`; every automated writer must use `setStakesFromAutomation` (absent from the init on purpose), which refuses to overwrite a hand-set value. Also: `prepLeadDays` (3/7/14 band, exam events only), commitment fields (`commitmentShapeRaw`/`commitmentDailyCount` mark a parent for expansion; `targetCount`/`completedCount`/`carriedCount` for quantity tasks — one task with a count, completes at `effectiveTargetCount`), and `commitmentStartDate`/`commitmentStartAskedAt`.
- `Nudge/Models/UserProfile.swift` — Settings (wake/bed, toggles, Pro/trial). **One per-kind toggle per notification feature** — never share a switch across two features. A new non-optional field needs a **property-level default** (no `VersionedSchema`; a defaultless attribute fails at launch, not build). A new toggle must also be added to `ContentView.notificationToken` or flipping it never reevaluates. Quiet hours are their own fields (default to the sleep schedule, no longer derived from it); the legacy `quietHoursStart`/`End` Ints are dead — do not reuse.
- `Nudge/Models/NudgeOutcome.swift` — Notification audit log; see invariant 4 for the lifecycle, the two columns, and `NudgeOutcomeKind` (which lives here with `successIsObservableInApp`).
- `Nudge/Models/PrepTombstone.swift` — Durable "user deleted this generated day" record, per (parent, day); the sweep never recreates a tombstoned day. Parent fields serve both exam and commitment rows. In all three schema lists + the widget exception list.
- `Nudge/Models/NudgeCommitment.swift` — Anchor for an expanded commitment: shape, end date, answered numbers (`totalMinutes` is the remembered size that stops re-asking), carry accumulator. **Never purged at end date** — an expired row generates nothing but keeps its answer. All three lists + widget.
- `Nudge/Models/TaskIntelligence.swift` — Cached AI signals per task; written by `NudgeIntelligence`.
- `Nudge/Models/DaySlotPalette.swift` — NOT a `@Model`: assigns day slots (timeline order first, then unplaced plan tasks) for the color coordination. Pure ordering; colors live in `NudgeTheme`. **One caller per target owns the assignment** (app: `TasksTabView`, passed down; widget: its own matching narrow fetch) — a task missing from the input shifts every slot after it and colors stop matching. Ties break on `id`; completed tasks keep their slot. In the widget exception list.
- `Nudge/Models/CountdownState.swift` — NOT a `@Model`: the pure countdown/date-line state machine, shared with the widget (one copy; `WidgetCountdownFormatter` delegates). In the widget exception list.
- `Nudge/Models/StatedUrgency.swift` — Enum for language-derived urgency.
- `Nudge/Models/TaskCategory.swift` — Category enum + helpers.
- `Nudge/Models/TaskTimeWindow.swift` — Appropriateness band (`anytime`/`daytime`/`businessHours`). Resolution is **read-time** via `effectiveTimeWindow` (explicit ?? inferred) — stored values stay exclusively what the classifier said. The deterministic `infer` is conservative: a wrong `businessHours` blocks placement; a wrong `anytime` is invisible. Consumed by `DayPlanEngine`.
- `Nudge/Models/TaskStakes.swift` — high/medium/low consequence signal; tolerant `parse`, nil = never classified (no catch-all). Data-only: nothing in scoring consumes it yet (work-order item 1).
- `Nudge/Models/CategoryDurationStats.swift` — Learned per-category effort mean; read by `DurationModel`.
- `Nudge/Models/EventDurationStats.swift` — Learned per-title event duration; written only by `BusyWindowResolver.recordDuration` (sole caller: the editor's save path — a hand-set duration is ground truth).
- `Nudge/Models/TimeBlock.swift` — Retained but unused by any view.
- `Nudge/Models/NudgeGoal.swift` — Personal goal. `lastActivityAt` (nil = never — the load-bearing zero case) is written only through `recordActivity`, the shared forward-only helper both targets call. Tasks link via a soft `goalID`; dangling links read as unlinked.
- `Nudge/Models/NudgeHabit.swift` — Recurring routine with reminder time.
- `Nudge/Models/CheckIn.swift` — Morning/evening check-in record.
- `Nudge/Models/DailySession.swift` — Per-day chat transcript (AI history source).
- `Nudge/Models/DailyStats.swift` — Per-day counters for Stats.
- `Nudge/Models/CompletedTaskRecord.swift` — Completed-task history (weekly, purged on Tasks-tab appear).
- `Nudge/Models/EngagementState.swift` — Streaks/open counts/escalation.
- `Nudge/Models/NotificationEvent.swift` — Notification lifecycle record.
- `Nudge/Models/SentNotificationFlag.swift` — Duplicate-send marker.
- `Nudge/Models/TaskActivityAttributes.swift` / `FocusSessionAttributes.swift` — ActivityKit attributes for the two Live Activities.

## Widgets (NudgeWidget extension)

`NudgeWidget/` is a sibling of `Nudge/` at the repo root.

- `NudgeWidget/NudgeWidgetBundle.swift` — `@main` bundle registering widgets + Live Activities.
- `NudgeWidget/NudgeWidget.swift` — Task widget (**large only** since Sep 2026 — the medium family, its compact header, footer, and goal summary are gone; the large layout's "Goals in motion" strip went the same day and the events row is always rendered with a "No events today" empty state so the height never changes): provider, views, `WidgetColors` (aliases `NudgeTheme` — never redefine values). **Declares the widget's own `widgetSchema`/`widgetModelContainer`** (invariant 2). Rows sort via the shared comparator (plan-first); rows and the mini day chart are day-slot tinted from the shared `DaySlotPalette` via the widget's own narrow slot fetch — a task is the same color here as in the app, and only today-scheduled/plan tasks light up. The hairline divider draws only between two untinted rows.
- `NudgeWidget/NudgeCompanionWidget.swift` — Small mascot widget; edge-to-edge `containerBackground` (a manual `.background` leaves an inset ring).
- `NudgeWidget/NudgeWidgetControl.swift` — Control Center control (template code, not in the bundle).
- `NudgeWidget/NudgeWidgetLiveActivity.swift` — Live Activity configuration (not registered in the bundle).
- `NudgeWidget/TaskLiveActivityView.swift` — Live Activity content view.
- `NudgeWidget/CompleteTaskIntent.swift` — Complete-a-task App Intent (writes the shared store).
- `NudgeWidget/FocusSessionIntents.swift` — **Widget-target copy** of the focus-session intents; the app has its own.
