# Nudge — Architecture Map

A file-level map of the project. Each entry is one responsibility + key relationships.
This is a map, not documentation — read the files for detail.

## Data flow (overview)

1. **User input** — the user brain-dumps in `HomeTabView` chat, or adds/edits tasks in `TasksTabView`, or imports a calendar/screenshot.
2. **Parsing** — `ClaudeService` (Haiku) turns free text into structured tasks/events; deterministic helpers (`DurationModel`, `EisenhowerScorer`, `StartByPlanner`) score/estimate without the LLM.
3. **SwiftData** — parsed items persist as `@Model`s (`NudgeTask`, `UserProfile`, `NudgeOutcome`, …) in the app-group container from `SharedModelContainer`.
4. **Enrichment** — `NudgeIntelligence` caches per-task AI signals (`TaskIntelligence`); `DayPlanRefiner` / `DayPlanner` place tasks onto today's timeline.
5. **Arbiter** — on data change / foreground, `NudgeArbiter.reevaluate` reads the data, applies gates (`BusyWindowResolver`, `NudgeConfig`), and decides which notifications should exist.
6. **Notifications** — `NudgeArbiter` + `NotificationScheduler` register `UNNotificationRequest`s (categories from `NudgeNotificationCategories`); `NudgeNotificationService` handles taps/actions and writes back `NudgeOutcome`.
7. **Sessions** — `SessionCoordinator` runs focus sessions and drives `LiveActivityManager` (Live Activity).
8. **Widgets** — the widget extension reads the shared store and renders task/companion widgets + Live Activities; App Intents write back completions.
9. **Feedback loop** — `NudgeOutcome` (tapped/ignored) and `CategoryDurationStats` feed future scoring/estimates.
10. **Reevaluation is data-driven** — UI never schedules notifications directly; it mutates data and calls the arbiter.

---

## App entry & root views

- `Nudge/NudgeApp.swift` — `@main` App: builds the SwiftData container, sets the notification delegate, registers background refresh. Hosts `ContentView`.
- `Nudge/ContentView.swift` — Root router (onboarding vs `MainTabView`); handles deep links, scene-phase, and the debounced `NudgeArbiter.reevaluate`.
- `Nudge/Views/Tabs/MainTabView.swift` — Tab shell owning `selectedTab`; reacts to `deepLinkTab` to switch tabs from notification taps.
- `Nudge/NudgeTheme.swift` — Central colors + Lexend fonts; used by every view.
- `Nudge/NudgeFeedback.swift` — Haptics (`NudgeHaptics`) and animation constants (`NudgeAnimation`); used app-wide.
- `Nudge/Views/MainAppMockView.swift` — Static design mock of the main app (previews/reference); not in the live flow.

## Tabs

- `Nudge/Views/Tabs/HomeTabView.swift` — Brain-dump chat; calls `ClaudeService.sendChat` / routes plan intents to `DayPlanRefiner`, writes `NudgeTask`s, triggers the arbiter.
- `Nudge/Views/Tabs/TasksTabView.swift` — Task/event list + `TodayTimelineView`, Plan-my-day / AI Refine, placement & editor sheets; calls `NudgeArbiter`, `DayPlanRefiner`, `NudgeIntelligence`.
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
- `Nudge/Views/Components/TodayTimelineView.swift` — Horizontal day timeline (events, placed tasks, notification markers, now-line); reads SwiftData, calls back into `TasksTabView` for open/place.

## Services

