# Drift report: docs, diagrams, code

Written 2026-10-06 against commit `ede6774` (dated 2026-10-04, `main`). Report only. Nothing in the docs, the diagrams or the code was changed.

**Compared:** `CLAUDE.md`, `ARCHITECTURE.md`, `DESIGN.md`, `docs/plan/CONTEXT.md`, the 61 files in `docs/diagrams/` (54 `.mmd`, 7 `.html` including the step tables and prose on each page), and the Swift code in the four targets.

**Method:** every checkable claim (a file, function, constant, order, count, "only", "every") was looked up in the code. Roughly 1,500 claims were checked. Each entry below names both sides with file and line, what the code does, and which side is wrong.

**How to read an entry:** entries are grouped by the file that is wrong, because that is the file you would change. "Confidence: medium" is marked where it applies; everything else is high.

## Summary

| Where the error is | Entries |
|---|---|
| Working tree (not a doc) | 1 |
| `CLAUDE.md` | 11 |
| `ARCHITECTURE.md` | 38 |
| `docs/plan/CONTEXT.md` | 13 |
| `DESIGN.md` | 4 |
| Diagrams | 30 |
| Code breaks a rule the docs state | 8 |

The diagrams are the most accurate of the three. Most diagram errors are omissions from a list that claims to be complete. Most doc errors are text that was true before Sep 23 to Oct 4 and was not updated.

The six that matter most:

1. **W-1.** The uncommitted change in `TodayTimelineView.swift` is a stray keystroke that breaks the build.
2. **C-5 / A-2.** "The arbiter is the only scheduling site in the app" is false. The snooze re-add and the Settings test notification also add requests.
3. **R-1.** The goal-lapse toggle is missing from `notificationToken`, so flipping it does nothing until something else runs the arbiter.
4. **X-2 / X-4.** `CONTEXT.md` says two targets and a flat 5-minute placement lead. The project has four targets and the lead is 60 / 15 / 5 by stakes. The planner reads only this file.
5. **D-1 / D-2.** `DESIGN.md` says exactly four AI touchpoints and that exam study tasks are "not built". There are eight call sites, and study plans were built, then replaced by ask-first proposals.
6. **G-27 / G-28.** The task-lifecycle close-ups say the calendar window is 14 days and the commitment horizon is 7. The code says 180 and 14.

---

## W. Working tree

**W-1. Stray text in `TodayTimelineView.swift`**
- Working copy: `Nudge/Views/Components/TodayTimelineView.swift:123` reads `p/contextrivate var startTime: Date {`
- HEAD: `private var startTime: Date {`
- Wrong: the working copy. It is the only change in that file and it will not compile. No doc or diagram depends on it; `ARCHITECTURE.md:145` still matches HEAD.

---

## C. `CLAUDE.md` is wrong

**C-1. Widget target contents**
- Doc: `CLAUDE.md:10` "widgets, Control Center control, Live Activities"
- Against: `ARCHITECTURE.md:225-226` (control "not in the bundle"), `docs/diagrams/index.mmd:132` ("two widgets and the Live Activity view")
- Code: `NudgeWidget/NudgeWidgetBundle.swift:14-16` registers `NudgeTaskWidget`, `NudgeCompanionWidget`, `TaskLiveActivityView` and nothing else.
- Wrong: `CLAUDE.md`. No control ships and there is one Live Activity.

**C-2. Deployment target**
- Doc: `CLAUDE.md:14` "iOS deployment target is 26.4"
- Against: `docs/diagrams/system-context.mmd:35-36` (monitor and report "iOS 26.5")
- Code: `Nudge.xcodeproj/project.pbxproj:727, 786` (26.4, project level); `:565, 595` and `:625, 655` (26.5 for the two Screen Time extensions).
- Wrong: `CLAUDE.md`, incomplete. The extensions build with the app scheme, so the real Xcode floor is 26.5.

**C-3. `--local-only` eval coverage**
- Doc: `CLAUDE.md:67` "runs the free half of the eval (arbiter and editor cases)"
- Code: `Nudge/Services/EvalHarness.swift:110-124` skips only `capture` cases; `import` cases run.
- Wrong: `CLAUDE.md`, omits import.

**C-4. Gate list**
- Doc: `CLAUDE.md:85` "busy windows …, quiet hours, daily budget, spacing, per-task fatigue"
- Against: `docs/diagrams/notification-flow-arbiter.mmd:12-17` (six checks, in order)
- Code: `Nudge/Services/NudgeArbiter.swift:2716-2787` has six checks in `passesGates`: active session, cooldown, quiet hours, busy windows, another task's planned slot, fatigue. Budget and spacing are in `pickWinners` (`:4016`).
- Wrong: `CLAUDE.md`. It omits three gates and lists two things that are not gates. `ARCHITECTURE.md:161` and `CONTEXT.md:76-94` say "five" because they fold the planned-slot check into busy windows; that is grouping, not an error.

**C-5. "The arbiter is the ONLY scheduling site inside the app process"**
- Doc: `CLAUDE.md:90`. Same claim at `ARCHITECTURE.md:16` ("the arbiter registers every request") and `ARCHITECTURE.md:161` ("the only scheduling site").
- Against: `docs/diagrams/index.mmd:124`, `docs/diagrams/notification-flow.mmd:5`, `docs/diagrams/system-context-notifications.mmd:37` (four add sites).
- Code: `UNUserNotificationCenter.add` is called at `Nudge/Services/NudgeArbiter.swift:4129`, `Nudge/Services/NudgeNotificationService.swift:133` (`sendTestNotification`, called from `Nudge/Views/Tabs/SettingsTabView.swift:90`, not DEBUG-gated), `NudgeNotificationService.swift:403` (`rescheduleSnoozed`, id `<original>.snoozed`), and `NudgeActivityMonitor/DeviceActivityMonitorExtension.swift:106`.
- Wrong: both docs. The diagrams are right. The arbiter is the only site that decides what to schedule; it is not the only site that adds a request.

**C-6. Tap routing**
- Doc: `CLAUDE.md:90` "The morning prompt's tap routes to Home chat; everything else routes to Tasks." Same at `ARCHITECTURE.md:90-92`.
- Against: `docs/diagrams/notification-flow-delivery.mmd:32` ("stats for category.mirror, home for morningPrompt, else tasks")
- Code: `Nudge/Services/NudgeNotificationService.swift:290-292`.
- Wrong: both docs. The mirror tap goes to Stats (since Sep 25).

**C-7. `#Preview` container**
- Doc: `CLAUDE.md:99` "already missing `CompletedTaskRecord`, `TimeBlock`, `CategoryDurationStats`, `EventDurationStats`"
- Code: `Nudge/ContentView.swift:444-470` lists all 18 models, the same set and order as `Nudge/Services/SharedModelContainer.swift:34-52` and `NudgeWidget/NudgeWidget.swift:268-286`. The comment at `ContentView.swift:447-448` says the drift was fixed in Jul 2026.
- Wrong: `CLAUDE.md`.

**C-8. Widget intents and the store**
- Doc: `CLAUDE.md:101` "Widget App Intents (`CompleteTaskIntent`, `FocusSessionIntents`) write back through the shared store"
- Against: `docs/diagrams/session-lifecycle-widget.mmd:47`, `docs/diagrams/system-context-widget.mmd:41`
- Code: `NudgeWidget/FocusSessionIntents.swift:35-46` touches ActivityKit, one App Group key and WidgetKit. No `ModelContext`. Only `NudgeWidget/CompleteTaskIntent.swift:29-98` writes the store.
- Wrong: `CLAUDE.md`, true for `CompleteTaskIntent` only.

