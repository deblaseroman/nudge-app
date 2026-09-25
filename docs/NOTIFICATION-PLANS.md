# Notification system: four plans that fit the app as built

Sep 25 2026. Read-only proposal; nothing here is built. Each plan keeps the
arbiter's contract (deterministic timing, data in → candidates → gates →
winners) and changes one layer. They compose: B is the base the others'
push features stand on.

## What every plan starts from

**What the app already knows about the user**, all on-device:

- Tasks: due date/time (owed), intent day, placement (and whether the
  user placed it by hand), stakes, category, length, skip count.
- Events with times; calendar imports.
- Profile: wake, bedtime, quiet window, per-kind toggles, coaching style.
- Behavior: app opens (`AppOpenLog`), session starts/ends, every nudge's
  outcome (tapped / dismissed / ignored, per kind, per task),
  completions per day, goal activity.

**How a nudge is decided today**: ten builders each turn that data into
candidates with a fire time; gates drop the ones that would land badly
(quiet hours, busy, active session, cooldown, budget 10/day, 90-minute
spacing); winners are scheduled as local notifications with copy written
up to three days ahead and cached. Every plan below keeps this pipeline
and changes only what is in bold in its section.

**Apple's lines, respected by all four**: a local notification cannot
change after it is scheduled; a closed app runs no code except a
background refresh (opportunistic, once a day here) or an extension iOS
starts for a push or a Screen Time event; an extension gets seconds, a
few MB, and App Group storage, and cannot talk back to the app process.

---

## Plan A: Adaptive, no server

Arm what is already recorded. The arbiter learns from outcomes and keys
the two clock-anchored kinds to behavior.

- **Decision**: unchanged builders, plus two new inputs to gates and
  ranking. Per-kind adaptation: a kind ignored N times in a row gets its
  fire time moved and its frequency halved; a kind tapped gets kept. The
  morning prompt fires at the first app open after wake if that comes
  before the anchor, else at the anchor; the idle check fires only after
  a gap in opens and sessions, not at a fixed hour.
- **Copy**: pre-generated and cached as today.
- **Code**: `NudgeArbiter` gates and the morning/idle builders,
  `NudgeConfig` for the thresholds, `fatigueGateEnabled` on. No new
  files, no new data.
- **Infrastructure**: none.
- **Cost**: none beyond today.
- **Does not do**: react to anything outside the app; personalize at
  delivery.

## Plan B: Decided on-device, delivered by push, written at delivery

The arbiter still decides what and when. The server only carries time.

- **Decision**: unchanged. After each reevaluate the app uploads its
  winners (fire time, kind, task id, fallback copy) to the proxy.
- **Delivery**: the proxy sends a push at each fire time. iOS starts the
  app's Notification Service Extension, which reads the task's current
  state from the App Group store, asks the model for one line through the
  proxy, and shows it; on any failure it shows the cached copy. A silent
  push can wake the app to re-plan when the server sees a change.
- **Code**: a small upload in `NudgeArbiter.schedule` (keep locals as the
  fallback when no token), a new Notification Service Extension target
  that reuses `NudgeCopyService`'s prompt, device-token handling in
  `NudgeApp`.
- **Infrastructure**: the proxy already planned for the key, plus an
  APNs key and one table of pending sends.
- **Cost**: about a Haiku call per delivered nudge, under a tenth of a
  cent.
- **Does not do**: change timing; add behavior triggers.

## Plan C: Behavior triggers from Screen Time

Adds the one signal the research points at that the app cannot see
today: time spent in the apps the user names.

- **Decision**: the user opts in and picks apps in Apple's picker. A
  Screen Time schedule with a threshold (for example 30 minutes in those
  apps since wake) starts the app's DeviceActivity extension when
  crossed. The extension writes one event to the App Group. That event is
  a new candidate source for the floater and idle builders: the target is
  chosen with the ranking they already use, and the event counts against
  the same budget and spacing.
- **Delivery**: two options, chosen after a one-day spike. A shield over
  the picked app with the app's own text naming the one task, which is
  reliable; or a notification from the extension, which has been
  inconsistent across iOS versions.
- **Code**: a DeviceActivity extension target, the App Group event, a
  branch in the floater/idle builders, an opt-in screen in Settings.
- **Infrastructure**: none for the local version. Apple must grant the
  Family Controls capability for distribution.
- **Cost**: none; copy from the cache.
- **Does not do**: read usage numbers into the app, know which app is
  open, or work without the user's explicit opt-in.

## Plan D: Presence and digests instead of interruptions

Fewer nudges, two new surfaces: the session and the summary.

- **Decision**: unchanged builders, with idle and floater merged into one
  check-in kind that fires only after a real gap (no open, no session).
  Two additions with no ranking at all: a mid-session line on the Live
  Activity at the block's midpoint ("still with you, 20 minutes left"),
  and a weekly summary on Sunday evening from `DailyStats` and
  `CompletedTaskRecord` (done, missed, longest session, what is due next
  week).
- **Delivery**: the session line updates the Live Activity locally while
  the app is open and by push through Plan B when it is not; the weekly
  summary is a local notification pre-generated by the daily background
  refresh, opening the Tasks-tab memo.
- **Code**: `LiveActivityManager` gets a midpoint update, a
  `weeklySummary` kind in the arbiter, one memo template.
- **Infrastructure**: none for the local version.
- **Cost**: one memo call a week.
- **Does not do**: personalize at delivery without Plan B.

---

## Side by side

| | A adaptive | B push + at-delivery copy | C Screen Time triggers | D presence + digests |
|---|---|---|---|---|
| Changes timing | yes, from outcomes | no | adds a trigger | merges two kinds |
| Personal copy at delivery | no | yes | no | with B |
| Works with app closed | yes | yes | yes | session line needs B |
| Needs the proxy | no | yes | no | for push only |
| Apple approval needed | no | APNs setup | Family Controls | no |
| New targets | none | 1 extension | 1 extension | none |
| Research backing | paper 1 (behavior over timers) | paper 1 (personal, adaptive) | paper 2 (boredom trigger) | paper 1 (59% summaries; body doubling) |
| Effort | days | a week plus the proxy | a week plus approval | days |

## A recommendation, if wanted

A first, because it uses data the app has collected for two months and
costs nothing. B when the proxy lands, since it is the one that makes the
notifications read as written for the user, which was the original goal.
D's weekly summary any time. C last: it is the most novel and the only
one that depends on Apple saying yes.
