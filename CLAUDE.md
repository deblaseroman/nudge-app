# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Nudge is an iOS app (SwiftUI + SwiftData) that turns brain-dumped tasks into scheduled, ADHD-friendly notifications ("nudges"). Two targets in `Nudge.xcodeproj`:

- **Nudge** — the app (`com.deblaser.nudge`)
- **NudgeWidgetExtension** — widgets, Control Center control, Live Activities (`NudgeWidget/`)

iOS deployment target is 26.4 — a build failure about the deployment target means the local Xcode is too old, not broken code. No SPM/CocoaPods dependencies; the Anthropic API is called directly over URLSession.

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
2. Rebuilds candidates (event-block reminders, idle, get-ahead, floater check-in, break-it-down)
3. Filters through gates (busy windows from `BusyWindowResolver`, quiet hours, daily budget, spacing, per-task fatigue from `NudgeOutcome` history)
4. Picks winners and schedules

Time-triggered reasons (`appLaunch`, `sceneActive`, `backgroundTask`) are debounced 60s; data-driven reasons always run. Triggers live in `ContentView` (launch/scene-phase), `NudgeApp` (BGTask), and the tabs after mutations.

The only other scheduling site is `NotificationScheduler` (the two fixed daily morning/bedtime notifications). `NudgeNotificationService` is the delegate side: taps/actions → deep-link tab routing + `NudgeOutcome` write-back, which feeds future fatigue gating.

### App ↔ widget sharing

Both targets share one SwiftData store and one `UserDefaults` via App Group `group.com.deblaser.nudge`, built in `SharedModelContainer`:

- Every new `@Model` must be registered in `SharedModelContainer.schema`.
- Use `SharedModelContainer.appGroupDefaults` for shared defaults; never construct `UserDefaults(suiteName:)` inline (hot-path cost, and the cached instance is the app-wide convention).
- Widget App Intents (`CompleteTaskIntent`, `FocusSessionIntents`) write back through the shared store; `SessionCoordinator` drives Live Activities via `LiveActivityManager`.
- `FocusSessionIntents.swift` exists in both `Nudge/Services/` and `NudgeWidget/` — make sure you're editing the copy for the target you mean.

### AI vs deterministic split

- All Anthropic calls live in `ClaudeService` (Haiku). `NudgeIntelligence` caches per-task AI signals in `TaskIntelligence` (7-day TTL, single-flight). `DayPlanRefiner` is the AI layer over Plan-my-day.
- The notification path is fully deterministic: `EisenhowerScorer` (urgency×importance → quadrant), `DurationModel` (category priors + learned `CategoryDurationStats`), `StartByPlanner`, `BusyWindowResolver`. No LLM calls in the arbiter.

### Conventions

- **Every tunable constant lives in `NudgeConfig`** (thresholds, budgets, priors, buffers) — change behavior there, not inline. The file is deliberately kept thin and readable.
- Stateful services expose a `.shared` singleton; scoring/planning helpers are stateless.
- Colors/fonts come from `NudgeTheme` (Lexend font family); haptics and animation constants from `NudgeFeedback`.
- `TaskScheduler`, `SmartNotificationEngine`, `NotificationMessageGenerator`, and `FocusSessionManager` are cleared legacy stubs — don't add code to them.
