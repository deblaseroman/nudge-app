# Report — 2026-08-01-03 (item 4 of 4) — Study tasks from exam events

**Plan:** `archive/2026-08-01-03-plan.md` (§4)
**Status:** complete
**Commits:** see the item-4 commit on `automation-run-1` (this report is committed with it)

---

## What changed

**Classifier**
- `Nudge/Services/ClaudeService.swift` — both capture schemas emit
  `prepLeadDays` for exam-category EVENTS only: brain-dump prompt (rule +
  schema line + `TaskData.prepLeadDays`), screenshot prompt (schema field +
  rule + `ScreenshotEventJSON` + `ParsedScreenshotEvent`). Coarse bands
  spelled out in both prompts (3 = light/intro quiz, 7 = typical
  exam/midterm, 14 = final/cumulative/heavy subject), judged from the title
  alone; no web search.
- Tolerant decoding: `ExamPrepSweep.validLeadBand` accepts exactly
  {3, 7, 14}, everything else (null, 5, 0, 30) reads as "didn't say" → the
  sweep defaults to `NudgeConfig.defaultPrepLeadDays` (7). Applied at both
  write sites (`HomeTabView`, `ScreenshotCalendarImporter`).
- `Nudge/Models/NudgeTask.swift` — new optional `prepLeadDays: Int?`
  (additive, property-level default nil). Deterministic calendar imports
  never set it — no AI call there; those exams get the default band.

