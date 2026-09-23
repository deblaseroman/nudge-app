# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Nudge is an iOS app (SwiftUI + SwiftData) that turns brain-dumped tasks into scheduled, ADHD-friendly notifications ("nudges"). Two targets in `Nudge.xcodeproj`:

- **Nudge** — the app (`com.deblaser.nudge`)
- **NudgeWidgetExtension** — widgets, Control Center control, Live Activities (`NudgeWidget/`)

iOS deployment target is 26.4 — a build failure about the deployment target means the local Xcode is too old, not broken code. No SPM/CocoaPods dependencies; the Anthropic API is called directly over URLSession.

`ROADMAP.md` is the index of outstanding work, ordered by when each item can be started and naming what blocks it — read it when picking up work or checking whether something is already planned; the constraints below are what's in force *now*, which is a different question.

`docs/plan/README.md` is the planning bus: a separate planning agent writes the current work item to `docs/plan/NEXT.md`, Claude Code archives the approved plan and writes a report to `docs/plan/reports/`. Read it at session start — if `NEXT.md` holds an approved item, that's the work. The planner's filesystem access is scoped to `docs/plan/`, so Claude Code stays the only writer to source.

**`docs/plan/CONTEXT.md` is census-derived and maintained in the same commit as the change that dates it.** Any cycle that adds, removes, re-anchors, or disables a candidate builder, a gate, or an AI call site updates `CONTEXT.md`'s ⚙ census sections and its verification stamp **in the same commit** — the file is the sole input to every new planning conversation, and a stale copy there converts directly into planner error (cycle 2026-08-05-01 exists because it did, twice). Same discipline as the three hand-synced schema lists and the ARCHITECTURE.md update rule below: keyed on the change, not on anyone remembering.

