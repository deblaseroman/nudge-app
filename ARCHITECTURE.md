# Nudge — Architecture Map

A file-level map of the project. Each entry is one responsibility + key relationships.
This is a map, not documentation — read the files for detail.

## Data flow (overview)

1. **User input** — the user brain-dumps in `HomeTabView` chat, or adds/edits tasks in `TasksTabView`, or imports a calendar/screenshot.
2. **Parsing** — `ClaudeService` (Haiku) turns free text into structured tasks/events; deterministic helpers (`DurationModel`, `EisenhowerScorer`, `StartByPlanner`) score/estimate without the LLM.
3. **SwiftData** — parsed items persist as `@Model`s (`NudgeTask`, `UserProfile`, `NudgeOutcome`, …) in the app-group container from `SharedModelContainer`.
4. **Enrichment** — `NudgeIntelligence` caches per-task AI signals (`TaskIntelligence`); `TasksTabView.planMyDay()` (deterministic) or `DayPlanRefiner` (AI) place tasks onto today's timeline.
5. **Arbiter** — on data change / foreground, `NudgeArbiter.reevaluate` reads the data, applies gates (`BusyWindowResolver`, `NudgeConfig`), and decides which notifications should exist.
6. **Notifications** — `NudgeArbiter` + `NotificationScheduler` register `UNNotificationRequest`s (categories from `NudgeNotificationCategories`); `NudgeNotificationService` handles taps/actions and writes back `NudgeOutcome`.
7. **Sessions** — `SessionCoordinator` runs focus sessions and drives `LiveActivityManager` (Live Activity).
8. **Widgets** — the widget extension reads the shared store and renders task/companion widgets + Live Activities; App Intents write back completions.
9. **Feedback loop** — `NudgeOutcome` (tapped/ignored) and `CategoryDurationStats` feed future scoring/estimates.
10. **Reevaluation is data-driven** — UI never schedules notifications directly; it mutates data and calls the arbiter.

---

## Cross-cutting invariants

Three things you cannot reconstruct by reading any single file. Read these first.

### 1. Ordered plans: stated order outranks Eisenhower score

`NudgeTask.sequenceIndex: Int?` is a 1-based position in the user's stated plan
("first X, then Y, then Z"); nil means the task is not in a plan. A plan is a
**numbered, reorderable list — not a placement**; it never sets a timeline slot.

**At every "what should I start?" decision point, the plan's next item (lowest
`sequenceIndex`) wins over score.** All five sites implement the same override:

- `NudgeArbiter.buildIdleCandidates` — idle nudge targets the plan's next item
- `NudgeArbiter.buildFloaterCheckInCandidates` — check-in points at the plan's next item instead of an arbitrary undated floater
- `NudgeNotificationService.pickTopOpenTask` — notification-tap target
- `DayPlanRefiner` + `TasksTabView.planMyDay()` — plan tasks lead the candidate list in stated order; score-ranked tasks follow
- `NudgeWidget` row sort — plan tasks first, by index

**One active plan at a time.** When a new ordered plan arrives from the brain
dump, `HomeTabView` clears `sequenceIndex` on every surviving task first. Those
tasks are not deleted — they drop back into the normal Unscheduled/Scheduled
sections, and the new plan owns 1,2,3…

`sequenceIndex` is independent of `plannedStartDate`: a task can be numbered in
Today's plan, placed on the timeline, both, or neither.

### 2. Schema registration: three lists, synced by hand

Adding or removing a `@Model` requires editing **three** separate lists. Nothing
enforces agreement — a mismatch is a runtime crash, not a build error.

| List | Location | Scope |
|---|---|---|
| `SharedModelContainer.schema` | `Nudge/Services/SharedModelContainer.swift` | the app's real container |
| `widgetSchema` | `NudgeWidget/NudgeWidget.swift` | the widget's own container — does **not** call `SharedModelContainer`, though that file is compiled into the widget target |
| `#Preview` container | `Nudge/ContentView.swift` | previews only — **already drifted**: missing `CompletedTaskRecord`, `TimeBlock`, `CategoryDurationStats`, `EventDurationStats` |

The widget re-declares its own schema, app-group ID, and `ModelContainer` rather
than reusing `SharedModelContainer`. The only guardrail is a comment in
`NudgeWidget.swift`: *"MUST stay in lockstep with `SharedModelContainer.schema`."*

### 3. Target boundaries are directory boundaries

