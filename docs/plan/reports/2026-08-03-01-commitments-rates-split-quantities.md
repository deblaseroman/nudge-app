# Report — 2026-08-03-01 — Commitments: rates, split work, and quantities

**Plan:** `archive/2026-08-03-01-plan.md`
**Status:** complete
**Commits:** `0d11f19` (item 1), `a4e5194` (item 2), `152e434` (item 3), `a91846d` (item 4), plus this report commit

---

## What changed

**Item 1 — ask only what can't be inferred** (`0d11f19`)

- `Nudge/Models/NudgeCommitment.swift` — NEW: `CommitmentShape` enum (splitWork / rate / quantity, tolerant lowercase parse) + the `NudgeCommitment` @Model, the durable parent an expansion produces. Rows are the memory: `totalMinutes` is the remembered answer, and rows are deliberately never purged at end date.
- `Nudge/Models/NudgeTask.swift` — additive `commitmentShapeRaw` / `commitmentDailyCount` (+ typed accessor): the capture task carries its shape until expansion.
- `Nudge/Services/ClaudeService.swift` — the brain-dump prompt gains a COMMITMENTS section (shape detection rides the one capture call — no second round trip) and the two-questions rule: splitWork with no total → ask rough hours; rate/quantity with no end date → ask when it ends; all needed questions (timeless-events one included) combine into ONE closing message, capture-first; nothing else about a commitment may be asked. `TaskData` gains the two fields. `sendChat` takes `knownCommitmentSizes` and injects a KNOWN COMMITMENT SIZES block instructing reuse-instead-of-asking.
- `Nudge/Views/Tabs/HomeTabView.swift` — writes the shape fields on captured tasks; builds the known-sizes lines from `NudgeCommitment` rows.
- Schema lists ×3 + widget `membershipExceptions` for the new model.

**Where the questions live, and why:** Home chat, not the message box. The message box is deliberately read-only — a question there has no path for its answer to come back. Chat already owns the one-follow-up idiom (timeless events) and the `task_updates` answer path, so an answered "about 8 hours" / "until Friday" lands through existing plumbing (`estimatedMinutes` / `dueDate`) with zero new update machinery.

**Whether `CategoryDurationStats`' pattern fit:** in spirit, yes — a learned store consulted before asking — and that shape is what was built. Its actual granularity did not fit: per-category is far too coarse for "how big is a module" (all `school` ≠ one course's module size). So the store is the `NudgeCommitment` rows themselves, and "is this the same kind of work" matching is delegated to the model inside the one capture call rather than a deterministic title-family normalizer.

**Item 2 — expansion** (`a4e5194`)