`DESIGN.md` is the product intent — positioning, what the arbiter is for, where AI is allowed, tone rules. Read it before any change that touches product behavior (copy, what the user is told, when they're interrupted, what the app decides for them); a change can compile, fit `ARCHITECTURE.md`, and still be wrong there.

## Current work order

Sequencing constraints in force right now. Each is a deliberate state, not an oversight — don't "fix" one without being asked.

1. **The due-date importance ladder is live (Sep 16 2026):** a due-dated item is medium (0.6) from creation and high (0.9) on its due day, ahead of the weighted mix; undated items keep the mix. Separate from that: **stakes is NOT wired into scoring.** `EisenhowerScorer.importance` accepts an optional `stakes:` param, but no production call site passes it, so the number is identical to the pre-stakes one. Do not arm it without explicit instruction. **Reading `task.stakes` directly is a different thing and is allowed** — `buildMorningPromptCandidates` ranks on it to pick which task the morning prompt names (Jul 2026). That doesn't arm anything: it never reaches the scorer, and the candidate's `urgency`/`importance` are the constants they always were.
2. **Before arming stakes, the floater check-in must actually fire and produce baseline outcome data.** It never has — `.floater` shows `—` in every by-kind outcome dump. The original cause (no next-day rollover in `buildFloaterCheckInCandidates`) was **fixed Jul 2026**; the builder now rolls a passed anchor to tomorrow like morning/idle do. What starves it now is population, not code: it targets open **undated** tasks, and real dumps so far date everything, so it skips with `floater: SKIP — no open undated task` (Sep 2026 console). Arming stakes first would still hand floaters a −0.15 penalty and suppress the very thing `.floater` was split out to measure.
3. **`NudgeConfig.fatigueGateEnabled` is false deliberately.** Outcomes are being recorded and observed before anything consumes them.
4. **Break-it-down was removed entirely (Jul 2026).** The kind, builder, category, `tappedBreakDown`, toggle and Settings row are gone; `deadlinePrepNotificationsEnabled` survives only as a deprecated tombstone column on `UserProfile`. Don't resurrect any of it.
5. **Any change that alters what the arbiter does gets a DEBUG before/after comparison on real data before it goes live.** This has caught several wrong assumptions already.

### Known bugs, not yet fixed

Unlike the items above, these are wrong — they're listed so they aren't mistaken for deliberate state, and so their noise isn't misread as signal.

- ~~**`deadlinePrepNotificationsEnabled` is misnamed**~~ — **resolved Jul 2026** by break-it-down's removal (item 4 above): nothing reads the field any more; it survives only as a deprecated tombstone column on `UserProfile` so existing stores open without a migration. The name still lies — read it as history, not a spec.
- ~~**`hadRecentActivity` in `passesGates` evaluates against `now`**~~ — **fixed Jul 2026.** It is now `firesInsideActivityCooldown(_ fireDate:)` and blocks a candidate only when its own fire time lands in `[lastSessionStart, lastSessionStart + recentActivityCooldownMinutes)`. Strictly more permissive than the old rule for every future-firing candidate, so it can only free candidates, never block new ones. The active-session gate above it had the identical bug plus a missing `countsAgainstBudget` exemption, and was fixed the same way in the next cycle (`firesDuringActiveSession`). **Both gates now read the candidate's fire date; no gate in `passesGates` is keyed on `now` any more.**

## Roman's dev notes

DEBUG builds have a **Dev notes** page under Settings where Roman writes issues and changes while using the app. They are a plain file in the app's Documents folder on the phone. With the phone plugged in, unlocked and trusted, run `scripts/pull-dev-notes.sh` to copy and print them; read them at the start of a session when he says he has notes. The same page has **Write data snapshot**, which dumps every task row to a JSON file; `scripts/pull-dev-snapshot.sh` pulls it, and that is how to see the store's real state on his phone (the app-group container itself cannot be copied through devicectl). To reproduce a schedule-screenshot import without a device, launch the simulator build with `-nudge-skip-onboarding -nudge-import-screenshot <mac path to the image>` and read the console (`xcrun simctl launch --console`); the simulator's app-group store is then queryable with sqlite3 via `xcrun simctl get_app_container <udid> com.deblaser.nudge groups`.

## Commit and push

Every cycle ends with a commit, and every commit is pushed to `origin` on the
working branch in the same turn. Never merge to `main`; that is Roman's call
through a pull request. The reason this is a rule: 42 commits sat on this Mac
for nine days in Sep 2026 while GitHub showed the branch stuck on Sep 14, and
Roman found out from the repo page. If the push is refused (the permission
gate, or GitHub rejecting the keychain credential), say so in the report's
first line and give the exact command to run with the `!` prefix; do not
leave it to the closing summary. The "do not push" line in older plan
templates is superseded by this rule.

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
2. Rebuilds candidates — ten builders: event blocks, morning prompt, idle, prep, due-soon, floater check-in, come-back, goal lapse, placement heads-up, placement follow-up (`docs/plan/CONTEXT.md`'s ⚙ census table is the authority; `getAhead` and break-it-down are retired)
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
- **Plan-my-day has two implementations.** The deterministic one is `DayPlanEngine` (entered from `planMyDay()` in `Nudge/Views/Tabs/TasksTabView.swift`). `DayPlanRefiner` is the AI layer over it (cached once per day; no tier gate, the app ships as one version). Both write only `plannedStartDate` / `plannedDurationMinutes` / `plannedIsAuto`.
- The notification path is fully deterministic: `EisenhowerScorer` (urgency×importance → quadrant), `DurationModel` (category priors + learned `CategoryDurationStats`), `StartByPlanner`, `BusyWindowResolver`. No LLM calls in the arbiter.

### Conventions

- **Every tunable constant lives in `NudgeConfig`** (thresholds, budgets, priors, buffers) — change behavior there, not inline. The file is deliberately kept thin and readable.
- Stateful services expose a `.shared` singleton; scoring/planning helpers are stateless.
- Colors/fonts come from `NudgeTheme` (Lexend font family); haptics and animation constants from `NudgeFeedback`. 


## Build for the category, never the instance

This applies to every change — bug fixes and new features alike.

A bug report or feature request describes one case. The case is an
example, not the target. "Call grandma" is a placeholder for every
task like it. The test for any change: would it work for a task or
input nobody has thought of yet?

Before editing, state in your reply:
1. The category: the property that makes this case behave this way.
   A category is something any task can carry (a time window, a due
   kind, a source, a missing date) — never a title, keyword, or phrase.
2. Five other cases in that category, worded differently, including
   at least one that doesn't look like the report. Say which pass now.
3. Whether the cause is the design or just this code path. If the
   design, propose the design change and end the turn before editing.

Then fix so every listed case passes, and add the cases to the eval
set at eval/cases.json (`eval/run.sh --local-only` runs the free half;
`eval/README.md` has the case shape). Create it if it doesn't exist.

Signs a fix is wrong: it names the specific task, keyword, or phrase
from the report; it adds a special case, keyword list, or "if the
user says X" rule to a prompt or to code; it enumerates cases instead
of stating a rule. If a special case seems necessary, the design
doesn't cover this category — report that instead of adding it.

If you encounter an existing special case while working, flag it in
your reply with the category it was patching. Don't remove it unasked.