The project uses Xcode's file-system-synchronized groups: dropping a `.swift`
file into `Nudge/` or `NudgeWidget/` auto-joins that target — no `.pbxproj` edit.

The widget target additionally compiles all of `Nudge/Models/*.swift` plus
`Nudge/Services/SharedModelContainer.swift`, and **nothing else** from `Nudge/`.
So widget code can reach the models but not `NudgeConfig`, `DurationModel`,
`EisenhowerScorer`, or any other service.

---

## App entry & root views

- `Nudge/NudgeApp.swift` — `@main` App: builds the SwiftData container, sets the notification delegate, registers background refresh. Hosts `ContentView`.
- `Nudge/ContentView.swift` — Root router (onboarding vs `MainTabView`); handles deep links, scene-phase, and the debounced `NudgeArbiter.reevaluate`.
- `Nudge/Views/Tabs/MainTabView.swift` — Tab shell owning `selectedTab`; reacts to `deepLinkTab` to switch tabs from notification taps.
- `Nudge/NudgeTheme.swift` — Central colors + Lexend fonts; used by every view.
- `Nudge/NudgeFeedback.swift` — Haptics (`NudgeHaptics`), animation constants (`NudgeAnimation`), AND the completion-effect visual system: `TaskCompletionEffect`, `CheckboxBounceEffect`, `AnimatedStrikethrough`, `ParticleBurstView`, exposed as `.taskCompletionEffect(isComplete:)` / `.checkboxBounce(isComplete:)`. Used by task rows and timeline blocks.
- `Nudge/Views/MainAppMockView.swift` — Dead shim: `typealias MainAppMockView = MainTabView`, kept for backward compatibility after the tab views moved to `Views/Tabs/`. No mock content.

## Tabs

- `Nudge/Views/Tabs/HomeTabView.swift` — Brain-dump chat; calls `ClaudeService.sendChat`, writes `NudgeTask`s, triggers the arbiter. `isPlanIntent()` keyword-matches "plan my day" / "restructure" / … and routes to `handlePlanIntent()` → `DayPlanRefiner.refine(force: true)`, Pro/trial gated. Owns **plan supersession** (clears `sequenceIndex` on surviving tasks when a new plan arrives) and three capture rules: timeless events stay events (*"Previously we demoted timeless events to tasks; that hid genuine plans."*); floater detection requires `!isEvent`; a bare due date resolves to **23:59, not midnight** — otherwise a task "due today" is instantly overdue.
- `Nudge/Views/Tabs/TasksTabView.swift` — The biggest file. Task/event list + `TodayTimelineView`; the **deterministic `planMyDay()` engine** (wake+30 → bed−60 window, fills `BusyWindowResolver` gaps around events and existing placements, 1-hour pre-event "get ready" buffer, max 4 placements, 15-min spacing, never overwrites a manual placement); the numbered drag-reorderable "Today's plan" section (`movePlanTasks` rewrites `sequenceIndex`); `clearPlan()` (removes **only** auto placements); AI Refine; placement/editor/`IdleStartConfirmationSheet`/`SessionTaskPickerSheet`/`WeeklyCompletedSheet`. Also **defines `TaskSortComparator`**, which `NudgeArbiter` and `NudgeNotificationService` both consume — a service-on-view dependency.
- `Nudge/Views/Tabs/CalendarTabView.swift` — Calendar connect + screenshot import; calls `CalendarService` / `ScreenshotCalendarImporter`.
- `Nudge/Views/Tabs/StatsTabView.swift` — Reads `DailyStats` / `CompletedTaskRecord` / `EngagementState` for progress display.
- `Nudge/Views/Tabs/SettingsTabView.swift` — Edits `UserProfile` (wake/bedtime, toggles); triggers `NotificationScheduler` / arbiter on change.
- `Nudge/Views/Tabs/AccountTabView.swift` — Account / plan (Pro, trial) status from `UserProfile`.

## Onboarding

