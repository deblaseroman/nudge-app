# Report — 2026-08-03-02 — Generated series tasks: due times and labelling

**Plan:** `archive/2026-08-03-02-plan.md`
**Status:** complete
**Commits:** `c019cde` (item 1), `4e0ff7a` (item 2), `403457c` (item 3), item 4 needed no commit (verification only — findings below), plus this report commit

---

## What changed

**Item 1 — sessions due at the end of their own day** (`c019cde`)

What the generator was actually setting, confirmed before changing: both creation sites (exam prep and commitment dailies) stored `dueDate = calendar.startOfDay(for: day)` — midnight. The subtle part: `sortDeadline` reads a bare due date as end-of-day, so sorting and the red overdue *treatment* were correct — but the row subtitle feeds the RAW `dueDate` into `CountdownState.remainingLine`, whose overdue rule always wins. Hence "20 hours ago" at 8pm on a task created that minute, with no red row around it. Generated dailies now carry 23:59 of their own day via the shared `sessionDueDate` helper — the exact convention capture already uses for bare due dates, for exactly this reason. Day-stamp idempotence, tombstones, the carry walk, own-day placement and `sortDeadline` all normalize through `startOfDay` and are untouched; the right-side date line stays date-only because `specificTime` stays nil.

**The day count, as asked:** the shipped split-work arithmetic for 8 hours to Friday captured Monday Aug 3 produces exactly **four** sessions — 480 minutes over 4 available days (today through the day *before* the deadline: Aug 3, 4, 5, 6) → 120-minute sessions, ceil(480/120) = 4. No off-by-one; this arithmetic was executed, not desk-checked, last cycle and matches the plan's own "days to Friday = four" expectation. **Five same-title rows ending Aug 7 is not producible by the split-work path** — sessions are capped at `daysAvailable` by construction. It *is* exactly what a **rate or quantity** classification produces: their windows run through the end date inclusive, and Aug 3–7 is five days. So the likely explanation for the screenshot is the model classifying "finish module 4 of python course" as a rate rather than splitWork (the dump's "an hour a day" sat one clause away). The DEBUG dump now prints each series' shape, window, and due-time convention, so one device capture will pin it.

**Item 2 — series rows show their day, not a countdown** (`4e0ff7a`)

`TaskRowView`'s subtitle for `source == "prep"` or `"commitment"` (one branch — they share the generator, so the fix covers the seven-identical-study-rows problem too, which the plan asked about: **yes, one fix covered both**): "Today's session", a weekday name within a week ("Wednesday's session"), a date beyond that ("Session on Aug 15"). Ordinary tasks keep their countdowns — the branch keys strictly on the two generated sources.

**The overdue decision:** a missed session shows its day label in the overdue color — "Monday's session" in red — and never a countdown. Reasoning: the label states *which day slipped* (the useful fact) where a "26 hours ago" counter grows every hour, which is a shame ticker under `DESIGN.md`; the row's existing overdue treatment (tint, red date) already flags the state once, so the subtitle doesn't need to pile on. Beyond a week back a weekday name is ambiguous, so the date form takes over. The wall-of-red accumulation risk is real but is a *retention* question, not a labelling one — flagged under "Noticed" below.

**Item 3 — ask whether to start today or tomorrow** (`403457c`)

The decision is computed app-side by `ExamPrepSweep.startDayDecision` — room-left (via `DayWindow`, wake+30 → bed−60) and split-work growth arithmetic are exactly the things the model is never trusted with (the weekday-table precedent). Three outcomes:

- **No room today** → start tomorrow silently; the message-box announcement says "from tomorrow". A question with one answer is noise.
- **Skipping today would grow the sessions** (split work only — a rate/quantity that skips today just starts tomorrow, nothing grows, because the per-day amount is the user's stated cadence) → start today, and the closing message *states* it: "I'm starting X today — waiting until tomorrow would make each session longer."
- **Genuine choice** → the question is appended to the same closing chat message, and that commitment's expansion waits (`commitmentStartAskedAt`).

The answer routes through the existing `task_updates` channel (new `commitmentStartDay` field; the prompt is told never to ask the question itself, only to map the answer). An unanswered ask **expires at day rollover** and expansion proceeds on the viability default — a stale question about a day that no longer exists must not stall the series forever. `NudgeCommitment.startDate` anchors every generation window at `max(today, startDate)`. The background sweep path (no chat) gets the same viability default, so a 10pm capture never births a today-session even if the user closes the app mid-conversation.

**The all-three flow, as asked:** worst case is *two turns, one compound question each* — turn 1 asks size + end date combined ("Roughly how many hours is Module 4? And when does the app testing run to?"); turn 2, once the numbers exist, may ask "Want to start X today, or from tomorrow?". Within a single turn there is never more than one appended start-day sentence (a second choice-commitment in the same dump expands on the default). **Is it too much?** Borderline but acceptable — each turn stays one message, one question. If one has to go, drop the start-day ask for *split work* specifically (auto-decide and state the result): it's the shape whose ask always lands on a second turn, and its ask-gate already means the choice is low-stakes (only fires when sessions are identical either way).

**A consequence worth naming:** the plan's "if the user picks tomorrow, the work compresses — say so" case is **unreachable by construction**. The ask only fires when skipping today does NOT grow sessions (that's the plan's own ask-gate), so picking tomorrow never compresses; the compression statement lives in the todayForced path instead, where the plan asked for it ("state what's happening"). For rates and quantities, tomorrow just means one less day at the stated cadence — the deadline holds.

**Item 4 — collapse grouping, verified (no commit)**

- **Key:** groups form on `linkedEventId` — the parent's UUID. One group per parent; distinct parents can never merge (distinct UUIDs) and one parent can never split (all its dailies carry the same ID). Correct.
- **Counts:** the button label is `rest.count` = the parent's unscheduled dailies minus the visible head. "Show 4 more days" twice is the **correct** rendering for the observed store: a rate and a quantity both ending Friday, captured Monday, each span Aug 3–7 *inclusive* = 5 rows = head + 4. After item 3, a start-tomorrow series to Friday would read "Show 3 more days".
- The screenshot's four-to-five flat Python rows are consistent with that group having been manually expanded (state per parent in `expandedPrepExams`), or with the rate-classification hypothesis from item 1 — either way the grouping logic itself checks out; the flat rendering is not producible by a grouping bug, since any shared `linkedEventId` collapses unconditionally.

**Docs** — `ARCHITECTURE.md`: sweep entry (due times, start-day flow), `NudgeTask` fields, capture-prompt entry (`commitmentStartDay`), Tasks-tab entry (series subtitle).

## Verification

- **Builds:** both schemes built successfully after each of the three item commits; zero warnings in filtered output.
- **Root cause** for item 1 was established by reading the code path (generator's `startOfDay` → raw `dueDate` → `remainingLine`'s overdue-first rule) *before* the change, as the plan required, and is written up above.
- **Arithmetic:** the four-session count for 8h→Friday was verified by actually executing the mirrored `splitWorkPlan` math (last cycle's script; the function is unchanged this cycle — item 1 touched only the due-date stamp).
- **DEBUG seams for the on-device before/after:** the sweep now prints, per series, its shape, window (`start=`/`end=` stamps), and a per-creation line stating the 23:59 due convention. One fresh capture on device shows the before/after the work order asks for.
- **Not verified here:** the live model's handling of `commitmentStartDay` mapping and the appended-question conversational flow (needs API + device); the exact cause of the five-row Python series (needs the DEBUG dump from a device run — hypothesis above).

## The existing-store question (answered, nothing written)

**No migration, and no re-capture needed.** After this cycle the stored midnight due times on your existing generated tasks are *display-invisible*: item 2 removed the only surface that ever rendered the raw clock time (the countdown subtitle) for series rows; the right-side line was always date-only; and `sortDeadline` — which drives sorting, overdue state, and every scheduler read — has always normalized a bare due date to end-of-day, so a midnight-stamped row and a 23:59-stamped row behave identically everywhere that remains. Newly generated days get 23:59 from item 1. If you'd rather have the store literally clean, the DEBUG trash + relaunch works (the surviving `NudgeCommitment` rows regenerate rate/quantity dailies with correct stamps, and split-work re-lays its plan since no dailies or tombstones remain) — but it also wipes events until the next calendar refresh, and there's no behavioral difference to buy. I did not write the one-time normalizer; if you want the stamps corrected in place anyway, that's a ~10-line idempotent sweep and a one-cycle ask.

## Deviations from the plan

- **Item 3's compression case is unreachable** (explained above) — the plan's two rules ("ask only when skipping today doesn't force sessions longer" and "if the user picks tomorrow the work compresses") cannot both fire on the same capture; the gate wins and the growth statement moved to the todayForced path.
- **"Asked in the same closing message"** is implemented as the app *appending* to the model's reply (the assistant bubble is now composed after task processing). For split work the appended ask can only ride the turn its numbers complete — i.e. the answer turn — so the three questions can span two turns. Reported as the plan requested.
- **The start-day question's copy is fixed app-side**, not model-generated — deciding *whether* to ask requires arithmetic the model isn't trusted with, and once the app decides, letting the model re-phrase the question adds a failure mode with no benefit.
- Item 4 produced no commit — nothing was wrong.

## Noticed but not done

- **Missed-session retention:** quantity dailies get consumed by the carry walk, but a missed prep / split-work / rate session persists as a red row indefinitely (until done or deleted). One missed Monday reading "Monday's session" in red is clear; a bad week accumulates several. A retention/consumption policy for non-quantity series (roll the day forward? absorb like carry? expire quietly?) is a real design question for the planner — item 2 deliberately changed labels only.
- **The widget's task rows still show countdown-style lines** for series tasks (`WidgetCountdownFormatter` path) — the day-label treatment is app-side only this cycle. Same-fix-different-target work if wanted.
- **The rate-classification hypothesis** for the Python series, if confirmed by the DEBUG dump, suggests a prompt clarification (split work vs. rate disambiguation when a dump mixes both shapes in one breath) — related to the out-of-scope group-deadline inheritance question.
- `expandedPrepExams` (the collapse-state property) now holds commitment parents too; the name lies slightly. Left alone.

## Open questions

- If the device dump confirms the Python item was classified as a rate: should a title like "finish module 4" (completion-shaped) veto the rate classification even when "an hour a day" appears nearby? That's a prompt-rule question for the planner.
- Missed-session retention policy (above) — the never-shame rule and the vanishing-task rule pull in opposite directions and need a deliberate call.