- `Nudge/Services/ExamPrepSweep.swift` — restructured into `examPhase` + `commitmentPhase` (the old no-exams early return would have skipped commitments). Expansion converts a ready parent into a `NudgeCommitment` row + one `source == "commitment"` task per day and **deletes the capture task — the dailies replace it; listing both would show the same work twice**. Split work generates once: `splitWorkPlan` (pure static) divides total ÷ days available, rounds UP to half-hour blocks (floor 30m / ceiling 240m in `NudgeConfig`), front-loaded today → day before deadline. Rate generates one task per day through the end date *inclusive* on a rolling 14-day (`commitmentHorizonDays`) window topped up each run.
- `Nudge/Services/NudgeConfig.swift` — the four commitment constants.
- `Nudge/Services/NudgeArbiter.swift` — due-soon exclusion extended to `source == "commitment"` (self-imposed scaffolding, not deadlines).
- `Nudge/Services/DayPlanEngine.swift` — own-day rule and the generated-placement cap now cover both generated sources.
- `Nudge/Views/Components/TasksMessageBox.swift` — commitment announcement state (own App Group slot so a same-morning exam sweep can't overwrite it) + commitment copy for the tombstone note.
- `Nudge/Views/Tabs/TasksTabView.swift` — tombstone note distinguishes commitment parents (`@Query` on `NudgeCommitment`); Unscheduled per-parent collapse extended to commitment dailies ("Show N more days" — a 2-week rate is 14 rows and would swamp the tab).
- `Nudge/Views/Tabs/HomeTabView.swift` — runs the sweep after any capture turn that changed tasks, so a fully-specified dump or an answered question expands immediately, before the arbiter reevaluate.

**Shared vs. separate (the plan's no-second-sweep instruction):** shared — the sweep class, run cadence and entry points; (parent, day-stamp) idempotence via the extracted `missingStamps` walk (the exam `decide()` now calls it too); the `PrepTombstone` model and `recordDeletionIfGenerated` (né `recordDeletionIfPrep`; the model's `examEventId`/`examTitle` fields read as "parent id/title" for commitment rows — renaming @Model fields is forbidden by repo rule, and the field-name-lies-intent-continues convention already exists twice); the announce-or-it-didn't-happen mechanism. Separate — parent source (a converted capture task vs. a calendar event), per-day math (÷ days vs. one-per-day vs. count), and window shape (deadline-exclusive one-shot vs. inclusive rolling horizon vs. lead band). The exam dedupe (`userStudyTaskMatch`) has no commitment analog: the parent came *from* the user, so there is nothing to dedupe against.

**Item 3 — quantity-per-day** (`152e434`)

- `Nudge/Models/NudgeTask.swift` — additive `targetCount` / `completedCount` / `carriedCount` + `effectiveTargetCount` (base + capped carry). `Nudge/Models/NudgeCommitment.swift` — `carryUnits`, the durable accumulator, capped at every write.
- `Nudge/Services/ExamPrepSweep.swift` — quantity arms: expansion readiness, rolling generation with `targetCount` stamped, and `applyQuantityCarry`.
- `Nudge/Views/Tabs/TasksTabView.swift` — `TaskRowView.countControl`: under four effective units, one small checkbox per unit (tap each; tapping a filled one steps back); four or more, a single capsule with the running `done/target` number that increments per tap. The final unit funnels through the existing `toggleCompletion` path so records/haptics/arbiter are identical; the task cannot complete below the count through the row. `NudgeTheme` colors only.

**How the carry is stored:** `NudgeCommitment.carryUnits` is the accumulator, capped at `commitmentCarryCapDays (3) × dailyCount` at every write — so a week of misses *stores* the same number as three days of misses; there is no uncapped value anywhere that a display could accidentally show. The sweep's walk consumes each past daily exactly once, in date order (shortfall = base + carry-in − done, floored, capped), then deletes the row — the carry IS the reschedule (DESIGN.md: rescheduled with more urgency, not a red row sitting in Overdue), and consuming the row is precisely what makes re-running the walk a no-op. Today's task gets the accumulator stamped as `carriedCount`, so the displayed number is always the capped one. A tombstoned (user-deleted) day never appears in the walk and contributes nothing — the deletion stands.

**Item 4 — displacement** (`a91846d`)

- `Nudge/Services/DayPlanEngine.swift` — auto placements' busy intervals are tracked per task (`autoPlacedIntervals`; manual placements and events are never tracked, hence never displaceable). A generated session with no in-band gap triggers `attemptDisplacement`: each candidate eviction is *simulated* (remove exactly its interval, re-run the gap search inside the session's band) and only one that opens a genuinely fitting gap counts as helpful — the two-45-minute-gaps case fails the simulation and displaces nothing. Among helpful candidates, only strictly-lower stakes (rank high > medium > nil > low, the morning prompt's convention) may be evicted — lowest rank first, later-in-day first on ties; at most ONE displacement per run. Helpful-but-equal candidates displace nothing and surface as `noRoom(contention:)`.
- `Nudge/Views/Components/TasksMessageBox.swift` — `PlanOutcomeContext` gains `displacedTitles` + `contentionTitle`; the auto-plan announcement names a displaced task ("went back to Unscheduled — re-place it wherever suits you"), and the contention message states the fact and leaves the decision: "Everything placed today matters as much as it does, so nothing was moved."
- `Nudge/Views/Tabs/TasksTabView.swift` — outcome plumbing for the new case.

A displaced task's placement fields are cleared (`plannedIsAuto` included), so it lands in Unscheduled — visible and re-placeable, never moved to another day.

**Docs** — `ARCHITECTURE.md`: sweep/model/planner/message-box/capture entries updated; `NudgeCommitment` and the generalized tombstone documented.

## Verification

- **Builds:** both schemes (`Nudge`, `NudgeWidgetExtension`) built successfully after every item commit — four times each, zero warnings in the filtered output.
- **Pure math, actually executed** (script mirroring the shipped `splitWorkPlan` body and constants, plus the carry recurrence):
  - `480m / 4 days → (120m, 4 sessions)` — the plan's evidence case: eight hours across four days is four two-hour sessions.
  - `60m / 5 days → (30m, 2 sessions)` — no five-sliver smear.
  - `2400m / 4 days → (240m, 4 sessions)` — ceiling case: honest undershoot instead of 10-hour blocks.
  - Carry, base 3/day: miss 1→carry 3, miss 2→6, miss 3→9, miss 4…7→**9** (displayed target 12 throughout) — missing three days does not produce a fourth day's worth of carry.
- **DEBUG before/after (work-order item 5), status:** the seams are in place but a real-data device run has not happened from here. `commitmentPhase` prints per-commitment decisions (shape, window, existing/tombstoned stamps, created days) exactly as the exam half does; `applyQuantityCarry` prints each consumed day (`did n/m → carry k (cap c)`); `attemptDisplacement` prints the per-candidate eviction check, stakes ranks, the decision, and the displaced placement, and the run result line flags displacement/contention. These need one DEBUG run on the real store to produce the actual before/after output — same as the last cycles' device-check pattern. Nothing in items 2/4 fires until a commitment is captured or a generated session meets a full day, so the current store's behavior is unchanged until then by construction.
- **Not verified here:** the live capture flow (needs the API key + a device/simulator run) — i.e., that the model reliably emits `commitmentShape` and asks exactly the two questions. The prompt follows the same worked-rule style as the existing sections, but prompt behavior is only provable by running it.

## Deviations from the plan

- **The captured parent task is deleted at expansion**, replaced by the `NudgeCommitment` row + its dailies. The plan named "the parent commitment" without saying what the captured task becomes; keeping it would list the same work twice (a "Module 4" task due Friday *plus* its daily sessions). The exam analog keeps its parent because an exam event is independently real (you attend it); a commitment's only reality is its daily work. Until its numbers are known, the parent stays a perfectly ordinary visible task — capture-first is preserved.
- **Split work stops the day before the deadline** (the prep buffer-day pattern); rate/quantity run through their end date inclusive. "Between now and the deadline" was ambiguous; finishing a divisible body of work *on* its due day (normalized to 23:59) is the plan-to-fail shape, while a stated cadence "until Friday" plainly includes Friday.
- **Split work generates once, capped at 14 sessions** (`commitmentHorizonDays`), with a 240-minute session ceiling — the smaller honest version. Re-dividing the remainder on later runs would silently inflate sessions the user already saw; a >14-day split-work deadline gets its sessions front-loaded into the first 14 days; a total exceeding ceiling × days covers less than the stated total rather than proposing impossible blocks.
- **Quantity's missed-day rows are consumed (deleted) by the carry walk** — all past dailies are, completed ones included, once absorbed. This is system consumption, not user deletion, so it is not tombstoned; completed history already lives in `CompletedTaskRecord` and completed tasks render nowhere in the Tasks tab since the Completed control's removal. Without consumption the walk isn't idempotent and missed days sit red in Overdue *and* double-count against the carry.
- **Displacement is capped at one eviction per run**, and only generated sessions may displace — their date is their only day; an ordinary task can wait for tomorrow's gaps. A planner that reshuffles several placements stops reading as a proposal.
- **A displacement during a *manual* replan is not narrated.** The replan releases every auto placement before placing, so "released and not re-placed" is that pass's normal, already-visible shape; only the auto-run announcement names displaced tasks. (In practice displacement during any run can only evict placements made earlier in that same run, or — auto-run only — pre-existing autos when the run proceeds around manual placements.)
- **Equal-stakes contention reads "no strictly-lower helpful eviction exists."** Multiple helpful candidates that are all strictly lower but tied with *each other* do get one evicted (lowest rank, latest placement) — refusing there would fail the feature for exactly the case it exists for.

## Noticed but not done

- **The widget's `CompleteTaskIntent` and the timeline long-press complete a count task wholesale.** Both funnel to full completion; the row's toggle now stamps `completedCount = effectiveTargetCount` so the numbers agree, but the widget intent writes `isComplete` directly and skips the stamp (harmless: the count UI only renders while incomplete, and un-completing re-syncs). A per-unit widget affordance is its own design question.
- **Editing a commitment after expansion has no path** — the parent task is gone from `EXISTING_TASKS`, so "actually make it 10 hours" in chat can't target it. The user's lever today is deleting dailies (tombstoned) or editing them individually. A `task_updates`-like channel for commitment rows is planner material.
- **`NudgeCommitment` rows accumulate forever** (deliberately — they're the memory), and the known-sizes injection sends every sized splitWork row. Fine at a handful; would want a cap/recency filter if it ever grew large.
- **Rate dailies with no stated duration** (e.g. "work on X every day until Friday") carry nil `estimatedMinutes` and fall to category priors downstream — the plan only guaranteed a duration for stated rates.
- **The prep-collapse expansion state (`expandedPrepExams`) keys generated groups by parent ID** — commitment groups reuse it unchanged; the property name now slightly lies. Left alone.

## Open questions

- Should the two-hour-max session ceiling and the 14-day split cap be surfaced to the user when they bite ("that's more than fits — I scheduled the first 14 days"), or is silent-honest coverage enough? Currently silent; the message box announcement states the per-day amount, not the shortfall.
- When a quantity commitment's end date passes with carry outstanding, the backlog vanishes with the last day (nothing extends past the stated end). Extend one day to land the carry, or is a stated end a stated end? Currently the latter.