- `Nudge/Views/Onboarding/OnboardingCoordinatorView.swift` — Drives the onboarding step sequence; owns `OnboardingViewModel`.
- `Nudge/Views/Onboarding/OnboardingViewModel.swift` — Holds onboarding draft state and writes it into `UserProfile` / habits on completion.
- `Nudge/Views/Onboarding/OnboardingChatShell.swift` — Chat-style shell wrapping each onboarding step's mascot dialogue.
- `Nudge/Views/Onboarding/OnboardingMessage.swift` — Model for a single onboarding chat message.
- `Nudge/Views/Onboarding/SplashView.swift` — Launch splash shown before onboarding/main.
- `Nudge/Views/Onboarding/WelcomeStepView.swift` — Name/intro step; feeds `OnboardingViewModel`.
- `Nudge/Views/Onboarding/WakeUpStepView.swift` — Wake-time step → `UserProfile.wakeTime` / `morningCheckInTime`.
- `Nudge/Views/Onboarding/BedtimeStepView.swift` — Bedtime step → `UserProfile.bedtime`.
- `Nudge/Views/Onboarding/RoutineStepView.swift` — Recurring routines → `NudgeHabit`s.
- `Nudge/Views/Onboarding/GoalsStepView.swift` — Personal goals → `NudgeGoal`s.
- `Nudge/Views/Onboarding/CoachingStyleStepView.swift` — Coaching tone → `UserProfile.coachingStyle` / `personalityMode`.
- `Nudge/Views/Onboarding/CalendarImportStepView.swift` — Optional calendar connect during onboarding; calls `CalendarService`.
- `Nudge/Views/Onboarding/OnboardingCompleteView.swift` — Final step: requests notification permission, marks onboarding complete.
- `Nudge/Views/Onboarding/Components/ChatBubbleView.swift` — Onboarding chat bubble.
- `Nudge/Views/Onboarding/Components/MascotAvatarView.swift` — Mascot avatar image.
- `Nudge/Views/Onboarding/Components/TypingIndicatorView.swift` — Animated "typing" dots.
- `Nudge/Views/Onboarding/Components/OnboardingProgressBar.swift` — Step progress bar.

## Components

