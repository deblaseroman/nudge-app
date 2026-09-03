# NEXT — Make silent drops impossible, and capture what the user said

**Status:** APPROVED — three items
**Cycle ID:** 2026-08-05-02
**Source:** Sep 2 brain dump — a stated 6pm event never became a row, and
nothing anywhere recorded why. Read-only diagnosis in chat this session.

> On `fix/notification-threading-and-memory`. **One commit per item.** Both
> schemes build after every commit. Do not push, do not merge.
>
> **If an item is larger than described or needs a decision not written here,
> ship the smaller honest version and say so.**

---

## Why this exists

A dump entered Sep 2 described a fixed commitment that evening ("event with my
friends at 6, back home about 9 or 10") followed by a stated plan for the next
day. Eight ordered tasks were created, all correct. The event does not exist
anywhere in the app — not Events, not Calendar, not any task tab.

The diagnosis enumerated every way an item can vanish between the model's
response and a row. Six of them, and **five log nothing at all**. The dedupe
guard is the only per-item drop, and it was cleared for these titles: it needs
whole-string containment, and "event with friends" doesn't match any of the
eight. The remaining explanation is that the model never emitted the item —
which by design leaves no trace.

That is the thing to fix, and it is two problems, not one.

**The app cannot tell the difference between "the model returned nothing" and
"we threw it away."** Every path reports success. An app whose entire promise
is *write it however it comes out* dropped a fixed commitment and told the user
everything worked. This is the same failure shape as the dedupe marker that was
silently killing event reminders — the symptom was absence, and absence is
invisible until someone counts.

**The prompt licenses dropping.** A dump containing a plan plus one item that
isn't part of the plan risks losing the odd one out, absorbed as context rather
than captured. `ClaudeService.swift:209` already documents this happening
before — "a previous bug dropped an item that was only asked about; do not
repeat that." It happened again, in a different shape.

Both fixes are keyed on the category, not on this dump. Item 1 makes any drop
visible whatever causes it; item 2 states a rule about what a dump contains
that holds for dumps nobody has written yet. Neither names an event, a title,
or a phrase.

---

## Item 1 — Every drop leaves a trace

**The rule: no item the model returned may fail to become a row without saying
so.** Currently five of six drop points are silent.

Add DEBUG logging at each, naming the item and the reason. From the diagnosis,
in order:

1. `ClaudeService.swift:1247` — only the first content block is read; further
   blocks discarded.
2. `ClaudeService.swift:1321-1327` / `extractJSONObject` — everything outside
   the first balanced object discarded.
3. `ClaudeService.swift:1440` — `newTasks ?? []`: a missing or misspelled
   `new_tasks` key becomes a normal empty capture.
4. `HomeTabView.swift:448` — the dedupe `continue`. Log the incoming title, the
   existing title it matched, and which clause suppressed it (same-day, or the
   nil-date fallthrough).
5. `HomeTabView.swift:554` — `try? modelContext.save()`. **This one is not just
   a log.** A save failure silently discards the whole batch after the UI has
   already shown it. Catch the error, log it, and surface a failure to the user
   rather than swallowing it.

Then add the count reconciliation that makes the whole class checkable in one
line: after the insert loop, DEBUG-print items returned, items inserted, and
items dropped with reasons, so a mismatch is visible without counting parsed-date
lines by hand.

`#if DEBUG` for the logs. The item 5 save handling is production behavior.

**Deliberately not in scope:** changing what the dedupe guard matches on. It is
a real hazard — events are deduped against tasks, the new item's `isEvent` isn't
read until ten lines after the guard, and a nil date suppresses on title alone.
But the right shape for that guard is a product decision, and once it logs, the
next collision will show its own evidence. Log it now, redesign it when there's
a case.

## Item 2 — The prompt states what a dump contains

In `chatSystemPrompt`, alongside the existing CAPTURE-FIRST rule:

> Every distinct commitment or intention in the message becomes an item.
> Belonging to a stated sequence is a property of an item, not a filter on
> which items exist. A message that describes a plan may also contain things
> outside that plan — capture those too.

Phrased as a principle, not a case list. It must not name events, times of day,
or any specific phrase — a dump mixing an errand with a deadline, or an
appointment with a plan, has the same shape.

Also, from the previous session's trace: `"this evening"` has no resolution
rule while `"tonight"` does. Fix the **category** — the relative-day block
should state the principle for resolving any relative day reference to a date,
not enumerate the phrases it happens to cover. Do not add "this evening" as a
sixth bullet.

## Item 3 — The error message stops asserting a cause

`HomeTabView.swift:596-598` shows *"Sorry, I couldn't connect right now. Check
your internet and try again"* for any error that isn't a `ClaudeError` — which
includes `DecodingError` from a malformed response. The app tells the user the
network failed when it does not know that.

That is fabricated precision in error copy, and `DESIGN.md` guards against it
directly: a confident claim the app can't justify is worse than none. It also
has a behavioral cost — a user told to check their internet retries, and a
retry after a partially-successful capture is how duplicates get made.

Rewrite it to state only what is known and what to do. Facts, no diagnosis.
Follow `DESIGN.md`'s voice — the calibrated refusals are the model ("Nothing to
plan — your list is clear"). Include the actual error type in DEBUG.

## Constraints

- No change to the tab predicates. The Today tab reading `sequenceIndex` and
  no date is a real problem and is **not this cycle** — see below.
- No change to what the dedupe guard matches on (item 1 logs it only).
- `DESIGN.md` and `ROADMAP.md` are Roman's. Do not edit, do not commit changes
  found in them.
- Per `CLAUDE.md`: this cycle touches an AI call site's prompt (item 2), so
  `docs/plan/CONTEXT.md`'s census sections and stamp update in the same commit
  if the census facts change. Item 2 changes prompt content, not the site
  inventory — say in the report which applies.

## Evidence it worked

- Re-run a dump on device that mixes a fixed commitment with a stated ordered
  plan. The console shows returned / inserted / dropped, and the numbers
  reconcile. If an item is dropped, the reason is named.
- The specific case: a dump of this shape produces an item for the commitment
  that is not part of the sequence. If it still doesn't, the log now says
  whether the model omitted it or the app dropped it — **that distinction being
  visible is the pass condition for item 1**, independent of whether item 2's
  prompt change works.
- Item 3: force a decode failure (DEBUG-only path is fine) and confirm the user
  sees copy that doesn't mention the network.
- No arbiter behavior changes here, so work-order item 5 doesn't apply. Say so
  rather than skipping it silently.

## Out of scope

- **The tab partition.** Four tabs on four different axes, Unscheduled
  admitting by failing everything else, tasks appearing in two tabs, completed
  unplaced tasks appearing in none, and "Today" meaning `sequenceIndex != nil`
  rather than a date. Diagnosed this session, deliberately deferred — it needs
  a product decision about what a plan's day is, and that decision is worth
  making once rather than patching.
- The countdown showing hours-to-deadline on tasks that have no real deadline.
  Same reason: it needs a deadline-vs-intended-day distinction at capture,
  which is its own cycle.
- Arming stakes. Still blocked on floater baseline data and the passport flip
  test, per `CLAUDE.md` items 1–2.
- The slot-tint change committed outside the bus (no cycle ID, no report).
- The unused HealthKit entitlement and the calendar full-access usage-string
  crash — TestFlight blockers, separate cycle.
