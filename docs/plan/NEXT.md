# NEXT — Plan proposals: the app builds the steps, the user says yes

**Status:** SHIPPED — Roman's "go", Sep 16 2026; four commits fa05cbb,
d3d5dd5, 7c6cf8c, 3350460; report at `reports/2026-09-16-01-plan-proposals.md`
**Cycle ID:** 2026-09-16-01
**Source:** Roman's vision statement and rulings, Sep 16 2026 ("Right now
add the way for it to create subtasks for the users based on anchored
tasks or events. The AI needs to be able to read the task and interpret
if it's a task or event worth creating sub tasks for."). Written by Claude
Code directly against the working tree. The vision statement is the
source of truth; `SYS-VIS-10` is its map.

> On `fix/notification-threading-and-memory`. **One item per commit.** Both
> schemes build after every commit. Do not push, do not merge.
>
> If an item is larger than described or needs a decision not written here,
> ship the smaller honest version and say so.

---

## Why this exists

"Prepare the user for what's ahead" is one of the app's three verbs and the
only one with no general mechanism. Today only exam-category events get
lead-up work, chosen by a keyword at import, created silently, announced
after. The vision says: for an important, necessary task or event **with a
due date**, the app builds the subtasks that prepare for or complete it,
Opus explains them in the Tasks-tab message box, and a **Yes** adds them
to the list and timeline; a **No** changes nothing. This cycle builds that
mechanism and routes exams through it.

The two-clock rule governs what gets written: subtasks are **scheduled
sessions before the anchor, never due-dated tasks of their own.** Only the
parent is owed. That is what stops a slipped study session from reading as
"overdue calculus".

## Item 1 — The reader: candidates in, proposals out

