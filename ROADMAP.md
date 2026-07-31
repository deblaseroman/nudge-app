# Nudge — Roadmap

Everything discussed but not built. Ordered by **when it can be done**, not by
category, so the top of the file is the part you can't start and section 2 is
the part you can.

**Distinct from the other three docs.** `ARCHITECTURE.md` is how the code is
arranged, `DESIGN.md` is product intent, `CLAUDE.md` is the constraints in
force right now — what must not break. This file is what's outstanding. An
item leaves this list when it ships; a constraint leaves `CLAUDE.md` when it
stops being true.

Every item names what blocks it. "Nothing" means it can be picked up as-is.

---

## 1 — Blocked on evidence, nothing to build yet

The work here is *waiting*, not coding. Building any of it now means tuning
against data that doesn't exist.

- Arm stakes in `EisenhowerScorer.importance` — *blocked: the passport flip test, and floater baseline data.*
- Arm `fatigueGateEnabled` — *blocked: roughly a week of real outcome rows.*
- Retune the floater's wake+6h anchor — *blocked: `.floater` rows existing at all.*
- Retune `morningPromptBusyDayThreshold` — 50% likely never triggers; three classes won't reach it — *blocked: evidence of it firing or not.*
- Untethered release-build run to confirm the memory and performance story — still never done — *blocked: nothing but doing it; it gates confidence in everything else.*
- Nothing upstream of `pending` is covered by the classifier harness — real delivery is still unverified end to end — *blocked: nothing; folds into the untethered run.*

## 2 — Arbiter, ready to build

Unblocked and closest to the product's core. Everything here changes what the
arbiter does, so **every item needs a DEBUG before/after on real data** per
`CLAUDE.md`.

- Schedule-based nudge timing: replace every fixed wake+N offset with real gap-finding — largest remaining piece, touches all six builders — *blocked: gap-finding logic must be extracted first (duplicated in `planMyDay` and privately in `DayPlanRefiner`).*
- Gates find the next viable slot instead of rejecting — *blocked: nothing.*
- Split get-ahead into separate prep and due-soon kinds — *blocked: nothing.*
- Batch same-hour deadlines into one notification — *blocked: nothing.*
- ~~Fix idle's suppression rule~~ — **done Jul 2026** (batch cycle `2026-07-30-02`): the event-window check is gone; idle's activity test reads only real activity (session started / task completed).
- ~~Remove the break-it-down kind entirely~~ — **done Jul 2026** (batch cycle `2026-07-30-02`): kind, builder, category, `tappedBreakDown`, toggle and Settings row all removed; `deadlinePrepNotificationsEnabled` survives as a deprecated tombstone column only.
- Custom quiet hours can swallow the morning prompt — its budget-exempt status is now load-bearing in a way it wasn't — *blocked: nothing.*

## 3 — Features, designed but unbuilt

Designed in conversation, nothing written. Each needs a `DESIGN.md` check
before it starts — these are all user-facing.

- Study tasks auto-created from exam events: coarse prep-lead-time band from the classifier, announced in chat, deduped against a task the user already made, deletions tombstoned rather than regenerated — *blocked: nothing; fully specified in `DESIGN.md`.*
- Task-outcome retrospectives — "how did your exam go?" with a few options — feeding future nudge copy and prep lead times. **The app's only signal about whether interventions actually work**; everything else measures notification engagement — *blocked: nothing.*
- AI-generated nudge copy at scheduling time with a deterministic fallback — *blocked: nothing, but it sits against the AI-at-the-edges rule; the fallback is what makes it legal.*
- Personal goals filling spare capacity in Plan My Day — *blocked: nothing.*
- Interactive chat surface in the Tasks tab — *blocked: nothing.*
- Contextual AI message on nudge tap (morning state buttons, idle "not yet") — *blocked: nothing.*
- Conversational feedback questions in chat, framed during a stated calibration period — *blocked: nothing.*
- Batched AI classification for calendar imports — *blocked: nothing.*
- AI policy-setter: reads outcome data daily, writes timing parameters the arbiter executes — *blocked: outcome data (section 1); the arbiter still executes deterministically, which is what keeps this within the design rule.*
- Time-shift before backoff; per-kind strike rates rather than streaks — *blocked: outcome data (section 1).*
- Retire AI Refine as a button — deterministic planner always runs, AI advises — *blocked: nothing.*
- Onboarding: semester dates asked once; more conversational — *blocked: nothing.*
- Weekly prompted capture for week-by-week professors — *blocked: nothing.*
- Three pigeon mascots (nudges, brain dump, tasks-tab chat) — *blocked: assets.*

## 4 — UI and structure

- ~~Tasks tab sections: Overdue → Today's plan → Open tasks → Events~~ — **superseded and done** (cycle 2026-08-01-05): replaced by the tab strip (Unscheduled / Today / Events / Overdue) below Start Session.
- Vanishing-task bug: a task placed on a past day still carries a stale placement — needs a rollover sweep — *blocked: nothing; presentation half fixed by the tabs (a stale-placed task now shows in Unscheduled), so this is no longer data-loss-shaped, but the stale `plannedStartDate` remains until the sweep exists.*
- Deleted-tasks section in Stats — *blocked: nothing.*
- Stakes visuals on the widget (app only today) — *blocked: nothing.*

## 5 — Bugs

- Widget event fetch is unsorted — can miss today's events when the window holds more than 20 — *blocked: nothing.*
- Widget mascot assets missing; companion widget renders empty — *blocked: assets (same as the mascots above).*
- "urgent" priority ghost value still emitted by the prompt — *blocked: nothing.*
- `DayPlanRefiner` and the widget skip the learned event-duration lookup — *blocked: nothing.*
- Xcode keeps reverting `queueDebuggingEnableBacktraceRecording` — *blocked: nothing; already re-disabled twice, so it needs a durable fix rather than a third.*
- `DailyStats` has live consumers and zero producers — *blocked: nothing.*
- Countdown text logic duplicated and disagreeing (48h app vs 72h widget) — *blocked: nothing.*
- `TaskSortComparator` doesn't know `sequenceIndex`; plan-first ordering is hand-bolted at seven sites — *blocked: nothing.*
- `inferCategory` can't emit "exam"; imported exams score 0.7 where chat-captured ones score 0.9 — *blocked: nothing; also a prerequisite for study tasks in section 3 being reliable.*
- `WidgetColors` hand-copies `NudgeTheme` with off-by-one RGB — *blocked: nothing.*
- The `#Preview` container in `ContentView.swift` is missing four models (`CompletedTaskRecord`, `TimeBlock`, `CategoryDurationStats`, `EventDurationStats`) — *blocked: nothing; previews-only, but it's one of the three hand-synced schema lists.*
- The classifier's morningPrompt branch matches **any** `NudgeTask` created in the window, so a task captured coincidentally at that hour is indistinguishable from a response to the prompt — *blocked: nothing; it degrades the outcome data section 1 is waiting on.*

## 6 — Pre-release cleanup

Nothing here blocks development; all of it blocks shipping.

- Remove `TEMP-STAKES-DUMP` and the PII-heavy DEBUG logs — *blocked: nothing; must happen before any external build.*
- The three dead-code waves from the liveness survey — *blocked: nothing.*
- Test-data cleanup mechanism — *blocked: nothing.*
- 1024×1024 app icon for TestFlight — *blocked: asset.*
