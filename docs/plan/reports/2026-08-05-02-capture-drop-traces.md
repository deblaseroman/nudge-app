# Report — 2026-08-05-02 — Capture drop traces, dump-contents rule, honest error copy

**Plan:** `archive/2026-08-05-02-plan.md`
**Status:** complete
**Commits:** `70f5017` (archive), `984f014` (item 1), `5cd065e` (item 2), `c1f8828` (item 3)

---

## What changed

- `Nudge/Services/ClaudeService.swift` (items 1 + 2) —
  - Item 1, three drop points now DEBUG-log: extra content blocks beyond the
    first (`makeRequest`, with discarded char count); content outside the
    first balanced JSON object (`normalizedJSONPayload`, with char count);
    a response that decodes with **no `new_tasks` key** (`parseResponse` —
    this is the one that reads as a normal empty capture and is also what a
    dropped array looks like).
  - Item 2, two prompt changes in `chatSystemPrompt`: a "THE DUMP IS NOT ONLY
    THE PLAN" rule beside CAPTURE-FIRST (every distinct commitment or
    intention becomes an item; sequence membership is a property, not a
    filter; explicitly: non-plan items get `sequenceIndex` null and their own
    correct `isEvent`/dates), and a governing principle at the head of the
    relative-day Mapping rules (any phrasing resolves against the injected
    date context by rule; unlisted phrasing must neither go undated nor
    shift days). No phrase bullets added or removed.
- `Nudge/Views/Tabs/HomeTabView.swift` (items 1 + 3) —
  - Dedupe guard rewritten from `contains` to `first(where:)` — **same
    predicate** — so a suppression names the incoming title, the existing row
    it matched, and the clause (`same-day` vs `nil-date fallthrough`).
  - Every per-item drop is accumulated and a reconciliation line prints after
    the insert loop: `CAPTURE: returned=N inserted=M dropped=K` plus one line
    per drop with its reason.
  - `try? modelContext.save()` after capture is now a real do/catch
    (**production behavior**): failure DEBUG-logs the error and appends a
    chat message stating the fact — "I couldn't save that just now. If it's
    not in your list, send it again." The inserts stay in the context, so a
    later successful save is the recovery path and the copy stays
    conditional rather than asserting loss.
  - Item 3: the non-`ClaudeError` catch branch no longer says "check your
    internet." New copy: "That didn't go through — nothing from it was
    saved. Try sending it again." Both claims are code-backed: the sole
    throwing call precedes every insert. DEBUG builds append the concrete
    error type (e.g. `[DecodingError]`) to the bubble. `errorText` became
    `var` for the DEBUG append.

## Verification

- Both schemes build clean (no errors, no warnings) after **each** of the
  three item commits — six builds total, `xcodebuild` against the generic
  simulator destination. One intermediate compile error (`errorText` was
  `let`) was caught by the item-3 build and fixed before commit.
- **Work-order item 5 (arbiter before/after) does not apply**, as the plan
  itself states: nothing here touches candidates, gates, scoring, or
  scheduling. The runtime changes are console prints, one error-copy string,
  one chat-message-on-save-failure, and prompt text consumed by the model —
  the arbiter's inputs and code are byte-identical. Said explicitly rather
  than skipped silently, per the plan.
- **Not verified here — needs a device run with an API key:** the two
  evidence items in the plan. (1) A mixed dump (fixed commitment + ordered
  plan) printing a reconciling `returned/inserted/dropped` line — the code
  paths compile and the arithmetic is `returned = inserted + dropped` by
  construction, but the pass condition is seeing it on a real dump.
  (2) Item 2's behavioral effect on the model is inherently probabilistic;
  item 1 is what makes its success or failure *observable*, which is why the
  plan made the distinction-being-visible the pass condition.
- Item 3's forced decode failure: not exercised on device this session. The
  branch is reachable exactly as diagnosed (any non-`ClaudeError`, incl.
  `DecodingError` at `parseResponse`); the new copy contains no network
  claim by inspection. A DEBUG-only failure injection was considered and not
  added — it would be a fourth change the plan didn't ask for.

## Deviations from the plan

- **Save-failure copy is conditional, not declarative.** The plan said
  "surface a failure to the user"; the copy says "if it's not in your list,
  send it again" rather than "your tasks were lost," because the failed
  `save()` leaves inserts pending in the context and a later save (including
  SwiftData autosave) can still land them. Asserting loss would be the same
  fabricated precision item 3 removes. Judged consistent with the plan's own
  voice rule; flagging because it's softer than a literal reading.
- **Drop point 1 logs only when a second content block exists** (count > 1),
  not on every response — the plan's "log at each, naming the item and the
  reason" read as "log when a drop happens," and an every-response line
  would bury the reconciliation signal it exists to serve.
- The `new_tasks`-key log lives in `parseResponse` rather than at the
  `newTasks ?? []` accessor the plan pointed at — the accessor is a computed
  property evaluated on every read; the parse boundary fires once per
  response. Same fact logged, better location.
- None otherwise. Constraints held: dedupe predicate untouched, tab
  predicates untouched, `DESIGN.md`/`ROADMAP.md` untouched.

## CONTEXT.md census

Per the plan's constraint: item 2 changes **prompt content at an existing
call site** (`sendChat`), not the call-site inventory, gates, or builders.
The census section lists sites, not prompt text, so no census fact changed
and `CONTEXT.md` is deliberately not updated in this cycle's commits.

## Noticed but not done

- **The legacy `send(userMessage:context:)` path** (`ClaudeService.swift`,
  used by `NudgeIntelligence.callAI`) appends its own date line that says
  "Default dueDate to today if none specified" — contradicting the floater
  rule — and injects no clock time or tomorrow date. It shares
  `parseResponse`/`normalizedJSONPayload`, so it inherits items 1's parse
  logs, but its prompt got neither item 2 rule. Out of scope (the plan names
  `chatSystemPrompt`); worth its own look since it's a live call site.
- `captureWordVomit` (`ClaudeService.swift`) has no call sites at all —
  dead prompt code carrying the same "default to today" instruction.
- The dedupe guard's shape (events deduped against tasks, `isEvent` read
  after the guard, nil-date suppression on title alone) — explicitly out of
  scope per the plan; it now logs, which is the evidence-gathering the plan
  wanted before a redesign.
- The eight Sep 3 tasks from the triggering dump are still in the store;
  nothing in this cycle re-dates or recreates the lost event. The user
  re-entering it is the recovery, and the new logs will witness the retry.
- Working tree carries the uncommitted slot-tint work (TasksTabView,
  NudgeTheme, TodayTimelineView, NudgeWidget, pbxproj, ARCHITECTURE.md) —
  named out-of-scope by the plan. Left uncommitted and untouched; this
  cycle's commits were staged per-file to keep them separate.

## Open questions

- Should the dedupe guard's eventual redesign gate on `isEvent` before title
  matching, or compare within-kind only? Deferred by the plan until a logged
  collision provides a case.
- The save-failure message currently appends to chat only. If a save failure
  ever occurs with the app backgrounding immediately after, the message
  itself may not persist (`persistSession` writes through the same context).
  Accepted for now — the failure is also in the console — but a planner pass
  on failure-surface durability may be warranted if it ever fires.