**Detection sweep + creation**
- `Nudge/Services/ExamPrepSweep.swift` (new) — runs from `ContentView` on
  cold launch and scene-active, beside `PlacementRollover` and BEFORE the
  arbiter reevaluate. For each open exam-category event within its band:
  one task per remaining day up to (not including) the exam day —
  `source = "prep"` (the prescription in `CalendarService`'s old comment),
  title "Study for <exam>", `linkedEventId` → the event, category exam,
  stakes high via `setStakesFromAutomation`, `estimatedMinutes` set
  explicitly from the exam category prior (120) so the duration is visible
  and editable. Due date is the bare study DAY (stored as start-of-day,
  read as end-of-day by `sortDeadline` — the app's existing convention).
  **Idempotent** by (exam, day-stamp); **capped** by construction
  (daysRemaining ≤ band ≤ 14, one per exam per day).
- The decision core (`decide`) is a pure `nonisolated static` over value
  inputs, so the fixture harness runs the exact shipped logic.

**Dedupe**
- `userStudyTaskMatch` (deterministic v1): a user's open non-prep task
  blocks ALL creation for an exam when its normalized title contains the
  exam's course token (adjacent word+number pair, "chem 101"), or contains
  a study word (study/review/prep/practice/revise/cram) AND shares a
  subject token with the exam title. **Honest misses, accepted:** nicknames
  ("orgo" for Organic Chemistry), study-intent synonyms without a study
  word ("go over notes"), misspellings. AI matching stays a later cycle.

**Deletion tombstone**
- `Nudge/Models/PrepTombstone.swift` (new `@Model`) — one row per deleted
  (exam, day); survives the task's removal. **Where it lives:** registered
  in all THREE schema lists (`SharedModelContainer.schema`, `widgetSchema`,
  the `#Preview` container) AND added to the widget target's
  `membershipExceptions` in project.pbxproj — a new Models file is
  invisible to the widget until that hand edit.
- Written by `ExamPrepSweep.recordDeletionIfPrep` from the Tasks tab's two
  real deletion sites (row swipe/`deleteTask`, editor `onDelete`), BEFORE
  the delete. The DEBUG wipe-everything helper deliberately does NOT
  tombstone (it resets a test store; poisoning every exam's sweep would
  defeat the reset).
- The sweep never recreates a tombstoned day (verified in fixtures below).

**Message box (sixth + seventh states)**
- `TasksMessageBox.swift` — two new composer states between high-stakes
  and the rationale ("above resting, below overdue" per the plan):
  1. tombstone note — "Do you still want study time for “X”?" with a
     factual detail (removed days stay removed, other days still listed).
     Per exam, never repeats: consumed on first RENDER (equality against
     the state's own copy builder detects that it actually won the
     priority contest, not merely existed), then freshness-windowed
     (`prepMessageFreshnessMinutes`, 30) so it doesn't vanish mid-read.
     Later deletions for an already-noted exam insert pre-stamped.
  2. announcement — "Your “Stats exam” is in 6 days — I've added study
     time each day until then." Created-today only, freshness-windowed
     after first render. Written by the sweep for the soonest exam that
     got tasks; silent creation is not acceptable (DESIGN.md).
- `TasksTabView` supplies both contexts (`@Query` on tombstones; App Group
  announcement) and the consumption callbacks.

**Interaction with item 1, decided here**
- `buildDueSoonCandidates` excludes `source == "prep"`: a study day's
  end-of-day due date is scaffolding the sweep invented, not a deadline
  the world enforces — without the exclusion every study day would end in
  a ~10 PM "due soon" banner for a synthetic midnight due. Prep tasks
  remain ordinary everywhere else: the morning prompt can name them
  (stakes high), `.prep` nudges fire on them (dueDate exists), both
  planners place them.

## Verification

- Both schemes build (`xcodebuild`, iOS Simulator): **Nudge** ✅,
  **NudgeWidgetExtension** ✅ — the widget build also proves the
  three-list schema registration and the pbxproj membership edit are
  consistent.
- **Fixture run per the plan's item-5 requirement** — `decide` extracted
  by line range (`sed`) into a scratch harness, today = Mon 2026-08-03:

  ```
  exam 2 days out, band 3          → IN WINDOW, create 20260803,20260804 (2 tasks — "3 days out, 3 tasks" rule at n=2)
  exam 6 days out, band nil → 7    → IN WINDOW, create 6 tasks (Aug 3–8, through the day before)
  exam 20 days out, band 14        → out of window, create nothing yet
  6 days out + user's own task     → dedupe hit "Review chem notes", create nothing
  6 days out + course-token task   → dedupe hit "Finish chem 101 flashcards" (no study word needed)
  6 days out + unrelated tasks     → no dedupe ("Study Spanish", "Chem lab report" correctly pass), create 6
  6 days out, Aug 4 tombstoned,
    Aug 3 already created          → create Aug 5–8 only (4) — tombstone skipped, idempotence held
  re-run after full creation       → create nothing (idempotent)
  exam today                       → out of window (no study days left)
  band 5 (invalid) → default 7     → tolerant decode confirmed
  ```

  The in-app DEBUG dump prints the same fields per exam on every sweep run
  (lead band, days remaining, in/out of window, dedupe verdict, tombstone
  stamps, existing count, created days).
- The live end-to-end path (real store, message box rendering, tombstone
  write from a real deletion) needs a device/simulator session — not
  runnable unattended; the fixtures above cover the decision logic, and
  the render-detection path is compile-checked only.

## Deviations from the plan

- **Announcement lands in the message box, not chat.** `DESIGN.md`'s older
  text says "tell the user in chat"; the plan itself overrides — "the
  message box announces it — that's what the box was built for."
- **"Consuming" the tombstone note = it actually rendered.** The box is
  display-only, so there is nothing to tap; render + freshness window is
  the honest reading of "consumed". If a higher-priority state (overdue)
  preempts it for days, it stays pending and shows later — existence alone
  never consumes it.
- **One announcement slot** (the soonest exam with creations this run).
  Two exams entering their windows on the same day announce only the
  sooner; the other's tasks are still visibly on the list. Keeps the box
  to one voice; noted for the planner.
- **Study-day granularity:** "one per remaining day up to the exam day"
  read as today through the day BEFORE the exam (3 days out → 3 tasks,
  matching the plan's own arithmetic); exam-day-itself gets no task, and
  an exam today creates nothing.
- Prep tasks keep priority "medium" — stakes carries the weight; the plan
  named stakes/duration/title/source but not priority.

## Noticed but not done

- A user completing a prep task then deleting it still tombstones the day
  — arguably correct (they're done with it) but the note copy ("was
  removed") reads slightly off for that path. Rare; left.
- If the user deletes the EXAM EVENT, existing prep tasks survive as
  orphans (linkedEventId points nowhere) and the sweep simply stops
  managing them. A cascade-delete question for the planner.
- `CalendarService.detectHighPriorityEvents` + the `generatePrepPlan`
  stub are now superseded legacy (the AI prep-plan path was never wired);
  candidates for the stub graveyard next cleanup cycle.
- The dedupe check runs against open tasks only — a user study task
  completed YESTERDAY doesn't block today's creation. Defensible either
  way; picked the reading that errs toward scaffolding.

## Open questions

- Should deleting an exam event cascade to its remaining prep tasks (and
  their tombstones)? Needs a product call before wiring.

## Addendum (2026-07-31)

The `nonisolated` markers on `ExamPrepSweep`'s pure helpers were both
unnecessary and wrong: unnecessary because the app target compiles with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so `ClaudeService` (the
caller they were guarding) is main-actor-isolated anyway — and wrong
because they made the helpers reference the now-main-actor-isolated
`NudgeConfig` from nonisolated contexts. Warnings in Swift 5 mode
(missed by the item's error-grep), errors in Xcode's editor and in Swift
6 mode. Removed the markers; everything is uniformly main-actor. The
fixture harness is unaffected (its scratch extraction carries no
isolation). Fixed in a follow-up commit on this branch.

Lesson recorded for future cycles: grep build output for `warning:` as
well as `error:` — this project's Swift 5 language mode downgrades real
isolation violations to warnings.