**C-9. "(Haiku)"**
- Doc: `CLAUDE.md:106` "All Anthropic calls live in `ClaudeService` (Haiku)."
- Against: `ARCHITECTURE.md:159`, `CONTEXT.md:124, 145, 158, 171`, `docs/diagrams/copy-sequence.html:399`
- Code: `Nudge/Services/ClaudeService.swift:40` (Haiku), `:63` (capture, `claude-sonnet-5`), `:69` (`memoModel`, `claude-opus-5`), `:74` (`copyModel`, `claude-sonnet-5`). Four of the eight request functions are not Haiku.
- Wrong: `CLAUDE.md`. "All calls live in `ClaudeService`" still holds.

**C-10. How the planners write placements**
- Doc: `CLAUDE.md:107` "Both write placements only through … (`setPlanStart(auto: true)`, `releaseAutoPlan`)"
- Against: `docs/diagrams/task-lifecycle-planner.mmd:39, 41` ("auto: isToday"), `ARCHITECTURE.md:172`
- Code: `Nudge/Services/DayPlanEngine.swift:489` passes `auto: isToday`, so future-day placements are written as manual. `Nudge/Services/DayPlanRefiner.swift:198` uses `auto: true` and never calls `releaseAutoPlan`.
- Wrong: `CLAUDE.md`.

**C-11. Refiner "cached once per day"**
- Doc: `CLAUDE.md:107`. `ARCHITECTURE.md:169` says "cached daily unless forced".
- Code: `Nudge/Services/DayPlanRefiner.swift:49-54` skips the call only when `force == false`. The only production caller, `Nudge/Views/Tabs/HomeTabView.swift:766-769`, passes `force: true`.
- Wrong: `CLAUDE.md`. In practice every plan-intent message makes an API call. `ARCHITECTURE.md` is literally right but hides that the cache path is never taken.

See also R-2 and R-3 (`CLAUDE.md:100` and `:112` state rules the code breaks) and A-36 (`CLAUDE.md:33`).

---

## A. `ARCHITECTURE.md` is wrong

### Data flow and invariants (lines 1 to 101)

**A-1. Model tiering in the overview**
- Doc: `ARCHITECTURE.md:12` "capture on Sonnet 5 …, the Tasks-tab memo and plan proposals on Opus 5, everything else Haiku"
- Against: `ARCHITECTURE.md:159` ("`copyModel` = Sonnet 5")
- Code: `Nudge/Services/ClaudeService.swift:74`, used at `:1020`.
- Wrong: line 12. Notification copy is on Sonnet 5.

**A-2. "The arbiter registers every request" / "the only scheduling site"**
- Doc: `ARCHITECTURE.md:16` and `:161`. See C-5.

**A-3. "The widget compiles all of `Nudge/Models/`"**
- Doc: `ARCHITECTURE.md:57-58`
- Against: `docs/diagrams/system-context.html` Targets table ("26 in Models, NudgeTheme.swift and Services/SharedModelContainer.swift")
- Code: `Nudge.xcodeproj/project.pbxproj:105-134`. 26 of the 27 Models files; `Models/DistractionSettings.swift` is only in the two Screen Time lists (`:147`, `:154`).
- Wrong: `ARCHITECTURE.md`. The system-context page is exact. `docs/diagrams/task-lifecycle.mmd:121` is wrong the other way (G-33).

**A-4. Tap routing "special-cases `.morningPrompt` only"**
- Doc: `ARCHITECTURE.md:90-92`. See C-6.

**A-5. Bundle section covers two of four targets**
- Doc: `ARCHITECTURE.md:100-101` lists `Nudge/Info.plist` and `NudgeWidget/Info.plist`; "both targets read the App Group `UserDefaults`"
- Against: `docs/diagrams/system-context.html:175`
- Code: `NudgeActivityMonitor/DeviceActivityMonitorExtension.swift:33, 53` also read App Group defaults. `NudgeActivityMonitor/` has no `PrivacyInfo.xcprivacy`.
- Wrong: `ARCHITECTURE.md`, incomplete. Whether the extension needs its own privacy manifest was not established. Confidence: medium.

### App entry and tabs (lines 103 to 120)

**A-6. Foreground ordering**
- Doc: `ARCHITECTURE.md:106` "purge → `PlacementRollover` → `ExamPrepSweep` → `PlanProposalSweep` (async) → arbiter → calendar refresh → auto-plan → arbiter again if placed"
- Against: `docs/diagrams/notification-flow.mmd:319, 327`, `docs/diagrams/notification-flow-triggers.mmd:21-22`
- Code: `Nudge/ContentView.swift:181` (`syncIfActivityDismissed` runs first), `:204` (outcome classification), then `:273-288`: after auto-plan, `NudgeCopyGenerator.generateIfNeeded` runs and a third `reevaluate` follows if copy was written.
- Wrong: `ARCHITECTURE.md`. The chain stops one step short (since Oct 4).

**A-7. `HomeTabView` "owns plan supersession and the capture write rules"**
- Doc: `ARCHITECTURE.md:114`
- Against: `ARCHITECTURE.md:150` (moved to `CaptureWriter`), `docs/diagrams/capture-sequence.html:409-410`
- Code: `Nudge/Services/CaptureWriter.swift:47-52` (supersession), `:126-181` (DUE vs START), `:246` (the `CAPTURE:` line). `Nudge/Views/Tabs/HomeTabView.swift:497` only calls `CaptureWriter.apply`.
- Wrong: line 114. It was not updated after the Sep 23 move.

**A-8. Tasks-tab chip names and order**
- Doc: `ARCHITECTURE.md:115` "Four tabs: Unscheduled, Today, Events, Overdue"
- Code: `Nudge/Views/Tabs/TasksTabView.swift:1134-1144`. Order is Tasks, Events, Unscheduled, Overdue. The first chip reads "Tasks"; "Today" is a lens inside it.
- Wrong: `ARCHITECTURE.md` (stale since Sep 21).

**A-9. `scheduledTasks` no longer exists**
- Doc: `ARCHITECTURE.md:115` "`scheduledTasks` builds off `actionableTasks` …"
- Code: `TasksTabView.swift:570` mentions it only in a comment. The rule is in `Nudge/Models/NudgeTask.swift:286-299` (`dayTasks(among:on:)`).
- Wrong: `ARCHITECTURE.md`.

**A-10. `lists(on:)` is not the function the surfaces call**
- Doc: `ARCHITECTURE.md:115` "`lists(on:)` is the one membership function the tab, the widget, the calendar and the eval harness share"; `:192` "the single membership function"; `:116` "via the shared `NudgeTask.scheduledDay`"
- Against: `docs/diagrams/task-lifecycle.mmd:285` (draws the calendar fed from the `lists(on:)` box; also wrong, G-30)
- Code: the only callers of `lists(on:)` are `Nudge/NudgeApp.swift:279` (DEBUG) and `Nudge/Services/EvalHarness.swift:789`. The Tasks tab uses `isUnscheduled` (`TasksTabView.swift:549`), `isOverdue` (`:1166`) and `dayLens`. The widget uses `dayLens` (`NudgeWidget/NudgeWidget.swift:468`). The calendar tests `planDay` / `anchorDay` inline (`Nudge/Views/Tabs/CalendarTabView.swift:175-180`).
- Wrong: `ARCHITECTURE.md`. The outcomes match today, but the calendar is a second copy of the rule.

**A-11. "Day lenses exclude" deadline tasks**
- Doc: `ARCHITECTURE.md:116`
- Against: `ARCHITECTURE.md:115` and `CLAUDE.md:33` (a task belongs to a day if its plan day or anchor day is that day)
- Code: `Nudge/Models/NudgeTask.swift:138-146`. `belongs(to:)` is true on the anchor day.
- Wrong: line 116. It predates the day model.

