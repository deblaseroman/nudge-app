# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Nudge is an iOS app (SwiftUI + SwiftData) that turns brain-dumped tasks into scheduled, ADHD-friendly notifications ("nudges"). Two targets in `Nudge.xcodeproj`:

- **Nudge** — the app (`com.deblaser.nudge`)
- **NudgeWidgetExtension** — widgets, Control Center control, Live Activities (`NudgeWidget/`)

iOS deployment target is 26.4 — a build failure about the deployment target means the local Xcode is too old, not broken code. No SPM/CocoaPods dependencies; the Anthropic API is called directly over URLSession.

`ROADMAP.md` is the index of outstanding work, ordered by when each item can be started and naming what blocks it — read it when picking up work or checking whether something is already planned; the constraints below are what's in force *now*, which is a different question.

`docs/plan/README.md` is the planning bus: a separate planning agent writes the current work item to `docs/plan/NEXT.md`, Claude Code archives the approved plan and writes a report to `docs/plan/reports/`. Read it at session start — if `NEXT.md` holds an approved item, that's the work. The planner's filesystem access is scoped to `docs/plan/`, so Claude Code stays the only writer to source.

`DESIGN.md` is the product intent — positioning, what the arbiter is for, where AI is allowed, tone rules. Read it before any change that touches product behavior (copy, what the user is told, when they're interrupted, what the app decides for them); a change can compile, fit `ARCHITECTURE.md`, and still be wrong there.

## Current work order

Sequencing constraints in force right now. Each is a deliberate state, not an oversight — don't "fix" one without being asked.

1. **Stakes is NOT wired into scoring.** `EisenhowerScorer.importance` accepts an optional `stakes:` param, but no production call site passes it, so the number is identical to the pre-stakes one. Do not arm it without explicit instruction. **Reading `task.stakes` directly is a different thing and is allowed** — `buildMorningPromptCandidates` ranks on it to pick which task the morning prompt names (Jul 2026). That doesn't arm anything: it never reaches the scorer, and the candidate's `urgency`/`importance` are the constants they always were.
2. **Before arming stakes, the floater check-in must actually fire and produce baseline outcome data.** It never has — `.floater` shows `—` in every by-kind outcome dump, because `buildFloaterCheckInCandidates` has no next-day rollover. Arming stakes first would hand floaters a −0.15 penalty and suppress the very thing `.floater` was split out to measure.
3. **`NudgeConfig.fatigueGateEnabled` is false deliberately.** Outcomes are being recorded and observed before anything consumes them.
4. **Break-it-down is paused pending removal.** Don't build on it.
5. **Any change that alters what the arbiter does gets a DEBUG before/after comparison on real data before it goes live.** This has caught several wrong assumptions already.

### Known bugs, not yet fixed

Unlike the items above, these are wrong — they're listed so they aren't mistaken for deliberate state, and so their noise isn't misread as signal.

- **The active-session gate in `passesGates` has the same `now`-shaped blindness the cooldown gate just lost.** `if SessionCoordinator.shared.isSessionActive { return false }` is the first line of the function and drops **every** candidate in that reevaluate — tomorrow's included, and event-block reminders too, which every other gate in that function deliberately exempts via `countsAgainstBudget`. Found while fixing the cooldown gate (Jul 2026) and deliberately left alone: it was explicitly out of scope for that cycle, and unlike the cooldown fix it needs a decision about what "a session is active" should mean for a nudge firing three days out.
- **`deadlinePrepNotificationsEnabled` is misnamed** — it gates `buildBreakItDownCandidates`, not any deadline-prep feature (get-ahead reads `taskDueSoonNotificationsEnabled`), so the Settings "Break it down" row that binds it behaves correctly and only the field name lies. Renaming it means a store migration for a toggle whose feature is item 4 above, so read the name as a trap, not a spec.
- ~~**`hadRecentActivity` in `passesGates` evaluates against `now`**~~ — **fixed Jul 2026.** It is now `firesInsideActivityCooldown(_ fireDate:)` and blocks a candidate only when its own fire time lands in `[lastSessionStart, lastSessionStart + recentActivityCooldownMinutes)`. Strictly more permissive than the old rule for every future-firing candidate, so it can only free candidates, never block new ones.

## Build & verify

There are no test targets and no linter config — verification is building both schemes:

```bash
xcodebuild -project Nudge.xcodeproj -scheme Nudge -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Nudge.xcodeproj -scheme NudgeWidgetExtension -destination 'generic/platform=iOS Simulator' build
```

When the Xcode MCP server is connected, prefer its tools (`BuildProject`, `XcodeRefreshCodeIssuesInFile`, …) over raw `xcodebuild`.

### API key

`ClaudeService` reads `ANTHROPIC_API_KEY` from `Nudge/Secrets.plist` (gitignored; template at `Nudge/Secrets.plist.example`). The app builds and runs without it — AI features just throw `ClaudeError.missingAPIKey`.

## Architecture

`ARCHITECTURE.md` is a maintained file-level map (one responsibility + key relationships per file, plus the full data-flow overview). Read it before exploring, and **update it when adding, moving, or repurposing files**.

### The core loop: data-driven notifications

The most important invariant: **UI never schedules notifications directly.** Views mutate SwiftData, then call `NudgeArbiter.shared.reevaluate(reason:profile:modelContext:)`. The arbiter is declarative — each run:

1. Cancels every notification it owns (IDs prefixed `nudge.arb.`, tracked synchronously in App Group UserDefaults — deliberately NOT via the async `pendingNotificationRequests()`, which raced scheduling and killed fresh notifications)
2. Rebuilds candidates (event-block reminders, morning prompt, idle, get-ahead, floater check-in, break-it-down)
3. Filters through gates (busy windows from `BusyWindowResolver`, quiet hours, daily budget, spacing, per-task fatigue from `NudgeOutcome` history)
4. Picks winners and schedules

Time-triggered reasons (`appLaunch`, `sceneActive`, `backgroundTask`) are debounced 60s; data-driven reasons always run. Triggers live in `ContentView` (launch/scene-phase), `NudgeApp` (BGTask), and the tabs after mutations.

The arbiter is the ONLY scheduling site. `NotificationScheduler` is retired — it no longer schedules anything and survives only for the shared session-start key and the one-time cleanup of the old `nudge.daily.*` repeating notifications (which outlive the code that scheduled them). `NudgeNotificationService` is the delegate side: taps/actions → deep-link tab routing + `NudgeOutcome` write-back, which feeds future fatigue gating. The morning prompt's tap routes to Home chat; everything else routes to Tasks.

### App ↔ widget sharing

Both targets read and write one SwiftData store (`Nudge.store`) and one `UserDefaults` via App Group `group.com.deblaser.nudge` — but they build their containers separately: the app from `SharedModelContainer`, the widget from its own `widgetModelContainer` in `NudgeWidget/NudgeWidget.swift`.

- Every new `@Model` must be registered in **three** hand-synced lists — nothing enforces agreement, and a mismatch is a runtime crash, not a build error:
  1. `SharedModelContainer.schema` (`Nudge/Services/SharedModelContainer.swift`) — the app's container
  2. `widgetSchema` (`NudgeWidget/NudgeWidget.swift`) — the widget's container
  3. the `#Preview` container in `Nudge/ContentView.swift` — previews only, and already missing `CompletedTaskRecord`, `TimeBlock`, `CategoryDurationStats`, `EventDurationStats`
- Use `SharedModelContainer.appGroupDefaults` for shared defaults; never construct `UserDefaults(suiteName:)` inline (hot-path cost, and the cached instance is the app-wide convention).
- Widget App Intents (`CompleteTaskIntent`, `FocusSessionIntents`) write back through the shared store; `SessionCoordinator` drives Live Activities via `LiveActivityManager`.
- `FocusSessionIntents.swift` exists in both `Nudge/Services/` and `NudgeWidget/` — make sure you're editing the copy for the target you mean.

### AI vs deterministic split

- All Anthropic calls live in `ClaudeService` (Haiku). `NudgeIntelligence` caches per-task AI signals in `TaskIntelligence` (7-day TTL, single-flight).
- **Plan-my-day has two implementations.** The deterministic one is `planMyDay()` inside `Nudge/Views/Tabs/TasksTabView.swift` — not a service, and *not* `DayPlanner.swift`, which is dead code. `DayPlanRefiner` is the AI layer over it (Pro/trial gated, cached once per day). Both write only `plannedStartDate` / `plannedDurationMinutes` / `plannedIsAuto`.
- The notification path is fully deterministic: `EisenhowerScorer` (urgency×importance → quadrant), `DurationModel` (category priors + learned `CategoryDurationStats`), `StartByPlanner`, `BusyWindowResolver`. No LLM calls in the arbiter.

### Conventions

- **Every tunable constant lives in `NudgeConfig`** (thresholds, budgets, priors, buffers) — change behavior there, not inline. The file is deliberately kept thin and readable.
- Stateful services expose a `.shared` singleton; scoring/planning helpers are stateless.
- Colors/fonts come from `NudgeTheme` (Lexend font family); haptics and animation constants from `NudgeFeedback`.
- `TaskScheduler`, `SmartNotificationEngine`, `NotificationMessageGenerator`, and `FocusSessionManager` are cleared legacy stubs — don't add code to them.