**Candidates (deterministic, `PlanProposalSweep.candidates`):** open rows,
task or event, with an anchor (`dueDate` or `specificTime`) inside
`NudgeConfig.planProposalHorizonDays` (21, matching the import edge), not
`source == "prep"` / `"commitment"`, not already decided (below), and with
no user-made subtask already pointing at them (`ExamPrepSweep
.userStudyTaskMatch`, the existing title-match rule, generalized: any open
task whose title contains the parent's subject tokens).

**The call (`ClaudeService.proposePlans`, Opus 5 at effort low, one batched
request):** up to `planProposalBatchSize` (5) candidates per call, at most
`planProposalCallsPerDay` (2) calls a day. Input per candidate: title,
kind (task/event), anchor as a pre-phrased line ("in 18 days, Oct 4 at
9 AM"), category, stakes, estimated minutes, the days available
(offsets from today, excluding days with no free time per the busy gate is
NOT computed here; the planner places later). Output per candidate:

```json
{"id": "...", "worthPlan": true,
 "reason": "one plain sentence for the message box",
 "sessions": [{"title": "Review chapters 5-6", "dayOffset": 12, "minutes": 45}, ...]}
```

Rules in the prompt: judge worth honestly (most everyday things are not
worth a plan; a dentist appointment is not); 2–8 sessions; each 15–120
minutes; `dayOffset` strictly before the anchor's day and ≥ 0; titles
short (the title-condensing rule: "Masters Application", not "Apply to a
Masters program"); tone rules from the memo (facts, no shame, no promise,
no em dash). `worthPlan: false` is stored as a decision too, so the same
item is never re-asked while its anchor is unchanged.

**Storage (`PlanProposalStore`, app-group defaults JSON, no new
`@Model`):** per parent id: `{status: proposed | accepted | declined |
notWorth, anchorStamp, reason, sessions}`. `anchorStamp` is the anchor's
day; if the anchor moves, the decision is void and the item is a candidate
again.

**When it runs:** in the day-change chain where `ExamPrepSweep` runs
(before the arbiter, never in its path), and once after a capture or
import that created an anchored row. Async; the message box shows the
deterministic ladder until a proposal lands. No key / offline: nothing is
proposed, nothing is written. The app adds only what the user asked for.

## Item 2 — The ask: Opus explains, the user decides

New composer state `planProposal` in `TasksMessageComposer.compose`, placed
**above the memo and below tapped-nudge context and one-time news** (same
seam logic as the memo: it yields to prep notes, announcements, planner
outcomes). Renders:

- headline: `reason` from the reader (Opus's sentence)
- detail: deterministic, from the stored sessions: "6 sessions, Sep 28 to
  Oct 3, about 45 minutes each. First one: Review chapters 5-6."
- two buttons, the existing accept-offer capsule pattern: **Yes** and
  **No**. Nothing else on the surface asks or takes text.

**Yes:** `PlanProposalSweep.accept(parentID)` writes one `NudgeTask` per
session: title, `intendedDate` = today + dayOffset, `estimatedMinutes`,
`category` and stakes from the parent, `source = "prep"`,
`linkedEventId` = parent id (the existing column, now the parent link for
tasks as well as events). **No `dueDate`, no `specificTime`.** Then
`NudgeArbiter.reevaluate(.taskCreatedOrEdited)` and a widget reload. The
proposal's status becomes `accepted`; the message box falls through to
its next state. Plan my day places the sessions on their days; a session
whose day passes is cleared by the rollover as any placement is, and stays
open and unplaced until the anchor (ruling: a skipped subtask goes to
neither Overdue nor Skipped).

**No:** status `declined`. Nothing written. Never re-asked for that anchor.

One proposal shows at a time (soonest anchor first). A second one waits
until the first is answered.

## Item 3 — Exams route through the same door

- `ExamPrepSweep`'s **exam half stops creating study tasks.** Exam events
  become ordinary reader candidates (their category and stakes already
  mark them). The sweep's dedupe, tombstone, and stamp code is reused by
  `accept` so a Yes is idempotent and a deleted session is never
  recreated.
- **Capture:** when a dump contains an anchored exam and no study task
  from the user, the capture reply asks one question: "Want me to build a
  study plan for it?" A **Yes** in chat is consent: the reader runs for
  that item and the sessions are written and announced in the message box
  (no second Yes/No, the user already said yes). A **No** stores
  `declined`. If the user dumped their own study task, nothing asks; the
  app follows what they said (ruling).
- **Commitments are untouched** this cycle. A rate or quantity commitment
  ("an hour a day until Friday") is the user's own instruction, and its
  per-day rows stay as they are. Whether those rows should also lose
  their per-day due dates is a Phase 2 question.

## Item 4 — The reader can see the whole calendar

Deterministic, no tokens. Without it the reader only sees the 21 days
Apple Calendar imports and the 30-day snapshot an iCal link took once.

- `CalendarService.rollingWindowDays` becomes
  `NudgeConfig.calendarImportHorizonDays` (180; Roman may set "all"). The
  daily refresh extends the synced edge to that horizon, one tail slice a
  day as now.
- The **iCal feed joins the daily refresh**: the persisted feed URL is
  re-fetched on the same day-change cadence, through the same 
  duplicate check, with the same horizon. Manual Import stays.
- Dates and times stay exact (imported rows are never altered).
- Purge is unchanged: past events still leave the store daily, so store
  size is bounded by the horizon, not by history.
- The reader's own window stays `planProposalHorizonDays` (21): the
  store knows the term; the reader thinks three weeks ahead.

## Cost

One batched Opus call ≈ 2,000 tokens in, ≈ 800 out, about 3¢. Capped at
two calls a day; typical days make zero because every candidate already
has a decision. Worst case ≈ 6¢/day plus the memo's 1¢, about $2/month
against the $10 ceiling. Logged per call under the existing DEBUG usage
line with `site=planProposal`.

## Evidence it worked

- A fresh anchored event "Chem midterm, Oct 4, 9 AM" produces one message-
  box proposal with a Yes/No; Yes writes N sessions with `intendedDate`
  set and `dueDate == nil`; they appear under Today → This week and on the
  correct days in the calendar view; No writes nothing and the item is
  never proposed again.
- "Dentist, Sep 20" produces no proposal (`notWorth` stored).
- Console: one `USAGE ... site=planProposal` line per call, never more
  than two a day.
- The old silent study-task creation no longer fires for a new exam
  import; the DEBUG before/after (work-order item 5) shows the arbiter's
  candidate set unchanged apart from the sessions the user accepted.

## Out of scope (Phase 2 candidates, need Roman's approval separately)

- The **Skipped** section and the skip counter (two days on Today, not
  done → Skipped); reschedule-once for floaters.
- The **Due Date** section in task details under Reschedule, with "no
  date" / "no time" buttons, so a task can hold both clocks.
- The importance rule (ruled Sep 16): the existing ranking stays for
  everything without a due date; a due-dated task or event is **medium
  from creation and high on its due day**, one branch ahead of the
  scoring mix in `EisenhowerScorer.importance`. Among due-dated items
  the soonest anchor leads, as the shared comparator already does.
- Title condensing everywhere titles render; the empty-timeline Today
  list. (The import edge and iCal refresh moved into Item 4.)
- The memo's copy fix ("that is a process for later").