**A-12. "Remove from timeline" filed under the wrong file**
- Doc: `ARCHITECTURE.md:116` puts the timeline manage sheet in the `CalendarTabView` entry.
- Code: the sheet and the `clearPlanTime` call are in `TasksTabView.swift:2157, 2204, 2077`. `CalendarTabView.swift` has neither.
- Wrong: `ARCHITECTURE.md`. The behaviour described is right; the entry is wrong.

**A-13. Stats does not read `EngagementState`**
- Doc: `ARCHITECTURE.md:117` "Reads `DailyStats` / `CompletedTaskRecord` / `EngagementState`"
- Code: `Nudge/Views/Tabs/StatsTabView.swift:15-18` queries `NudgeTask`, `CompletedTaskRecord`, `DailyStats`, `DailySession`. It also reads `MissedSessionLog` (`:235`). No reference to `EngagementState`.
- Wrong: `ARCHITECTURE.md`.

### Components (lines 141 to 145)

**A-14. Composer priority chain**
- Doc: `ARCHITECTURE.md:144` "… → commitment announcement → goal invite → AI Refine rationale → resting"
- Code: `Nudge/Views/Components/TasksMessageBox.swift:618` commitment announcement → `:627` planner outcome → `:639` rationale → `:650` goal invite → resting.
- Wrong: `ARCHITECTURE.md`. Rationale outranks the goal invite and the planner-outcome state is missing. `CONTEXT.md:166` does name it.

