# The Process — how Nudge got built

A record of the collaboration behind this app: a solo developer (Roman
DeBlase, product owner and designer, not a Swift reader) working with an
AI engineer (Claude, via Claude Code) that reads and writes the code.
Written September 2026, mid-project, for anyone examining how this was
made — including the failures, because the failures are where the method
came from.

---

## How the work actually flows

The working loop, arrived at by iteration rather than design:

1. **Roman describes what he saw, not what to build.** The rule was
   learned the hard way: early on he proposed a "Tomorrow tab" (a
   solution); the real defect was that the Today tab filtered by plan
   membership instead of by date. When he instead described the screen —
   "a task for tomorrow shows up under Today" — the actual bug surfaced
   in minutes. Symptoms in, diagnosis out.
2. **Claude diagnoses against the real code before proposing.** Every
   claim in a diagnosis carries a `file:line`. Read-only investigation
   is a distinct mode, requested explicitly ("do not change anything"),
   and respected.
3. **Non-trivial changes get a written plan Roman approves before any
   code moves.** Plans and their post-work reports live in
   `docs/plan/archive/` and `docs/plan/reports/`, paired by cycle ID —
   an auditable trail of what was authorized versus what was done, with
   a mandatory "Deviations" section that has to be filled in honestly
   even when the answer is "none".
4. **Both build schemes compile after every commit.** There are no
   tests in this project; the compiler and on-device runs are the
   verification, so the discipline around them is strict.
