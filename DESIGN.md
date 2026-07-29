# Nudge — Design Intent

Why this app behaves the way it does. `ARCHITECTURE.md` describes how the code
is arranged; this file describes what the product is trying to be, so a change
that compiles and fits the architecture can still be wrong here.

Read this when a change touches **product behavior** — what the user is told,
when they're interrupted, what the app decides on their behalf. Implementation
sequencing (what's armed, what's paused, what's deliberately off) lives in
`CLAUDE.md`'s work order, not here.

---

## Who this is for

Students and adults with ADHD and executive dysfunction.

**Design for someone at their least capable, not their most motivated.** The
person who opens this app at their worst is the person it's for. A feature that
only works when the user is already organized enough to maintain it has failed
the target user — it's added to the executive-function load the app exists to
reduce.

## Positioning: an assistant, not an authority

Nudge proposes a starting point. The user runs their own life.

**The app must never promise an outcome.** No "follow this plan and you'll get
an A" — not in notification copy, not in chat, not in onboarding. The app
structures work and surfaces what matters; the user owns the result. Any copy
that trades on a guaranteed outcome is out of bounds regardless of how well it
converts.

The distinction is practical, not just tonal: an assistant's wrong suggestion
costs the user a moment's judgment, and an authority's wrong instruction costs
them their trust in everything else it says.

## The arbiter is the product

The differentiator is **deciding when to interrupt someone.** Not the task
list, not the timeline, not the planner — those are plumbing that feeds the
interruption decision.

Weigh feature work against whether it improves that decision. A feature that
makes the task list nicer without making the arbiter smarter about when to
speak is, at best, neutral; it still costs maintenance and screen space. This
is the tiebreaker when scope has to be cut.

## AI at the edges, deterministic in the core

There are exactly **two AI touchpoints, both where data enters the system:**

1. Brain-dump capture — free text into structured tasks.
2. Calendar import.

Everything downstream is arithmetic: ranking, planning, notification timing.
Instant, offline, identical every run.

**Do not put an API call in the arbiter's path.** Non-deterministic
notification timing is undebuggable — you cannot reproduce a complaint about a
badly-timed nudge if the decision isn't repeatable — and it erodes user trust
in a way that a slightly worse deterministic decision does not. A user can
learn the behavior of a system that always does the same thing with the same
inputs. This constraint is the reason the notification path can be reasoned
about at all.

## Stakes means consequence

**Stakes is the size of the consequence if the thing doesn't happen.** It is
not a category, and it is not urgency.

Explicitly **not school-specific**: a job interview, a medical appointment, and
a final exam are all high stakes. Any implementation that reads stakes off a
course field or a school-shaped heuristic has narrowed it wrongly.

Time pressure is a **separate axis**, handled by the urgency curve. A task can
be urgent and low-stakes (a form due tonight that nobody will notice), or high-
stakes and weeks away. Collapsing the two loses exactly the distinction that
makes the ranking useful.

## Study tasks from exam events

*Intent — not built as of this writing.*

An exam on the calendar should produce the work that leads up to it, because
the user who most needs that scaffolding is least likely to build it by hand.

- The classifier returns a **coarse prep-lead-time band** — roughly 3 / 7 / 14
  days — from the exam title. Course level and subject carry the signal, and
  the model already knows organic chemistry outranks intro marketing.
- **No web search.** There is no reliable data on how long anyone should study
  for a given exam, and fabricated precision is actively harmful here — a
  confident "start 11 days out" invents an authority the app doesn't have. The
  coarse band is honest about being a rough guess.
- When the exam reaches its lead time, **create study tasks daily until the
  exam**, and **tell the user in chat.** Silent creation is not acceptable —
  the user should never discover work on their list they can't account for.
- **Check for an equivalent task the user already made.** Duplicating the
  user's own planning is worse than doing nothing.
- **Tombstone deletions.** If the user deletes a generated study task, that
  deletion is a decision and it persists. Silently regenerating it teaches the
  user that their input doesn't matter.

## Feedback comes from two channels

1. **Behavior** — what the user actually did with a nudge.
2. **Explicit opinion** — 👎, and conversational questions in chat.

**Never a periodic survey.** Two reasons, both disqualifying: stated preference
diverges from revealed preference, so the survey answers would be worse data
than the behavior already collected; and a monthly questionnaire is precisely
the executive-function tax this app exists to reduce. Asking the user to do
administrative work about the app is a regression no matter what it returns.

## Never shame the user

**No copy that implies failure for missed work.** Not "you missed this again,"
not streak-breaking language, not guilt framed as motivation.

Missed deadlines get **rescheduled with more urgency, not punishment.** The
response to slippage is to make the next nudge land better, never to make the
user feel worse about the last one. The target user has usually supplied plenty
of self-criticism already; adding to it makes the app something to avoid, and
an avoided app nudges nobody.