- `Nudge/Services/SharedModelContainer.swift` — Builds the app-group SwiftData `ModelContainer` + shared `UserDefaults`; used by app and widget.
- `Nudge/Services/ClaudeService.swift` — All Anthropic (Haiku) calls: brain-dump parsing, day-plan refine, prep plans, screenshot parsing. Called by Home/Tasks, `DayPlanRefiner`, `NudgeIntelligence`, `ScreenshotCalendarImporter`.
- `Nudge/Services/NudgeIntelligence.swift` — Read-only cached AI signals per task (`TaskIntelligence`); single-flight enrichment via `ClaudeService`. Read by `NudgeArbiter` / scoring.
- `Nudge/Services/NudgeArbiter.swift` — The decision engine: `reevaluate` reads data, applies gates, schedules/cancels notifications, writes `NudgeOutcome`. Called by `ContentView`, tabs, `SessionCoordinator`, `DayPlanRefiner`.
- `Nudge/Services/NudgeConfig.swift` — All tunable constants (thresholds, budgets, priors) the arbiter/scorers consult.
- `Nudge/Services/EisenhowerScorer.swift` — Pure urgency×importance scoring + quadrant routing; used by the arbiter and planners.
- `Nudge/Services/StartByPlanner.swift` — Computes a task's recommended start-by time and deep-work classification; used by arbiter + planners.
- `Nudge/Services/DurationModel.swift` — Deterministic effort estimate (category prior + learned `CategoryDurationStats`); feeds urgency scoring.
- `Nudge/Services/BusyWindowResolver.swift` — Computes event busy windows (+buffers, merges) from events; used by the arbiter's conflict gate and planners.
- `Nudge/Services/DayPlanRefiner.swift` — AI layer over Plan-my-day: builds a day summary, calls `ClaudeService.refineDayPlan`, applies placements. Called by Tasks tab + Home chat.
- `Nudge/Services/DayPlanner.swift` — Standalone linear scheduling engine (tasks → time blocks); legacy/utility, not on the main arbiter path.
- `Nudge/Services/NotificationScheduler.swift` — Registers the two fixed daily notifications (morning kickoff, bedtime planning) from `UserProfile`.
- `Nudge/Services/NudgeNotificationService.swift` — `UNUserNotificationCenterDelegate`: handles taps/actions, routes to tabs/sheets, writes `NudgeOutcome`; durable idle-"Not yet" intent.
- `Nudge/Services/NudgeNotificationCategories.swift` — Defines `UNNotificationCategory` + action buttons used by every arbiter notification.
- `Nudge/Services/CalendarService.swift` — Apple Calendar / Canvas iCal import into `NudgeTask` events; rolling-window sync + past-event purge.
- `Nudge/Services/ScreenshotCalendarImporter.swift` — Vision OCR → `ClaudeService` → `NudgeTask` events from a schedule screenshot.
- `Nudge/Services/SessionCoordinator.swift` — Runs a single focus session (state, timers, widget publish); drives `LiveActivityManager`, calls the arbiter.
- `Nudge/Services/LiveActivityManager.swift` — Starts/updates/ends the focus-session Live Activity (ActivityKit); driven by `SessionCoordinator`.
- `Nudge/Services/CountdownClock.swift` — Single 60s ticker publishing `now`; observed by all `CountdownLabel`s and `TodayTimelineView`.
- `Nudge/Services/EngagementTracker.swift` — Records app opens, streaks, inactivity escalation into `EngagementState`; called on launch/foreground.
- `Nudge/Services/ChatComposerStore.swift` — Observable bridge between the Home composer and the floating tab-bar send button.
- `Nudge/Services/FocusSessionIntents.swift` — App Intents for focus-session actions (start/pause/end) usable from widgets/Live Activity.
- `Nudge/Services/TaskScheduler.swift` — Legacy/cleared stub (old scheduling engine removed; `TimeBlock` model retained).
- `Nudge/Services/SmartNotificationEngine.swift` — Legacy/cleared stub (superseded by `NudgeArbiter`).
- `Nudge/Services/NotificationMessageGenerator.swift` — Legacy/cleared stub (message copy now built in the arbiter).
- `Nudge/Services/FocusSessionManager.swift` — Deprecated placeholder (replaced by `SessionCoordinator` + `LiveActivityManager`).

## Models (SwiftData `@Model` unless noted)

- `Nudge/Models/NudgeTask.swift` — Core task/event record (title, due, category, planned placement, `isInformationalEvent`); the central entity most services read/write.
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

- `Nudge/NudgeWidget/NudgeWidgetBundle.swift` — `@main` widget bundle registering all widgets + Live Activities.
- `Nudge/NudgeWidget/NudgeWidget.swift` — Task widget (medium/large): timeline provider + views + `WidgetColors`; reads the shared store.
- `Nudge/NudgeWidget/NudgeCompanionWidget.swift` — Small mascot widget that deep-links into the app.
- `Nudge/NudgeWidget/NudgeWidgetControl.swift` — Control Center control (start session / open app).
- `Nudge/NudgeWidget/NudgeWidgetLiveActivity.swift` — Live Activity configuration + lock-screen/Dynamic Island layout.
- `Nudge/NudgeWidget/TaskLiveActivityView.swift` — Live Activity content view for a task/focus session.
- `Nudge/NudgeWidget/CompleteTaskIntent.swift` — App Intent to complete a task from the widget (writes to the shared store).
- `Nudge/NudgeWidget/FocusSessionIntents.swift` — App Intents for focus-session control from the widget/Live Activity.