5. **System maps became the shared language.** Five illustrated
   engineering documents (in `docs/maps/`) describe the architecture,
   the notification engine, its ten builders, the time model, and the
   AI surface. Roman rules on gaps *by pointing at the map* ("4.0,
   first one down"); the maps are updated in the same breath as the
   code they describe. This replaced paragraphs of misunderstanding
   with figures both sides can point at.

An earlier configuration had a second AI (a planning conversation with
no code access) writing instructions for Claude Code. **Roman fired
it** after observing that its knowledge of the app went stale and its
plans stopped matching the build — an important call: the planner's
value was process discipline, so the process (written plans, approval,
reports) was kept and the middleman was cut.

## Decisions Roman made (the product is his)

- **A deadline is not an intention.** The foundational ruling:
  "the countdown was for big exams and assignments that are due, not
  study sessions or everyday tasks." One sentence from him dissolved a
  four-way bug class (fake countdowns, false overdues, phantom urgency
  nudges, a starved notification type) that had been patched piecemeal
  for weeks.
- **Events are immovable.** "When an event has a scheduled time, that
  time is concrete" — the planner flows tasks around events, never the
  reverse.
- **The heart of the app is the widget, the notifications, and the
  simplicity of the Tasks tab.** Stated when pushing back on an
  over-engineered calendar proposal; now the sentence that stops scope
  creep.
- **The calendar is a rare glance, not a calendar app.** Read-only
  month view, tap-to-edit through the existing editor, "not another
  thing the AI needs to read."
- **One version, no free/paid tiers.** Simplicity over segmentation;
  the pricing model, not feature gates, will carry the API cost.
- **Model economics are a design constraint.** He funds the API
  personally; every AI decision is made with unit cost on the table.
  The capture model was chosen by a measured bake-off (see below), not
  by vibes.
- **The Tasks-tab chat box is a narrator.** Talk only, reads and
  interprets, never writes, one brain across the app.
- **User-facing "clear a day / push everything back" is deferred** to a
  post-TestFlight restructure system — named and parked, not forgotten.

## Pushback, in both directions (and who was right)

- **Roman pushed back on Claude's calendar-complexity estimate — and
  won.** Claude projected drag-and-drop, sync engines, "where it gets
  hard." Roman's spec had none of that: glance, tap, existing editor.
  The estimate collapsed from large to moderate, and the shipped
  calendar matches his sketch, not the warning.
- **Roman overrode a shipped design decision.** Claude had left widget
  task rows untinted "deliberately" (with a documented rationale).
  Roman: the widget must match the app. He was right — the rationale
  was internally consistent and externally wrong; users see one
  product, not two coordinate systems.
- **Claude pushed back on "shouldn't the AI plan the day?" — and Roman
  accepted.** The case was made with evidence from his own app (the
  language model had already failed date arithmetic twice); the
  resulting doctrine — **AI proposes, math disposes**: models supply
  judgment, deterministic code owns feasibility and verification — is
  now recorded as his standing architecture decision.
- **Claude initially deferred Roman's Tomorrow-tab request — half
  right.** The need was real (Roman kept insisting; he was correct);
  building it *before* dates meant anything would have added a tab and
  kept the bug (also correct). The resolution was sequencing: fix the
  date semantics first, then build the day views on top. Both halves
  of the disagreement shipped.
- **Self-corrections are part of the record.** Claude once labeled a
  plan "approved" on a published map when Roman had never said the
  word — caught and corrected in the next breath, because an audit
  trail with flattering errors is not an audit trail.

## Failures worth knowing about (kept, not buried)

- **The silent-drop era.** A stated 6pm event vanished during capture
  and *nothing anywhere recorded why*. The diagnosis found six distinct
  ways an item could disappear between the model's response and the
  database — five of them silent. The fix was categorical: every drop
  now logs itself with a reason, and a reconciliation line
  (`returned / inserted / dropped`) makes absence visible. The bug
  class, not the bug.
- **The fabricated-deadline era.** Before the deadline/intention split,
  every captured date became "due at 23:59" — the app manufactured
  time pressure from ordinary plans. Solved by schema, not by prompt
  patches, once Roman named the distinction.
- **The app rendered in the wrong font for its entire life.** The
  fonts were declared in configuration from day one; the font files
  themselves never existed. Found during TestFlight prep. A reminder
  that silent fallbacks are the most patient class of bug.
- **A week of work sat uncommitted** because a session ended without
  landing it — discovered later, disentangled from newer work, and
  committed with honest labels. Process gap, then process fix: work is
  committed when it ships.
- **The recurring lesson under most of these:** a rule written for the
  case in front of it, never renamed for the category. "Today shows
  the plan" was right when every plan was for today. The whole
  project's bug history is that sentence wearing different costumes.

## Engineering culture that emerged

- **One rule, one place.** Shared logic gets hoisted to a single
  implementation the moment a second consumer appears (the sort
  comparator, the day window, the slot palette, the editor's save
  logic) — because every duplicated rule in this codebase eventually
  drifted and shipped a bug.
- **Deterministic core, AI at the edges.** No model call in the
  notification or planning path; AI writes validated data in, or
  generates copy ahead of time. Interruptions are reproducible.
- **Paranoid asymmetry in anything lossy.** The chat router sends a
  message to the cheap model only when it *provably* contains no work —
  a wrong "chat" verdict loses a capture; a wrong "task" verdict costs
  six cents. Design for the asymmetric failure.
- **Evidence before behavior change.** Arbiter-touching changes ship
  with before/after dumps on real data; the model choice was a
  measured head-to-head (Opus 5 vs Sonnet 5 on canonical dumps — Opus
  kept for judgment quality at low effort: ~6¢ and 3–7s per capture,
  down from 24¢ and minutes).
- **Census-stamped documentation.** The planner-facing architecture
  census is verified against a named commit and must be updated in the
  same commit as any change to what it describes — docs that can't
  silently rot.

## Where it stands (September 14, 2026)

Pre-TestFlight: capture, scheduling, day-integrity, lenses, calendar,
router, and the notification engine are built; remaining work is the
chat-box wiring (spec in `AI-BEHAVIOR.md`, Roman authoring), onboarding
completion, mascot art, and the accumulated on-device test list. The
five system maps in `docs/maps/` are current to this date.

*Assembled by Claude at Roman's request, from the working record; the
decisions described are his.*
