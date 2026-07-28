# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Nudge is an iOS app (SwiftUI + SwiftData) that turns brain-dumped tasks into scheduled, ADHD-friendly notifications ("nudges"). Two targets in `Nudge.xcodeproj`:

- **Nudge** — the app (`com.deblaser.nudge`)
- **NudgeWidgetExtension** — widgets, Control Center control, Live Activities (`NudgeWidget/`)

iOS deployment target is 26.4 — a build failure about the deployment target means the local Xcode is too old, not broken code. No SPM/CocoaPods dependencies; the Anthropic API is called directly over URLSession.

## Current work order

Sequencing constraints in force right now. Each is a deliberate state, not an oversight — don't "fix" one without being asked.

1. **Stakes is NOT wired into scoring.** `EisenhowerScorer.importance` accepts an optional `stakes:` param, but no production call site passes it, so the number is identical to the pre-stakes one. Do not arm it without explicit instruction.
2. **Before arming stakes, the floater check-in must actually fire and produce baseline outcome data.** It never has — `.floater` shows `—` in every by-kind outcome dump, because `buildFloaterCheckInCandidates` has no next-day rollover. Arming stakes first would hand floaters a −0.15 penalty and suppress the very thing `.floater` was split out to measure.
3. **`NudgeConfig.fatigueGateEnabled` is false deliberately.** Outcomes are being recorded and observed before anything consumes them.
4. **Break-it-down is paused pending removal.** Don't build on it.
5. **Any change that alters what the arbiter does gets a DEBUG before/after comparison on real data before it goes live.** This has caught several wrong assumptions already.

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