**A-15. "Home owns capture"**
- Doc: `ARCHITECTURE.md:144` and `:150` ("the Home chat calls `apply(…)`"). `CONTEXT.md:118-119` says `ChatRouter` "fronts this site".
- Against: `docs/diagrams/capture-sequence.html:146` (send site 2)
- Code: `Nudge/Views/Tabs/TasksTabView.swift:2373-2397`. `createSessionItem` (the session picker's "Add your own", Sep 25) calls `ClaudeService.shared.sendChat` (`:2384`) and `CaptureWriter.apply` (`:2387`). `ChatRouter` is not referenced in that file.
- Wrong: both docs. The diagram is right. There are two capture entry points and the second skips the router.

### Services (lines 149 to 188)

**A-16. `apply` signature**
- Doc: `ARCHITECTURE.md:150` "`apply(response:allTasks:goalContexts:modelContext:)`"
- Against: `docs/diagrams/capture-sequence.html:217`
- Code: `Nudge/Services/CaptureWriter.swift:34-41` also takes `userMessage:` and `writeLog:`.
- Wrong: `ARCHITECTURE.md`. Low impact.

**A-17. Order of `task_updates` and `CaptureWriter.apply`**
- Doc: `ARCHITECTURE.md:150` Home "keeps everything after the rows exist (task_updates, follow-ups, save, sweeps, reevaluate)"
- Against: `docs/diagrams/capture-sequence.mmd` steps 7 and 8 ("apply task_updates", then "apply")
- Code: `Nudge/Views/Tabs/HomeTabView.swift:398` applies `task_updates`; `:497` calls `CaptureWriter.apply` afterwards.
- Wrong: `ARCHITECTURE.md`. Updates run before the new rows exist, not after.

**A-18. "overdue-or-skipped replace"**
- Doc: `ARCHITECTURE.md:150`
- Against: `docs/diagrams/capture-sequence.html:410` ("overdue or has slipped"), `CONTEXT.md:232`
- Code: `CaptureWriter.swift:89` tests `isOverdue || slipCount > 0`.
- Wrong: `ARCHITECTURE.md`, wording only. "Skipped" is the retired term.

**A-19. Reflow overflow "returns to Unscheduled"**
- Doc: `ARCHITECTURE.md:154`
- Against: `docs/diagrams/task-lifecycle.mmd:200`, `docs/diagrams/task-lifecycle-placement.mmd:48, 51` ("The day stays")
- Code: `Nudge/Services/TimelineReflow.swift:214-216` calls `clearPlanTime()`, which keeps `intendedDate` (`NudgeTask.swift:210-214`). `isUnscheduled` needs no plan day (`NudgeTask.swift:151`), so the row stays on today's list.
- Wrong: `ARCHITECTURE.md`. The code comment at `TimelineReflow.swift:20` and the result field name `unscheduled` (`:217`) carry the same old wording.

**A-20. "The only writer of `plannedDurationMinutes` outside the planners"**
- Doc: `ARCHITECTURE.md:154`
- Against: `docs/diagrams/task-lifecycle-placement.mmd:43, 46`
- Code: also written at `TasksTabView.swift:3729` (editor sets it to nil), `Nudge/Services/CalendarService.swift:515, 544` (via `setPlanStart`), and `TimelineReflow.swift:120` (`sessionStarted`).
- Wrong: `ARCHITECTURE.md`. Confidence: medium (depends how strictly "writer" is read).

**A-21. Snapshot written "after every arbiter pass"**
- Doc: `ARCHITECTURE.md:155`. Same at `CONTEXT.md:198-199`, `docs/diagrams/system-context-screentime.mmd:35`, `docs/diagrams/notification-flow.html:710`.
- Against: `docs/diagrams/notification-flow-arbiter.mmd:57` ("After scheduling it calls DistractionMonitor.writeSnapshot"), which is accurate.
- Code: `NudgeArbiter.swift:482` is the only call. The debounce return (`:357-364`) and the master-toggle-off return (`:372-377`) both exit before it.
- Wrong: both docs and the two diagram lines that say "every". With notifications off, no snapshot is written. The monitor extension does not read that toggle and keeps posting; `LimitDecider.decide` falls to `.random("snapshot is from another day")` (`Nudge/Models/DistractionSettings.swift:129-130`).

**A-22. `classifyStakes` is described but gone**
- Doc: `ARCHITECTURE.md:159` "`stakesRuleText` … shared with `classifyStakes` (which matches responses by index…)"
- Against: `CONTEXT.md:140-141` ("`classifyStakes` are gone")
- Code: no `classifyStakes` in any target. `stakesRuleText` is used only at `ClaudeService.swift:84, 110`.
- Wrong: `ARCHITECTURE.md`.

**A-23. Floater targeting rule**
- Doc: `ARCHITECTURE.md:161` "no deadline AND no fire-day-or-future `intendedDate`"
- Against: `CONTEXT.md:60` ("NO deadline and NO plan day"), `docs/diagrams/notification-flow.mmd:230`
- Code: `NudgeArbiter.swift:2042-2045`. The predicate is `dueDate == nil && intendedDate == nil`.
- Wrong: `ARCHITECTURE.md`. See X-3 for the second stale wording inside `CONTEXT.md`.

**A-24. "Idle and floater … no task named"**
- Doc: `ARCHITECTURE.md:161`
- Against: `ARCHITECTURE.md:163` (floater is among "the kinds that name something"), `docs/diagrams/copy-sequence.html:336`
- Code: the template names no task (`NudgeArbiter.swift:1964-1970`). The AI-written floater line is per task with `{task}` (`Nudge/Services/NudgeCopyService.swift:472-477`; brief at `ClaudeService.swift:958-959`), and `resolvedBody` swaps it in for every kind (`NudgeArbiter.swift:4214-4231`).
- Wrong: line 161 as a description of what is delivered. It is true only of the fallback template. **This one is a product decision:** the Sep 25 ruling (a named low-importance task trains ignoring) and the Oct 4 per-task floater line currently coexist.

**A-25. Placeholder list is one short**
- Doc: `ARCHITECTURE.md:163` "`{task}`, `{time}`, `{day}`, `{name}`, `{goal}`". Same at `CONTEXT.md:148`.
- Against: `docs/diagrams/copy-sequence.html:404`, `docs/diagrams/notification-flow-copy.mmd:45, 54`, `docs/diagrams/notification-flow.mmd:307`
- Code: `NudgeCopyService.swift:409-411, 440, 443` request `{task} {due}`; `:549-555` fills `{due}`.
- Wrong: both docs. `{due}` arrived in commit `c1b50fb`.

**A-26. Copy triggers**
- Doc: `ARCHITECTURE.md:163` "Triggers: first foreground of a day, calendar import, prep sweep"
- Against: `docs/diagrams/copy-sequence.html:267`, `docs/diagrams/notification-flow-copy.mmd:43`
- Code: four call paths. `ContentView.swift:275-277` passes `.newDay`, or `.calendarImport` only when the foreground refresh imported at least one event. `Nudge/Services/ExamPrepSweep.swift:373` and `Nudge/Services/PlanProposalSweep.swift:567-569` pass `.generatedWork`. A manual import in the Calendar tab does not call the generator.
- Wrong: `ARCHITECTURE.md`. It omits the plan-accept trigger and "calendar import" is narrower than it reads.

**A-27. `StartByPlanner` "both branches inherit the deadline's clock time"**
- Doc: `ARCHITECTURE.md:165`
- Code: `Nudge/Services/StartByPlanner.swift:69` (deep branch: whole days back, keeps the clock); `:85-86` (shallow branch: `due − effortHours × (1 + buffer)`, an hour offset).
- Wrong: `ARCHITECTURE.md`. Only the deep branch keeps the clock. Confidence: medium.

**A-28. `PlanProposalSweep` callers**
- Doc: `ARCHITECTURE.md:170` "Runs after `ExamPrepSweep` in both foreground chains, after a capture, after either import."
- Code: also `TasksTabView.swift:847` (task created), `:865` (task edited), `:2396` (`createSessionItem`). `runIfNeeded` returns early when the message box is off (`PlanProposalSweep.swift:315`), which the entry does not say.
- Wrong: `ARCHITECTURE.md`, incomplete. The capture-sequence page has its own gap here (G-5).

**A-29. Planner second tier**
- Doc: `ARCHITECTURE.md:172` "tasks intended for this day"
- Code: `Nudge/Services/DayPlanEngine.swift:245-249` tests `belongs(to: day)`, so a task due that day is in this tier too.
- Wrong: `ARCHITECTURE.md`, wording predates the day model. Confidence: medium.

**A-30. `pickTopOpenTask` is dead**
- Doc: `ARCHITECTURE.md:174` "`pickTopOpenTask` is plan-first."
- Against: `docs/diagrams/notification-flow.html:748` (no-effect list)
- Code: `NudgeNotificationService.swift:362` is a private forwarder with no caller. "Not yet" calls `NudgeTask.topOpenTask` directly at `:249`.
- Wrong: `ARCHITECTURE.md`.

**A-31. `AppOpenLog` "solely so the classifier can answer…"**
- Doc: `ARCHITECTURE.md:178`
- Against: `docs/diagrams/notification-flow-outcomes.mmd:28`
- Code: `NudgeArbiter.swift:2121` reads `AppOpenLog.timestamps().last` in the come-back builder.
- Wrong: `ARCHITECTURE.md`. The log now feeds a scheduling decision.

**A-32. `countsSlips` "excludes only generated rows"**
- Doc: `ARCHITECTURE.md:182`
- Code: `NudgeTask.swift:133-135` also excludes events.
- Wrong: `ARCHITECTURE.md`. Harmless; events carry no plan.

### Models and widgets (lines 192 to 228)

**A-33. `NudgeTask` entry contradicts itself**
- Doc: `ARCHITECTURE.md:192` opens with "`skipCount` / `isSkipCandidate` / `isSkipped`" and later says "`isSkipped` is gone". It calls `prepLeadDays` "a deprecated tombstone column" and later "(3/7/14 band, exam events only)".
- Code: no `isSkipCandidate` or `isSkipped` in any target. `NudgeTask.swift:436-440` marks `prepLeadDays` a tombstone that nothing reads or writes.
- Wrong: the opening clause and the "Also:" clause. The later sentences match the code.

**A-34. `TaskStakes` "Data-only"**
- Doc: `ARCHITECTURE.md:203` "Data-only: nothing in scoring consumes it yet"
- Against: `ARCHITECTURE.md:161` (lead "by STAKES") and `:172` ("strictly-lower-stakes auto eviction")
- Code: `NudgeArbiter.swift:2419` (stakes sets a fire time); `DayPlanEngine.swift:337-364` (displacement by stakes rank).
- Wrong: line 203. "Nothing in scoring" holds only for `EisenhowerScorer`; "Data-only" is false. `Nudge/Models/TaskStakes.swift:24` has the same stale comment.

**A-35. Four models described as live are unused**
- Doc: `ARCHITECTURE.md:209` (`CheckIn`), `:211` (`DailyStats`), `:214` (`NotificationEvent`), `:215` (`SentNotificationFlag`). Only `:206` (`TimeBlock`) says "unused".
- Code: `CheckIn`, `NotificationEvent`, `SentNotificationFlag` are referenced nowhere outside their own files and the three schema lists. `DailyStats` is fetched (`StatsTabView.swift:17`, `Nudge/Services/EngagementTracker.swift:173-179`) but never constructed or inserted.
- Wrong: `ARCHITECTURE.md`. See R-8 for the `DailyStats` consequence.

**A-36. "Plans are written only through" the five helpers**
- Doc: `ARCHITECTURE.md:192` and `CLAUDE.md:33`. Same in `docs/diagrams/task-lifecycle.mmd:35`, `docs/diagrams/task-lifecycle.html:117`, `docs/diagrams/index.mmd:111`.
- Code: three direct writes outside `NudgeTask.swift`: `Nudge/Services/PlacementRollover.swift:123` (`intendedDate = nil` on a complete row), `TimelineReflow.swift:106, 109` (`plannedDurationMinutes = minutes`), `TasksTabView.swift:3729` (`plannedDurationMinutes = nil`).
- Wrong: both docs and the three diagram lines, as absolutes. `task-lifecycle.mmd:226` draws the rollover write itself, so that diagram contradicts its own subgraph title.

**A-37. "The two Live Activities"**
- Doc: `ARCHITECTURE.md:216` and `:222` ("widgets + Live Activities")
- Against: `ARCHITECTURE.md:226` ("not registered in the bundle"), `docs/diagrams/session-lifecycle-widget.mmd:46` ("the only Live Activity in NudgeWidgetBundle")
- Code: the bundle registers only `TaskLiveActivityView`. `FocusSessionAttributes` is used only by the unregistered `NudgeWidget/NudgeWidgetLiveActivity.swift:31`; the only `Activity.request` is for `TaskActivityAttributes` (`Nudge/Services/LiveActivityManager.swift:51`).
- Wrong: lines 216 and 222.

**A-38. Three smaller items**
- `ARCHITECTURE.md:228` lists the removed kinds as "(prep, floater, placementLead, placementMissed)". `NudgeWidget/CompleteTaskIntent.swift:117` removes any `nudge.arb.` id containing the UUID; dueSoon ids carry one too (`NudgeArbiter.swift:1730-1732`). The list is incomplete.
- `ARCHITECTURE.md:223` says the widget's goal summary is gone. The provider still fetches active goals (`NudgeWidget/NudgeWidget.swift:488-492`) and builds a "Goal in motion" fallback row when the task list is empty (`:546-556`). Confidence: medium (the rendering of that row was not traced).
- No entry exists for `Nudge/Views/Settings/DevNotesView.swift` (262 lines, presented at `SettingsTabView.swift:308`). Every other `.swift` file in the four targets is named, and every path the doc names exists.

---

## X. `docs/plan/CONTEXT.md` is wrong

**X-1. Verification stamp**
- Doc: `CONTEXT.md:3` "Verified against the AI-writes-every-notification commit, Oct 4 2026"
- Code: that commit is `2c588b3`. Two later commits changed the copy call site without touching this file: `c1b50fb` (added `{due}`) and `ede6774` (row-level decode). `CONTEXT.md` was last changed in `2c588b3`.
- Wrong: the stamp is two commits old. Whether the `CLAUDE.md:20` same-commit rule applied is arguable, since the commits modified a call site and did not add or remove one.

**X-2. "Two targets"**
- Doc: `CONTEXT.md:25-26` "Two targets: the app and a widget extension"
- Against: `CLAUDE.md:7` ("Four targets"), `docs/diagrams/system-context.mmd:2`, and its own lines 192-207
- Code: `Nudge.xcodeproj/project.pbxproj:274, 296, 318, 340`. Four native targets.
- Wrong: `CONTEXT.md`.

**X-3. Floater target, second wording**
- Doc: `CONTEXT.md:246-247` "no-deadline tasks whose intent day (if any) has passed"
- Against: its own line 60 ("NO deadline and NO plan day")
- Code: `NudgeArbiter.swift:2042-2045`. Any `intendedDate` excludes the task.
- Wrong: lines 246-247. Line 60 is right.

**X-4. Placement heads-up lead**
- Doc: `CONTEXT.md:63` "`placementLead` | 5m before a timeline slot"
- Against: `ARCHITECTURE.md:161` ("high 60, medium 15, low 5"), `docs/diagrams/notification-flow.html:298` (builder table, "60 / 15 / 5 min … by stakes")
- Code: `Nudge/Services/NudgeConfig.swift:482-491`, used at `NudgeArbiter.swift:2419`.
- Wrong: `CONTEXT.md`. Five minutes is only the low or unclassified case.

**X-5. Fatigue rule**
- Doc: `CONTEXT.md:92` "suppress a task after 3 ignored nudges"
- Against: `docs/diagrams/notification-flow-arbiter.mmd:70` ("ignored or dismissed … in 14 days")
- Code: `NudgeArbiter.swift:3013` counts `ignored` or `dismissed`.
- Wrong: `CONTEXT.md`, incomplete. No live effect while the gate is off.

**X-6. `statedUrgency` readers**
- Doc: `CONTEXT.md:132-133` "inside the idle, prep, and floater builders"
- Against: `docs/diagrams/notification-flow.mmd:258-259`
- Code: also `NudgeArbiter.swift:2688` (`placementImportance`, called from both placement builders at `:2429`, `:2582`), `DayPlanEngine.swift:608`, `DayPlanRefiner.swift:236`.
- Wrong: `CONTEXT.md`. Five builders and both planners read the AI signal.

**X-7. "One batched call a day"**
- Doc: `CONTEXT.md:146`
- Against: `ARCHITECTURE.md:163` ("one … call a day, plus real shifts"), `docs/diagrams/copy-sequence.html:144` ("at most 6 times a day, normally once")
- Code: `NudgeCopyService.swift:263-286`; `NudgeConfig.swift:655` (`copyGenMaxPerDay = 6`), 15-minute minimum gap.
- Wrong: `CONTEXT.md`. Confidence: medium (it may have meant the baseline).

**X-8. Placeholder list**: `CONTEXT.md:148`. See A-25.

**X-9. Plan-reader cap**
- Doc: `CONTEXT.md:171-173` "one batched call, at most `planProposalCallsPerDay` (2) a day"
- Against: `docs/diagrams/capture-sequence.html:149` ("at most 2 sweep calls a day … requestPlan runs when the user says yes")
- Code: `PlanProposalSweep.swift:317` checks the cap only in `runIfNeeded`. `requestPlan` (`:395-432`) has no cap check.
- Wrong: `CONTEXT.md`. The cap binds the sweep, not the chat-consent path.

**X-10. Snapshot "after every pass"**: `CONTEXT.md:198-199`. See A-21.

**X-11. What the message-box switch stops**
- Doc: `CONTEXT.md:210-213` "Off hides the box and stops its three AI call sites"
- Code: `PlanProposalSweep.swift:315` gates only `runIfNeeded`. `requestPlan` (`:395-432`) does not read `tasksMessageBoxEnabled`. The memo (`TasksTabView.swift:285`) and the hook (`:181`) are gated as stated.
- Wrong: `CONTEXT.md`. With the box off, a chat "yes" still makes the Opus call. Confidence: medium.

**X-12. Write-only toggles**
- Doc: `CONTEXT.md:256-259` "four legacy notification toggles"
- Against: `docs/diagrams/notification-flow.mmd:78` (lists eight)
- Code: `Nudge/Models/UserProfile.swift:174-198`. `smartNotificationsEnabled`, `streakNotificationsEnabled`, `reEngagementNotificationsEnabled` and `milestoneNotificationsEnabled` also have no reader outside the model.
- Wrong: `CONTEXT.md`, undercounts by four.

**X-13. Omission: the message box is off by default**
- Doc: `CONTEXT.md:158-159` (memo is "the box's standing voice"); `ARCHITECTURE.md:144` ("the app's only place to speak")
- Code: `UserProfile.swift:131` `tasksMessageBoxEnabled: Bool = false`; `ContentView.swift:136-142` flips existing stores to off once.
- Wrong: neither side states a falsehood. The "eight live call sites" census reads as if all eight run by default; three do not.

Also in `CONTEXT.md`: the single-entry capture claim at `:118-119` (A-15).

---

## D. `DESIGN.md` is wrong

**D-1. "Exactly four AI touchpoints"**
- Doc: `DESIGN.md:55-62`, and "Everything downstream is arithmetic: ranking, planning, notification timing."
- Against: `CONTEXT.md:110` ("Eight live call sites"), `docs/diagrams/capture-sequence.html:145-152` (eight send sites)
- Code: eight request functions at `ClaudeService.swift:364, 645, 690, 761, 947, 1127, 1239, 1396`. `refineDayPlan` (`:690`) is AI planning. `analyzeTask` (`:645`) feeds importance scoring. The plan reader is a third site outside the four.
- Wrong: `DESIGN.md` as a description of the shipped app. Notification timing is still deterministic. If the four are meant as intent, the code has moved past it and that is your call.

**D-2. "Study tasks from exam events: not built as of this writing"**
- Doc: `DESIGN.md:89-108` (lead-time band, "create study tasks daily until the exam")
- Against: `CONTEXT.md:260-265`, `ARCHITECTURE.md:170-171`, `docs/diagrams/task-lifecycle-generated.mmd:38, 40`
- Code: `ExamPrepSweep.swift:350-389` runs only the commitment phase. Study sessions come from `PlanProposalSweep.swift:527-570` (written on Yes) or `:395` (chat consent). `prepLeadDays` is a dead column.
- Wrong: `DESIGN.md`. It was built, then replaced on Sep 16 by ask-first proposals. The tombstone and user's-own-task bullets still hold.

**D-3. "Missed deadlines get rescheduled with more urgency"**
- Doc: `DESIGN.md:126`
- Against: `DESIGN.md:148-152` and `CLAUDE.md:33` (a slipped plan day is re-planned once, then released)
- Code: `PlacementRollover.swift:119-128` re-plans only the plan day. No code moves a deadline. Missed app-made sessions are deleted and counted in `MissedSessionLog`.
- Wrong: `DESIGN.md`. Confidence: medium. The "Sessions missed" stat and the "Slipped N days" label also sit in tension with the no-shame section; that is a product call.

**D-4. "The planner is the only automatic writer of plans"**
- Doc: `DESIGN.md:155-156`
- Code: other automatic plan writers: `CalendarService.swift:512-544` (import), `PlacementRollover.swift:100, 128` (re-plan to today), `PlanProposalSweep.swift:562` (session days), `CaptureWriter.swift:177-179` (deadline today, dateless plan item), `TimelineReflow.swift:171, 221` (pushes). `DayPlanEngine.swift:489` writes future-day placements as manual.
- Wrong: `DESIGN.md`. Several of these mark their writes manual, so app-made placements also survive the planner's undo.

---

## G. Diagrams are wrong

### Index

**G-1. Commit date**
- Diagram: `docs/diagrams/index.mmd:2`, `docs/diagrams/index.html:93, 119` "ede6774 (2026-10-06)"; `docs/diagrams/task-lifecycle.mmd:2`, `docs/diagrams/task-lifecycle.html:91` "(2026-10-05)"
- Against: `docs/diagrams/notification-flow.mmd:2` "(2026-10-04)"
- Code: `git log -1 ede6774` gives 2026-10-04.
- Wrong: index and task-lifecycle. Those are drawing dates written as the commit's date.

**G-2. Rollover "at 6 AM"**
- Diagram: `docs/diagrams/index.mmd:113`, `docs/diagrams/index.html:230`
- Against: `docs/diagrams/task-lifecycle-rollover.mmd:43` ("It does not run the rollover…"), `ARCHITECTURE.md:182`
- Code: `Nudge/NudgeApp.swift:162-176`. `handleDailyRecalc` runs purge, `reevaluate(.backgroundTask)` and the retired-notification cleanup. `PlacementRollover.sweep` is called only at `ContentView.swift:121, 193`.
- Wrong: the index. The close-up is right.

Everything else on the index checked out: all 32 artifact links match each set's first line, all ten node ids and both step ranges cited in `index.html:305-311` exist, and the claims at `index.mmd:131-137` (18 model types, one defaults domain, two network services) match the code. `index.mmd:111` is covered by A-36.

### Capture sequence

**G-3. "The widget reads only…"**
- Diagram: `docs/diagrams/capture-sequence.html:528, 536`; `docs/diagrams/capture-sequence-5-widget.mmd:13`
- Code: `NudgeWidget/NudgeWidget.swift:488-492` also fetches active `NudgeGoal` rows; a second task fetch for slots is at `:508-516`.
- Wrong: the diagram. The "only" list is incomplete.

**G-4. `runIfNeeded` drawn as read-and-propose only**
- Diagram: `docs/diagrams/capture-sequence.html:718`; `docs/diagrams/capture-sequence-9-plans.mmd:17-26`
- Code: `PlanProposalSweep.swift:310` calls `applyUserPlanOverrides` first, before the message-box check at `:315`. That function (`:216-250`) deletes app-made `source == "prep"` rows (`:235`).
- Wrong: the diagram. A delete on this path is missing, and it runs even with the box off.

**G-5. When the plan reader runs**
- Diagram: `docs/diagrams/capture-sequence.html:149` "Launch, every foreground, after a capture, after an iCal import"
- Code: callers are `ContentView.swift:130, 199`, `HomeTabView.swift:592`, `CalendarTabView.swift:986` (Apple Calendar), `:1031` (iCal), `TasksTabView.swift:847, 865, 2396`.
- Wrong: the diagram omits the Apple Calendar import and the three Tasks-tab calls. `ARCHITECTURE.md:170` omits the Tasks-tab calls (A-28).

**G-6. Step order in the commitment picture**
- Diagram: `docs/diagrams/capture-sequence-7-commitments.mmd:19` (step 7, "dailyMinutes, carryUnits", after the row inserts)
- Code: `ExamPrepSweep.swift:551` writes `dailyMinutes` before the rows are inserted (`:586-609`). Only `carryUnits` (`:685`) comes after.
- Wrong: the diagram. Low impact.

### Copy sequence

**G-7. "Study or commitment task"**
- Diagram: `docs/diagrams/copy-sequence.html:266`
- Against: `ARCHITECTURE.md:171`, `CONTEXT.md:260-261`
- Code: `ExamPrepSweep.swift:360`. `created` comes only from `commitmentPhase`; `noteShift` fires at `:373`.
- Wrong: the diagram. The same stale wording is in the code comments at `NudgeCopyService.swift:228` and `ExamPrepSweep.swift:365-370`.

**G-8. Wrong file on the Screen Time keys box**
- Diagram: `docs/diagrams/copy-sequence-9-screentime.mmd:7, 16, 22` ("Screen Time keys / DistractionSettings.swift")
- Code: the rung and mirror keys are declared at `NudgeActivityMonitor/DeviceActivityMonitorExtension.swift:24-26`.
- Wrong: the diagram. Confidence: medium, low impact.

### Notification flow

**G-9. Rung stamps "before deciding"**
- Diagram: `docs/diagrams/notification-flow-screentime.mmd:60`
- Code: `DeviceActivityMonitorExtension.swift:84` decides; `:86-87` write the stamps; `:90` returns on silent.
- Wrong: the diagram. The order is reversed. The stated consequence (a silent decision still advances the stamps) is correct.

**G-10. Who writes `CompletedTaskRecord`**
- Diagram: `docs/diagrams/notification-flow-outcomes.mmd:32` "the in-app checkbox, session completion and the widget intent"
- Code: two constructors only: `TasksTabView.swift:1922` and `NudgeWidget/CompleteTaskIntent.swift:64`. `SessionCoordinator.completeCurrentTask` (`Nudge/Services/SessionCoordinator.swift:170-217`) inserts no record.
- Wrong: the diagram. Confidence: medium.

**G-11. Home and the permission function**
- Diagram: `docs/diagrams/notification-flow-permission.mmd:14` (edge from `requestAuthorizationIfNeeded` to Home)
- Code: `HomeTabView.swift:165` calls `authorizationState()`. Only `Nudge/Views/Onboarding/OnboardingCompleteView.swift:163` and `SettingsTabView.swift:354` call `requestAuthorizationIfNeeded`.
- Wrong: the diagram edge. Confidence: medium, low impact.

**G-12. Wrong file on the day-change caller**
- Diagram: `docs/diagrams/notification-flow-triggers.mmd:6` (box "DayPlanEngine.swift / autoPlanIfNewDay" calling `reevaluate`)
- Against: `docs/diagrams/notification-flow.mmd:37` ("ContentView.swift / after autoPlanIfNewDay")
- Code: the calls are at `ContentView.swift:261, 283`. `DayPlanEngine.swift` has no `reevaluate` call.
- Wrong: the triggers close-up. Its own tooltip at `:22` links to `ContentView`.

**G-13. DEBUG callers of `reevaluate`**
- Diagram: `docs/diagrams/notification-flow.mmd:43` and `docs/diagrams/notification-flow.html:693` name `EvalHarness` and `CaptureHistoryExporter`. `docs/diagrams/notification-flow-overview.mmd:47` ("Everything that calls reevaluate") names no DEBUG callers.
- Against: `docs/diagrams/notification-flow-triggers.mmd:24` (also names `-nudge-import-ical`)
- Code: `EvalHarness.swift:213`, `Nudge/Services/CaptureHistoryExporter.swift:143`, `ContentView.swift:396`.
- Wrong: the main diagram omits one; the overview omits all three. DEBUG only.

**G-14. Three smaller items**
- `docs/diagrams/notification-flow-triggers.mmd:20-21` lists the launch and scene-active chains without `LegacyPriorityNormalizer.sweep` (`ContentView.swift:133`), the one-time message-box flip (`:138-142`), `backfillImportedScheduleOnce` (`:146`) or the leading `syncIfActivityDismissed` (`:181`). Confidence: medium (the tooltips do not claim to be complete).
- `docs/diagrams/notification-flow.mmd:314` says "write fire time per kind". `morningPromptHistory` stores the named task's UUID by day stamp (`NudgeArbiter.swift:4181-4182`).
- `docs/diagrams/notification-flow-delivery.mmd:30` lists action buttons by category without the still-registered `category.getAhead` (`Nudge/Services/NudgeNotificationCategories.swift:201-203`). The page's own no-effect list covers it (`notification-flow.html:753`).

### Session lifecycle

**G-15. Idle confirmation sheet drawn as a live caller**
- Diagram: `docs/diagrams/session-lifecycle-start.mmd:36`; `docs/diagrams/session-lifecycle.html:168, 310`
- Against: `ARCHITECTURE.md:161` ("The idle proposal sheet path is retired.")
- Code: `TasksTabView.swift:904-910` still declares the sheet. `idleProposedTaskID` is set only from `.nudgeIdleNotYetTapped` (never posted) and `pendingIdleTaskIDKey` (never written; read at `:953-958`). The "Not yet" action writes `tappedNudgeAnswerKey` instead (`NudgeNotificationService.swift:231, 260`).
- Wrong: the diagram. The route is unreachable and the page leaves it out of its own no-effect list (`session-lifecycle.html:581-591`).

**G-16. "Every path that ends the Live Activity"**
- Diagram: `docs/diagrams/session-lifecycle-end.mmd:2`; `docs/diagrams/session-lifecycle.html:335, 388`
- Against: `docs/diagrams/session-lifecycle.html:171` (lists the app-target intent as a `cancelSession` trigger)
- Code: `Nudge/Services/FocusSessionIntents.swift:34-40`. The app-target `EndFocusSessionIntent.perform` calls `cancelSession()`, which ends the activity (`SessionCoordinator.swift:338`). No view references it.
- Wrong: the end diagram and its table, against the page's own triggers table. Whether the intent is reachable from Shortcuts was not tested.

One ordering note, not an error: `docs/diagrams/session-lifecycle-sync.mmd` draws `endPassed` before `widgetEnded`; the guard at `SessionCoordinator.swift:277` tests `widgetEnded` first. The outcomes are identical.

### System context

**G-17. Beta header**
- Diagram: `docs/diagrams/system-context-network.mmd:40` "on the memo and plan calls"
- Against: `ARCHITECTURE.md:159` ("server-side refusal fallbacks" on capture)
- Code: `ClaudeService.swift:620` (capture body carries `fallbacks`), `:1505-1506` (header set when the body has it), `:1308` (memo), `:1452` (plan).
- Wrong: the diagram. Three calls carry the header.

**G-18. Schema list count**
- Diagram: `docs/diagrams/system-context.html:519` "the two schema lists"; `:221` "A third container exists only in DEBUG: the eval harness's in-memory one"
- Against: `CLAUDE.md:96-99`, `ARCHITECTURE.md:43-52` (three hand-synced lists)
- Code: `ContentView.swift:444-450` is a third hand-written list. `EvalHarness.swift:183-184` reuses `SharedModelContainer.schema`.
- Wrong: the diagram page. It omits the `#Preview` list.

**G-19. Widget intent list**
- Diagram: `docs/diagrams/system-context.html:189, 514`
- Code: `NudgeWidget/FocusSessionIntents.swift:22-30` also defines `PauseFocusSessionIntent`, a no-op no view references.
- Wrong: the diagram. It belongs in the page's no-effect list.

**G-20. `importCanvasICal` callers**
- Diagram: `docs/diagrams/system-context-network.mmd:41`
- Code: also `Nudge/Views/Onboarding/CalendarImportStepView.swift:116`. A DEBUG caller of `importFromImage` at `ContentView.swift:370` is not drawn either.
- Wrong: the diagram, incomplete.

### Task lifecycle

**G-21. Source and page have diverged**
- Diagram: `docs/diagrams/task-lifecycle.mmd:2` "the page renders an overview plus close-ups cut from this"
- Against: `docs/diagrams/task-lifecycle.html` embeds the eight close-ups only (blocks at `:120, 200, 256, 336, 408, 490, 582, 658`). The full source is dated Oct 5; the close-ups Oct 6.
- Wrong: neither on facts. G-27 and G-28 exist only in the close-ups, so the two are already not one text. The same is true of `notification-flow.mmd`, which its page does not embed.

**G-22. "Never carries a plan (I2)"**: `docs/diagrams/task-lifecycle-overview.mmd:42`. See R-4.

**G-23. "Plan tomorrow" door missing**
- Diagram: `docs/diagrams/task-lifecycle.mmd:43-45`, `docs/diagrams/task-lifecycle-overview.mmd:40`, `docs/diagrams/task-lifecycle-planner.mmd:18-20`, `docs/diagrams/task-lifecycle.html:179` (three entries into the engine)
- Against: `docs/diagrams/task-lifecycle.html:384` ("Four entries into the engine"), `ARCHITECTURE.md:172`
- Code: `TasksTabView.swift:1550-1552`. `planFutureDay` calls `DayPlanEngine.plan(day:)`, wired to a button at `:1520`.
- Wrong: the diagrams. The page caption and `ARCHITECTURE.md` are right.

**G-24. Capture dedupe**
- Diagram: `docs/diagrams/task-lifecycle-creation.mmd:30`; `docs/diagrams/task-lifecycle.html:321` ("matching title, same due day")
- Code: `CaptureWriter.swift:72-82`. A title match is substring containment either way. The due-day check runs only when both rows have a due date; otherwise the title alone matches.
- Wrong: the diagram, incomplete.

**G-25. `placeTask` "or a drag"**
- Diagram: `docs/diagrams/task-lifecycle-placement.mmd:41`; `docs/diagrams/task-lifecycle.html:471`
- Code: the only caller is `TasksTabView.swift:2283` (the placement sheet). No `onDrag`, `draggable`, `onDrop` or `DragGesture` in `TasksTabView.swift` or `TodayTimelineView.swift`.
- Wrong: the diagram.

**G-26. Two incomplete caller lists**
- `docs/diagrams/task-lifecycle-placement.mmd:45` and `task-lifecycle.html:453` list `startSession` callers without the widget deep link at `ContentView.swift:85`.
- `docs/diagrams/task-lifecycle-placement.mmd:42` and `task-lifecycle.html:479` say Remove from timeline is "offered in the editor". The main door is the manage-timeline sheet (`TasksTabView.swift:2198`), and Swap (`:2177`) calls it too. `ARCHITECTURE.md:116` is right on this.

**G-27. Calendar rolling window "14-day"**
- Diagram: `docs/diagrams/task-lifecycle-creation-auto.mmd:33`; `docs/diagrams/task-lifecycle.html:289, 315`
- Against: `ARCHITECTURE.md:179`, `CONTEXT.md:266` (180)
- Code: `CalendarService.swift:135`; `NudgeConfig.swift:548` (`calendarImportHorizonDays = 180`).
- Wrong: the diagram. The code comment at `CalendarService.swift:153` ("today + 21") is also stale.

**G-28. Commitment horizon "7 days"**
- Diagram: `docs/diagrams/task-lifecycle-creation-auto.mmd:40`; `docs/diagrams/task-lifecycle-generated.mmd:42`; `docs/diagrams/task-lifecycle.html:296, 316, 624`
- Against: `ARCHITECTURE.md:171` ("rolling 14-day window")
- Code: `NudgeConfig.swift:599` (`commitmentHorizonDays = 14`), used at `ExamPrepSweep.swift:548, 565`.
- Wrong: the diagram.

**G-29. `CompletedTaskRecord` readers**
- Diagram: `docs/diagrams/task-lifecycle-completion.mmd:2, 24-25` (two readers drawn); `:29` and `docs/diagrams/task-lifecycle.html:696` ("Stats and the classifier read CompletedTaskRecord, never isComplete")
- Code: also read at `NudgeArbiter.swift:1468` (idle) and `:2122` (come-back), `Nudge/Services/DistractionMonitor.swift:245`, `TasksMessageBox.swift:187`. And `StatsTabView.swift:58` does filter on `isComplete`.
- Wrong: the diagram, on both points. Confidence: medium.

**G-30. Four smaller items**
- `docs/diagrams/task-lifecycle.mmd:285` draws the calendar fed from the `lists(on:)` box. The calendar has its own inline copy (A-10).
- `docs/diagrams/task-lifecycle.mmd:35`, `task-lifecycle.html:117`: "the only writers of the plan" (A-36).
- `docs/diagrams/task-lifecycle.mmd:121`: "compiles Nudge/Models only" omits `NudgeTheme.swift` and `SharedModelContainer.swift` (A-3).
- `docs/diagrams/task-lifecycle-creation-auto.mmd:37`: anchors "L295" and "L456" point at the `NudgeTask(` init lines. The `applyImportedSchedule` calls are at `CalendarService.swift:311, 474`.

### Page versus source

- `session-lifecycle.html` and `system-context.html` embed an overview that differs from the `.mmd` file by one comment line each (`session-lifecycle.mmd:3`, `system-context.mmd:3`). No node, edge or tooltip differs.
- Every other embedded block is byte-identical to its `.mmd` file.

---

## R. The code breaks a rule the docs state

Here the docs (and usually the diagrams) agree on the rule and the code is the outlier.

**R-1. Goal-lapse toggle missing from `notificationToken`**
- Rule: `ARCHITECTURE.md:193` "A new toggle must also be added to `ContentView.notificationToken` or flipping it never reevaluates."
- Diagrams: `docs/diagrams/notification-flow-triggers.mmd:20` ("the nine per-kind toggles except goalLapse") and `docs/diagrams/notification-flow.html:757` both flag it.
- Code: `ContentView.swift:300-323` lists nine per-kind toggles. `goalLapseNotificationsEnabled` (`UserProfile.swift:122`, toggled at `SettingsTabView.swift:183`, read at `NudgeArbiter.swift:2245`) is absent.
- Effect: flipping "Goal check-in" changes nothing until some other trigger runs the arbiter.

**R-2. Inline `UserDefaults(suiteName:)`**
- Rule: `CLAUDE.md:100`, `ARCHITECTURE.md:149` "never construct `UserDefaults(suiteName:)` inline"
- Diagram: `docs/diagrams/system-context-widget.mmd:44` ("The widget opens the suite by name each time") describes the code correctly.
- Code: `NudgeWidget/NudgeWidget.swift:582`, `NudgeWidget/CompleteTaskIntent.swift:75`, `NudgeWidget/FocusSessionIntents.swift:41`. The widget compiles `SharedModelContainer.swift` but never uses it. `DeviceActivityMonitorExtension.swift:33, 53` do the same, but that target cannot see the shared accessor.
- Either the three widget sites are wrong or the rule needs scoping to the app target.

**R-3. Inline tunables**
- Rule: `CLAUDE.md:112`, `ARCHITECTURE.md:162` "Every tunable constant lives in `NudgeConfig`"
- Code: `DayPlanEngine.swift:180` (`preEventBuffer = 60 * 60`), `:314` (`spacing = 15 * 60`); `DistractionMonitor.swift:136, 140` (ladder multipliers 1.5, 1.75); the snooze `30 * 60` in `NudgeNotificationService.swift` just above `:398`.
- Confidence: medium on what counts as "tunable".

**R-4. Converting a task to an event keeps its plan**
- Rule: `ARCHITECTURE.md:192` "events never carry a plan (I2)"; `docs/diagrams/task-lifecycle-overview.mmd:42`; `DESIGN.md:153-154`
- Code: `TasksTabView.swift:2009-2013`. `setEventFlag` only sets `isInformationalEvent`. A placed task flipped to an event keeps `intendedDate` and `plannedStartDate`. The helpers guard only new writes (`NudgeTask.swift:181-182`).
- Confidence: medium. Whether readers ignore plan fields on events was not checked.

**R-5. A Canvas-named string on the generic iCal path**
- Rule: `ARCHITECTURE.md:116` (the link source is generic)
- Code: `CalendarTabView.swift:1015` `"Add a Canvas iCal URL before importing."`
- Confidence: medium.

**R-6. Account subtitle still says "plan"**
- Rule: `ARCHITECTURE.md:120` "No plan or tier"
- Code: `Nudge/Views/Tabs/AccountTabView.swift:22` subtitle "Your profile, plan, and setup summary."
- Confidence: medium.

**R-7. Chat-consent plan call ignores the message-box switch and the daily cap**: see X-9 and X-11.

**R-8. `DailyStats` is read but never written**
- Doc: `ARCHITECTURE.md:211` "Per-day counters for Stats."
- Code: no `DailyStats(` construction in any target. `StatsTabView.swift:17` and `EngagementTracker.swift:173-179` read an empty table on any fresh store.

**Stale code comments** (seen while checking; not in the docs):
`ClaudeService.swift:48-49` (copy "stays on Haiku"), `:945-946` and `:1050` (whole pass thrown away); `NudgeCopyService.swift:27-28, 520` (five placeholders), `:62-65, 134-137` (deadline "still ahead of the fire date"); `NudgeArbiter.swift:2013` (old floater rule); `TimelineReflow.swift:20` (Unscheduled); `CalendarService.swift:153` (today + 21); `TaskStakes.swift:24` (data-only).

---

## What was not checked

Each reader listed what it left unverified. Treat these as unknown, not as correct.

- **Not run:** the two `xcodebuild` commands and `eval/run.sh`.
- **Arbiter internals:** morning-prompt consecutive-day and stakes-tier rules; prep's bounded walk; goal-lapse "one candidate per run"; placementMissed "ends at midnight"; `pickWinners` seeding order.
- **Sweeps:** `ExamPrepSweep` front-loading, 23:59 dailies and carry caps; `applyUserPlanOverrides` internals; `DayPlanEngine` displacement internals; `movePlanTasks` renumbering.
- **Imports:** `CalendarService` rolling cursor; `ScreenshotCalendarImporter` dedupe; `ChatRouter` internals.
- **Project files:** entitlements and `Info.plist` claims on the diagram pages' Scope sections; pbxproj embed line anchors; most GitHub `#L` anchors in tooltips (those spot-checked matched).
- **Widget and extensions:** the report extension's Monday-to-Sunday window; whether the "Goal in motion" fallback row renders (A-38); whether the app-target `EndFocusSessionIntent` is reachable from Shortcuts (G-16).
- **Data claims:** `CLAUDE.md:29` (`.floater` shows `—` in outcome dumps) needs a device dump.
- **Three leads not chased:**
  1. A snoozed request's id (`<original>.snoozed`) does not appear to be added to the arbiter's tracked id list, so "cancels every notification it owns" may not cover it.
  2. `ARCHITECTURE.md:105` lists two DEBUG launch dumps; a third (`tempDumpVisibilityAudit`, `NudgeApp.swift:121, 255`) may be missing.
  3. Three empty directories exist: `Nudge/Views/Home`, `Nudge/Views/Stats`, `Nudge/Views/Tasks`.
