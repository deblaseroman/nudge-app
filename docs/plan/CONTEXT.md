# Orientation for the planner

You can read `docs/plan/` and nothing else. This file exists so you can reason
about the system without the code — enough to write a plan that isn't guessing,
not enough to skip asking. **When a decision turns on a detail below, ask for
the relevant root doc to be relayed rather than inferring.** A summary that has
drifted is worse than no summary, and this one will drift.

Protocol: [`README.md`](README.md). Current item: [`NEXT.md`](NEXT.md).

---

## What the app is

iOS app (SwiftUI + SwiftData) that turns brain-dumped tasks into scheduled
ADHD-friendly notifications. Two targets: the app and a widget extension
sharing one store via an App Group.

**The arbiter is the product** — the differentiator is deciding *when to
interrupt someone*, not the task list or planner. Weigh proposals against
whether they improve the interruption decision.

## How the arbiter works

`NudgeArbiter.reevaluate` is declarative and runs end-to-end every time. UI
never schedules notifications; it mutates data and calls the arbiter.

1. **Cancel** everything the arbiter owns (IDs prefixed `nudge.arb.`).
2. **Build candidates** — six builders, below.
3. **Gate** them.
4. **Pick winners and schedule.**

Because step 1 always runs first, a builder that fails to rebuild something
*deletes* it. Several past bugs were this shape.

### The six builders

Every discretionary nudge fires at an offset from **wake**, not a fixed clock
time. Each has its own on/off toggle in Settings, plus a master switch.

> **This table drifts.** Nothing keeps it in agreement with the code — a
> builder added, removed, or re-anchored leaves it silently wrong, and
> break-it-down is already scheduled to disappear from it. Treat it as a shape
> to reason about, and ask for `ARCHITECTURE.md` to be relayed before relying
> on any specific row.

| Builder | Fires | Notes |
|---|---|---|
| Event blocks | lead time before the first event of a cluster | budget-exempt; 14-day horizon |
| Morning prompt | wake + 30m | budget-exempt; skipped when the day is already packed; taps land in Home chat |
| Get-ahead | wake + 2h | anchored to hour-of-day; walks forward, gives up rather than nudging on something overdue |
| Idle / session starter | wake + 3h | paralysis nudge if nothing started |
| Floater check-in | wake + 6h | undated open tasks; excludes anything placed on the timeline that day |
| Break it down | wake + 4h | **paused pending removal — do not build on it** |

Budget-exempt builders (event blocks, morning prompt) skip the shared gates
entirely and do their own checks, so a rule added to the gates does not apply
to them.

### The gates

Busy windows (from calendar events, merged), quiet hours, a daily budget,
minimum spacing between nudges, and per-task fatigue from notification-outcome
history. Gates key off whether a candidate counts against the budget.

Winner selection seeds event-block reminders first, so a discretionary nudge
near an event can be evicted on spacing by that event's own heads-up.

**Fully deterministic — no LLM anywhere in this path.** AI appears at exactly
two points, both where data enters: brain-dump capture and calendar import.
Do not propose an API call in the arbiter's path; non-deterministic timing is
undebuggable. This is a `DESIGN.md` rule, not a performance preference.

## What is deliberately not armed

These are considered states, not oversights. Proposing to "fix" one without
saying why it's now authorized will get pushback.

- **Stakes is not wired into scoring.** The scorer accepts an optional stakes
  input, but no production call site passes it — the number is identical to the
  pre-stakes one. Stakes means *size of the consequence*, not category and not
  urgency; time pressure is a separate axis.
- **Arming it is blocked on floater data.** The floater check-in has never
  produced a single outcome row, so arming stakes first would penalize floaters
  and suppress the exact thing being measured. Rollover was fixed recently and
  baseline data should now start accumulating.
- **Wake+6h is a known-bad floater anchor**, deliberately not retuned yet: with
  a default 08:00 wake it fires at 14:00, where midday events suppress or evict
  it. It can't be retuned against evidence until the evidence exists.
- **The fatigue gate is off.** Outcomes are being *recorded and observed*
  before anything consumes them.

**Outcome recording** captures two independent things per nudge: behavior
(tapped / dismissed / acted / engaged / ignored, with un-acted nudges resolved
later) and explicit opinion (👍/👎). Nothing reads the opinion half yet.

**There is a standing evidence rule:** any change that alters what the arbiter
does gets a DEBUG before/after comparison on real data before it goes live.
Plans that change arbiter behavior should say what comparison would falsify
them. If a change genuinely can't alter behavior, say that instead — the
reasoning gets reported either way.

## Which root doc holds what

You cannot read these. Ask for the relevant one to be relayed.

- **`CLAUDE.md`** — the authority on current state. Holds the numbered work
  order the section above summarizes, the list of known-but-unfixed bugs, build
  and verification commands, and hard invariants (e.g. a new data model must be
  registered in three hand-synced lists; new profile fields need property-level
  defaults or existing installs crash at launch). **Ask for this whenever a
  plan touches sequencing, or when the summary above is load-bearing.**
- **`ARCHITECTURE.md`** — file-level map: one responsibility per file, plus the
  data-flow overview. Ask when a plan needs to name specific files or call
  sites.
- **`DESIGN.md`** — product intent: positioning (assistant, never an
  authority — the app must never promise an outcome), the AI-at-the-edges rule,
  what stakes means, the two feedback channels (behavior and explicit opinion,
  never a survey), and the no-shaming rule. **Ask before proposing anything
  user-facing** — copy, what the user is told, when they're interrupted.
- **`ROADMAP.md`** — the index of outstanding work: what's queued and under
  consideration, as distinct from `CLAUDE.md`, which holds the constraints in
  force right now. Ask for it when a plan needs to fit alongside work already
  intended, or before proposing something new that may already be on it.

Reports in `reports/` are the other half of your context: they carry what
actually happened, including deviations and things noticed but deliberately not
done. Read the recent ones before planning.
