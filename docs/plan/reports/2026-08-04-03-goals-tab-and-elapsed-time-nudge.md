# Report — 2026-08-04-03 — Personal goals: tab, tracking, bait-and-hook

**Plan:** `archive/2026-08-04-03-plan.md`
**Status:** complete
**Commits:** `cea9c1b` (archive), `be0e341` (item 1), `7f57646` (pre-cycle, see Deviations), `deeebb1` (item 2), `fd6b44f` (item 3), `590008f` (item 4), plus this report.

---

## What changed

### Item 1 — Goals tab (`be0e341`)

- `Nudge/Views/Tabs/GoalsTabView.swift` — NEW. Active-goals list, add/edit/remove via a sheet editor (title + emoji chips; remove is a real delete behind a confirmation), empty state that invites setting one.
- `Nudge/Views/Tabs/MainTabView.swift` — `.goals` case in `AppTab` + the switch; consumes a one-shot app-group flag so the first post-onboarding screen is the Goals tab.
- `Nudge/Views/Components/AppTabBar.swift` — fifth side button ("Goals", SF `target`), between Stats and Tasks.
- `Nudge/ContentView.swift` — `"goals"` deep-link mapping (used by item 3's tap routing infrastructure).
- `Nudge/Views/Onboarding/OnboardingViewModel.swift` — `completeOnboarding` sets the land-on-goals flag.

**`NudgeGoal`'s shape, as requested:** `id`, `title`, `emoji`, `frequency` ("daily" | "3x_week" | "weekly"), `isActive`, `createdAt`. What it was missing: any activity/last-worked field (item 2 added `lastActivityAt`), any link from tasks (item 2 added `NudgeTask.goalID`), and any reader at all — it was written once at onboarding and read by nothing. `frequency` is still written ("daily" default) and read by nothing; the editor doesn't expose it (see Noticed).

**Tab bar layout impact:** the bar is a custom HStack of side buttons plus the floating chat circle (72pt reserved). The fifth button narrows each slot from 1/4 to 1/5 of the remaining width. Labels are 11pt with `lineLimit(1)` + `minimumScaleFactor(0.8)` — "Settings"/"Calendar" may scale slightly on small phones; nothing wraps or truncates. Worth one look on a device (SE-class width is the risk case).

**Conversational goal-setting (report-only, per plan):** it would ride the existing capture call the way commitments do — a `goal_updates`/`new_goals` block in the response schema, a prompt section describing when a dump states a goal rather than a task ("I want to learn Spanish someday" vs "practice Spanish Tuesday"), and a write path in `HomeTabView` mirroring the commitment one. The delicate part is the boundary with commitments (ongoing work with an end date) and floaters (undated tasks) — the prompt would need explicit disambiguation rules, and item 2's goal-matching context creates a feedback risk (a just-created goal matching the same dump's tasks) that needs a same-call ordering rule.

### Item 2 — Goal links + last activity (`deeebb1`)

- `Nudge/Models/NudgeTask.swift` — `goalID: UUID? = nil`, a soft reference (dangling after goal removal = unlinked). Additive, property-level default.
- `Nudge/Models/NudgeGoal.swift` — `lastActivityAt: Date? = nil` plus `recordActivity(goalID:at:in:)`, the one write path (forward-only, no-op on nil/dangling). **Storage choice, as requested: on the goal row itself**, not derived from task history — completed tasks can be deleted, and sessions leave no per-task record at all, so derivation would silently lose evidence.
- `Nudge/Services/ClaudeService.swift` — `activeGoals: [ActiveGoalContext]` param on `sendChat`; goals ride the prompt as short refs (G1, G2 — a model echoes a two-char token far more reliably than a UUID); `goalRef` on `TaskData` + the new_tasks format line. Prompt is explicitly conservative: "a wrong link corrupts the goal's activity history; a missed link costs almost nothing. Any doubt → null."
- `Nudge/Views/Tabs/HomeTabView.swift` — builds the ref list from active goals, resolves `goalRef` → UUID at the write site (unknown ref → nil), tasks only, never events. DEBUG-prints every link decision (`[GoalLink]`).
- **Activity writers** — every completion site + session start: `TasksTabView` checkbox, `NudgeWidget/CompleteTaskIntent` (NudgeGoal was already in the widget schema), chat-driven `task_updates` completion in `HomeTabView`, and `SessionCoordinator.startSession` ("running a session on one" — recorded at start: showing up is the activity).
- `Nudge/Views/Tabs/GoalsTabView.swift` — row now reads "Worked on N ago", or the zero case "Set N ago" from `createdAt` — never a lapse that never started.