- `Nudge/Views/Components/AppTabBar.swift` — Custom floating tab bar; morphs into a send button via `ChatComposerStore`.
- `Nudge/Views/Components/CountdownLabel.swift` — Task deadline display + `CountdownState` (pure countdown/urgency/date-line + event-line logic); used by task/event rows and the timeline.
- `Nudge/Views/Components/ScreenHeader.swift` — Reusable tab header (title + subtitle).
- `Nudge/Views/Components/TodayTimelineView.swift` — Horizontal day timeline (events, placed tasks, notification markers, now-line); reads SwiftData, calls back into `TasksTabView` for open/place/**complete** (long-press a placed block completes it via `.taskCompletionEffect`; tap still opens — simultaneous gestures). Blocks are `Button`s and the empty-space tap gesture sits on the *container*, because a parent gesture is lower priority than the child buttons. Its `@Query`s are **bounded in a custom `init`** (tasks capped 300; outcomes predicated to `resultRaw == "pending"`, capped 60): *"This view is ALWAYS mounted in the Tasks tab and re-reads on every 60s clock tick, so unbounded `@Query` here fetches the full task/outcome history into the main context on a hot path."*

## Services

- `Nudge/Services/SharedModelContainer.swift` — Builds the app-group SwiftData `ModelContainer` + shared `UserDefaults`. Compiled into both targets, but **only the app actually uses it** — the widget re-declares its own schema/container (see Cross-cutting invariant 2).
- `Nudge/Services/ClaudeService.swift` — All Anthropic (Haiku) calls: brain-dump parsing, day-plan refine, prep plans, screenshot parsing. Called by Home/Tasks, `DayPlanRefiner`, `NudgeIntelligence`, `ScreenshotCalendarImporter`. The brain-dump system prompt is a **behavioral contract**, not just parsing instructions: event-vs-task classification rules (a deadline is not an event; an exam is an event but studying for it is a task), 10 labeled worked examples, the ORDERED PLANS (`sequenceIndex`) rules, the single-follow-up rule for timeless events, and a generated 21-day weekday→ISO-date lookup table — *"The model is BAD at computing 'which date is next Thursday' on its own (it put 'Thursdays and Fridays' on the wrong dates), so we hand it an exact table and forbid it from calculating."* Edit this prompt carefully; it defines app-wide capture behavior.
- `Nudge/Services/NudgeIntelligence.swift` — Read-only cached AI signals per task (`TaskIntelligence`); single-flight enrichment via `ClaudeService`. Read by `NudgeArbiter` / scoring.
- `Nudge/Services/NudgeArbiter.swift` — The decision engine: `reevaluate` reads data, applies gates, schedules/cancels notifications, writes `NudgeOutcome`. Called by `ContentView`, tabs, `SessionCoordinator`, `DayPlanRefiner`. Idle and floater check-in candidates target the **plan's next item** (lowest `sequenceIndex`) ahead of score — see Cross-cutting invariant 1.
- `Nudge/Services/NudgeConfig.swift` — All tunable constants (thresholds, budgets, priors) the arbiter/scorers consult.
- `Nudge/Services/EisenhowerScorer.swift` — Pure urgency×importance scoring + quadrant routing; used by the arbiter and planners.
- `Nudge/Services/StartByPlanner.swift` — Computes a task's recommended start-by time and deep-work classification; used by arbiter + planners.
- `Nudge/Services/DurationModel.swift` — Deterministic effort estimate (category prior + learned `CategoryDurationStats`); feeds urgency scoring.
- `Nudge/Services/BusyWindowResolver.swift` — Computes event busy windows (+buffers, merges) from events; used by the arbiter's conflict gate and planners.
- `Nudge/Services/DayPlanRefiner.swift` — AI layer over Plan-my-day: builds a day summary, calls `ClaudeService.refineDayPlan`, applies placements (only `plannedStartDate` / `plannedDurationMinutes` / `plannedIsAuto` — never schedules notifications). Plan tasks lead the candidate list in `sequenceIndex` order, non-plan tasks follow by score. Pro/trial gated, cached once per day unless `force: true`. Called by Tasks tab + Home chat.
- `Nudge/Services/DayPlanner.swift` — **Dead code.** Referenced by zero call sites; only two stale comments elsewhere still name it (`TaskActivityAttributes.swift`, `TaskLiveActivityView.swift`). The real deterministic planner is `TasksTabView.planMyDay()`.
- `Nudge/Services/NotificationScheduler.swift` — Registers the two fixed daily notifications (morning kickoff, bedtime planning) from `UserProfile`.
- `Nudge/Services/NudgeNotificationService.swift` — `UNUserNotificationCenterDelegate`: handles taps/actions, routes to tabs/sheets, writes `NudgeOutcome`. `pickTopOpenTask` prefers the **plan's next item** over score. The idle-"Not yet" intent is made durable by writing `pendingIdleTaskIDKey`/`pendingIdleTaskDateKey` to the app group (consumed by `TasksTabView` on appear/active) because *"The transient `.nudgeIdleNotYetTapped` post is only caught if TasksTabView is already mounted and subscribed — which it is NOT on a COLD LAUNCH from the notification tap."*
- `Nudge/Services/NudgeNotificationCategories.swift` — Defines `UNNotificationCategory` + action buttons used by every arbiter notification.
- `Nudge/Services/CalendarService.swift` — Apple Calendar / Canvas iCal import into `NudgeTask` events; rolling-window sync + past-event purge.
- `Nudge/Services/ScreenshotCalendarImporter.swift` — Vision OCR → `ClaudeService` → `NudgeTask` events from a schedule screenshot.
- `Nudge/Services/SessionCoordinator.swift` — Runs a single focus session (state, timers, widget publish); drives `LiveActivityManager`, calls the arbiter.
- `Nudge/Services/LiveActivityManager.swift` — Starts/updates/ends the focus-session Live Activity (ActivityKit); driven by `SessionCoordinator`.
- `Nudge/Services/CountdownClock.swift` — Single 60s ticker publishing `now`; observed by `CountdownLabel`, `TodayTimelineView`, `TasksTabView`, and `ContentView`.
- `Nudge/Services/EngagementTracker.swift` — Records app opens, streaks, inactivity escalation into `EngagementState`; called on launch/foreground.
- `Nudge/Services/ChatComposerStore.swift` — Observable bridge between the Home composer and the floating tab-bar send button.
- `Nudge/Services/FocusSessionIntents.swift` — App Intents for focus-session actions (start/pause/end). **App-target copy.** `PauseFocusSessionIntent` / `EndFocusSessionIntent` are declared again in `NudgeWidget/FocusSessionIntents.swift`; the two files are separate per-target copies that do not collide. Check which target you mean before editing.
- `Nudge/Services/TaskScheduler.swift` — Legacy/cleared stub (old scheduling engine removed; `TimeBlock` model retained).
- `Nudge/Services/SmartNotificationEngine.swift` — Legacy/cleared stub (superseded by `NudgeArbiter`).
- `Nudge/Services/NotificationMessageGenerator.swift` — Legacy/cleared stub (message copy now built in the arbiter).
- `Nudge/Services/FocusSessionManager.swift` — Deprecated placeholder (replaced by `SessionCoordinator` + `LiveActivityManager`).

## Models (SwiftData `@Model` unless noted)

- `Nudge/Models/NudgeTask.swift` — Core task/event record (title, due, category, `isInformationalEvent`); the central entity most services read/write. Two independent scheduling concepts live here: **placement** — `plannedStartDate` / `plannedDurationMinutes` / `plannedIsAuto` (a slot on today's timeline; `plannedIsAuto` distinguishes "Plan my day" placements from manual ones, so `clearPlan()` can remove only the auto ones) — and **plan order** — `sequenceIndex` (see Cross-cutting invariant 1). Neither implies the other, and neither touches `dueDate`/`specificTime`, which remain the deadline.
- `Nudge/Models/UserProfile.swift` — User settings/preferences (wake/bedtime, toggles, Pro/trial); read by arbiter, scheduler, tabs.
- `Nudge/Models/NudgeOutcome.swift` — Audit log of each emitted notification and the user's response; feeds fatigue/scoring.
- `Nudge/Models/TaskIntelligence.swift` — Cached AI signals per task (statedUrgency, suggestedFirstStep); written by `NudgeIntelligence`.
- `Nudge/Models/StatedUrgency.swift` — Enum (none/explicit) for language-derived urgency.
- `Nudge/Models/TaskCategory.swift` — Enum of task categories + helpers used across scoring/config.
- `Nudge/Models/CategoryDurationStats.swift` — Learned per-category effort mean; written on completion, read by `DurationModel`.
- `Nudge/Models/EventDurationStats.swift` — Learned per-title event duration; read by the timeline / busy-window logic.
- `Nudge/Models/TimeBlock.swift` — Scheduled time-block record (retained for the schedule rebuild).
- `Nudge/Models/NudgeGoal.swift` — User goal captured in onboarding/chat.
- `Nudge/Models/NudgeHabit.swift` — Recurring routine/habit with reminder time.
- `Nudge/Models/CheckIn.swift` — Morning/evening check-in record.
- `Nudge/Models/DailySession.swift` — Per-day brain-dump chat transcript (source for AI history).
- `Nudge/Models/DailyStats.swift` — Per-day completion/activity counters for Stats.
- `Nudge/Models/CompletedTaskRecord.swift` — Completed-task history (weekly) shown in Tasks/Stats.
- `Nudge/Models/EngagementState.swift` — Streaks, app-open counts, escalation level; written by `EngagementTracker`.
- `Nudge/Models/NotificationEvent.swift` — Record of a notification lifecycle event (analytics/dedupe support).
- `Nudge/Models/SentNotificationFlag.swift` — Marker preventing duplicate sends of the same notification.
- `Nudge/Models/TaskActivityAttributes.swift` — ActivityKit attributes for the DayPlanner/task Live Activity.
- `Nudge/Models/FocusSessionAttributes.swift` — ActivityKit attributes for the focus-session Live Activity.

## Widgets (NudgeWidget extension)

Path note: this directory is `NudgeWidget/` at the repo root — a sibling of
`Nudge/`, not a subdirectory of it.

- `NudgeWidget/NudgeWidgetBundle.swift` — `@main` widget bundle registering all widgets + Live Activities.
- `NudgeWidget/NudgeWidget.swift` — Task widget (medium/large): timeline provider + views + `WidgetColors` (non-private, shared with the companion widget). Row sort matches the app — plan tasks first by `sequenceIndex`, then score/deadline. Also renders a mini day chart (`WidgetTimeBlock`, rolling 5-hour window with "now" 15% from the left). **Declares the widget's own `widgetSchema` / `widgetAppGroupID` / `widgetModelContainer`** — see Cross-cutting invariant 2.
- `NudgeWidget/NudgeCompanionWidget.swift` — Small mascot widget that deep-links into the app; uses `WidgetColors` and an edge-to-edge `containerBackground` (a manual `.background` sits inside the system content margins and leaves an inset ring).
- `NudgeWidget/NudgeWidgetControl.swift` — Control Center control (start session / open app).
- `NudgeWidget/NudgeWidgetLiveActivity.swift` — Live Activity configuration + lock-screen/Dynamic Island layout.
- `NudgeWidget/TaskLiveActivityView.swift` — Live Activity content view for a task/focus session.
- `NudgeWidget/CompleteTaskIntent.swift` — App Intent to complete a task from the widget (writes to the shared store).
- `NudgeWidget/FocusSessionIntents.swift` — App Intents for focus-session control from the widget/Live Activity. **Widget-target copy** — see the `Nudge/Services/` entry above.