No new `@Model`, so the three schema lists are untouched (both new fields are additive columns with property-level defaults; existing stores open unchanged).

### Item 3 — Bait and hook (`fd6b44f`)

**The bait** — `NudgeArbiter.buildGoalLapseCandidates`, kind `.goalLapse`:
- Deterministic template only, never AI copy, actionless category, and it deliberately does not name the goal — the reveal belongs to the hook.
- Fires when an active goal has gone `goalLapseAfterDays` (30) without activity, from `lastActivityAt` or `createdAt` (zero case). Come-back mechanics: the fire date derives from the goal's own evidence, so any recorded activity pushes it out on the next rebuild.
- **Can't become wallpaper, three ways:** a per-goal delivered map (`goalLapseHistory`, own 90-day prune horizon — the shared 2-day cutoff would erase the cap) enforces `goalLapseMinDaysBetweenPerGoal` (30); the builder emits ONE candidate per run (earliest-due goal), so two lapsed goals can never land the same day; and the cap only *binds* once the recorded fire instant has passed, so rescheduling a still-pending bait can't push it out forever.
- Wake+8h anchor (the +1.5h→+7.5h band is fully occupied per `NudgeConfig`'s own doc). Discretionary in every dimension. `taskID` nil (fatigue must never attribute a bait to a linked task); a new `NudgeCandidate.goalID` field rides into userInfo.
- Settings toggle `goalLapseNotificationsEnabled` (default true) + row, per the one-toggle-per-feature rule.

**Bait copy — the options considered, per the plan:**
- A (shipped): title "Got a minute?", body "Nothing's wrong — there's just something worth a look when you have a moment."
- B: "About \(goal.title) — nothing bad, promise. Come look when you're free." (names the goal; stronger pull, weaker reveal)
- C: "No rush. Tap me when you have a minute." (maximum vagueness; reads slightly bot-like)

Picked A: it keeps the goal out of the notification (the hook owns the reveal), and the explicit "nothing's wrong" is the anti-anxiety requirement done literally. B is the fallback if A under-performs on open-rate; it trades reveal for relevance.

**The hook** — the message box, expanded by default:
- Tap routes to Tasks (where the box lives); the tap context now carries `goalID` (fourth app-group key).
- The composer's dormant `aiMessage` seam gets its first producer: `TasksTabView.fetchGoalLapseHookIfNeeded` calls the new `ClaudeService.generateGoalLapseHook` **live on landing** — the app is running, so the notification-copy "can't generate at delivery" constraint doesn't apply, and nothing touches the arbiter's path. The AI reads state only: goal, precomputed elapsed phrase, open task titles, count of ignored nudges in 14 days. Result cached per (goal, day) so re-appears don't re-spend the call.
- The deterministic fallback is `nudgeExplanation`'s `.goalLapse` branch — showing immediately and covering no-key/offline/parse-failure. Lapse branch states the elapsed time; **zero-case branch says "You set X N ago"** and frames the empty list as the reason a first step helps, per the plan's exact requirement. Both end with a small concrete offer.
- The box takes `startsExpanded` (set on goal-lapse arrival) — the full message is the point of the tap.

**Gentle invite** — `goalInviteMessage`, composer slot 6.5 (just above resting, below everything day-relevant): the longest-neglected active goal with no open linked task gets a short question. No notification, no weight.

**Prompt tone rules** for the AI hook encode the plan's tone note verbatim: the elapsed time is allowed to sting; facts never verdicts ("it's been N" vs "you keep putting this off"); no guilt-as-motivation; must end with one small concrete offer.

### Item 4 — One-tap goal → task (`590008f`)

An always-visible button in the message box while either goal message is showing. **What the task gets, as requested:** `goalStepMinutes` (20, in NudgeConfig) as `estimatedMinutes` AND in the title ("20 minutes on Learn Spanish") so the ask is visibly small; priority medium; **stakes deliberately unset** (a self-set step has no external consequence — and nil ranks above `.low` in the morning ranking as absence-of-evidence, so honesty costs nothing); **undated and unscheduled** — it lands in the Unscheduled tab, where the floater check-in and plan-my-day both already cover it. Linked via `goalID`, `source: "goalOffer"`. Accepting clears the lapse tap context and switches to the Unscheduled list so the tap has a visible effect; the invite disappears by recomputation (the goal now has an open linked task). Creating the step does NOT touch `lastActivityAt` — completing it does, through the normal path.

## Verification

- Both schemes built clean after **every** commit (`xcodebuild … Nudge` / `NudgeWidgetExtension`, `BUILD SUCCEEDED`, no warnings in output) — six build pairs total.
- **Work-order item 5 (before/after on real data):** `debugGoalLapseImpact` is in place and runs on every DEBUG reevaluate — same shape as `debugPlacementImpact`: BEFORE = `pickWinners` over the same eligible set minus `.goalLapse`, AFTER = actual, with per-candidate SCHEDULED / gate-BLOCKED / lost-pickWinners verdicts and DISPLACED/ADDED lines. **The dump could not be executed here** — it needs the app running against the real device store; this environment can only build. What to look for on the next device run: `[GoalLapseImpact]` should report either "no goal-lapse candidate this run" (goals with recent activity) or one candidate ~30 days after the oldest goal's `createdAt`, and "nothing displaced" — with budget 10 and one monthly candidate, displacement should be essentially impossible; anything else is a red flag.
- Item 2's linking accuracy ("Spanish task links, unrelated doesn't") is a live-API behavior — not verifiable here. The `[GoalLink]` DEBUG print logs every link decision at capture for exactly this check.
- The AI hook's failure paths (no key → deterministic fallback) are verified by construction: the fallback renders first and the AI result only ever replaces it.

## Deviations from the plan

- **Pre-cycle commit `7f57646`, not in the plan:** the working tree contained complete, uncommitted work (commitment session titles — `commitmentSessionTitle`/`sessionTitle` across five files) with no matching plan or report in `docs/plan/`. It collided file-for-file with item 2's edit sites, so leaving it unstaged would have entangled it with my commits. It built cleanly with both schemes, so I committed it as-is, separately and labeled as found-on-branch, to keep the cycle's commits attributable. **It is not my work and was not reviewed as part of this cycle** — if it wasn't supposed to survive, revert that one commit.
- **The bait is scheduled like any other candidate rather than routed to the Goals tab.** The plan's hook lives in the message box, which is on Tasks — so the tap routes to Tasks (the default), not to the new `"goals"` deep link. The deep-link mapping exists if that call changes.
- **"Monthly at most per goal" is enforced at delivery, not at scheduling** — the cap binds only after the recorded fire instant passes. This is deliberate (a pending bait must survive reschedules), noted because the map's contents can look confusing in the debugger: a future epoch means "pending", not "sent".
- Item 1 shipped without a `frequency` editor — the field exists but nothing reads it, and adding UI for a dead field seemed the wrong direction. Flagged below.
- Otherwise none — the four items shipped as described, at full scope.

## Noticed but not done

- **`NudgeGoal.frequency` is a write-only field** ("daily"/"3x_week"/"weekly", set at onboarding, read by nothing — including the new lapse logic, which is flat 30-day). If frequency-aware lapse thresholds are ever wanted ("3x a week" goal lapsing after a week, not a month), the field is sitting there; alternatively it should be removed from onboarding. Out of scope.
- **The `#Preview` container in `ContentView.swift`** is still missing `CompletedTaskRecord`, `TimeBlock`, `CategoryDurationStats`, `EventDurationStats` (known, documented in CLAUDE.md). Didn't touch it.
- **`MessageBoxChatShell` is still all stubs** — both goal messages direct the user to "tap the bubble" for the conversational path, which lands in the prototype shell ("nothing is saved yet"). The one-tap button (item 4) is the real path; the copy's bubble mention is aspirational until the shell is wired. Worth a copy tweak if the shell stays a stub much longer.
- **Widget completions never trigger a reevaluate** — `CompleteTaskIntent` writes `lastActivityAt` (so the data is right) but the arbiter only rebuilds on the next app-side trigger. A lapsed-then-widget-completed goal keeps its pending bait until then. Accepted: the same staleness applies to every widget completion today; the bait's own monthly cadence makes the window irrelevant in practice.
- **The uncommitted app-icon and DESIGN.md changes** (Roman's hand edits, new icon assets, mascot images) are still uncommitted in the tree — not mine to commit.

## Open questions

- **Bait copy A vs B** (goal-nameless vs goal-naming) — shipped A; if device use shows the bait getting ignored, B is the designed fallback. A/B evidence will accumulate in `.goalLapse` outcome rows.
- **Should a session on a goal-linked task also count when started from the widget?** `FocusSessionIntents` (widget side) starts sessions through `SessionCoordinator` in-app, so today the answer is yes by construction — but if a widget-only start path ever appears, it needs the `recordActivity` call too.
- **The invite's cadence** — currently it can show any day the composer reaches slot 6.5 (it's outranked by everything day-relevant, so in practice it's rare). If it turns out to be wallpaper on quiet lists, it needs a freshness window like the prep announcement; deferred until it's observed on device.
