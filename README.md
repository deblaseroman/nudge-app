# Nudge

An iOS planner for students with ADHD. Most planning apps help you *see* your day — Nudge decides **when to interrupt you**, and gets out of the way the rest of the time.

<!-- SCREENSHOTS: three side by side — Tasks tab, a notification on the lock screen, the timeline -->

Built with SwiftUI and SwiftData, with a home-screen widget, Live Activities, and Apple Calendar / Canvas import.

---

## The problem

People with executive dysfunction usually know what they need to do. The hard part is starting.

Interviews I ran while researching this turned up the same thing repeatedly: the apps meant to help demand planning effort up front, and planning effort is exactly what ADHD makes expensive. 
One participant said the only tools that ever helped were ones that *reduced* friction — "usually the opposite of what time management apps do." Another described relying on an app specifically because it required zero engagement.

So the useful thing isn't a better surface to look at. It's something that reaches out at the right moment and asks for almost nothing back.

## The approach

Nudge captures tasks from a plain brain dump — type it however it comes out — and imports your calendar. Everything after that is about timing.

A component called the **arbiter** decides what notification to send, when, and whether to send one at all. It runs on every meaningful change: it cancels everything it owns, rebuilds candidates from scratch, filters them through a set of gates, and schedules the winners.

The gates are the interesting part:

- **Busy windows** — never nudge during a class, a shift, or an appointment
- **Quiet hours** — decoupled from bedtime, because students work at night
- **Daily budget and spacing** — a hard ceiling on interruptions, and a minimum gap between them
- **Fatigue** — repeated ignored nudges about the same task back off
- **Outcome tracking** — every notification records what happened to it: acted on, engaged with, or ignored

That last one is what makes it a nudge engine rather than a scheduler. The app measures whether its own interruptions work.

<!-- SCREENSHOT: the arbiter's debug trace, or a diagram of the pipeline -->

## Design decisions

**AI at the edges, deterministic in the core.**
There are exactly two places an AI model runs: parsing a brain dump, and classifying imported calendar events. Everything downstream — ranking, planning, notification timing — is arithmetic.

This was deliberate. Notification timing has to work offline, instantly, and identically every run. If a model decided when to interrupt you, "why didn't I get a reminder?" would have no answer, and the feature would be undebuggable by construction.

**Importance means consequence, not category.**
Tasks carry a *stakes* value — how bad is it if this gets missed — assigned by reading the task, not by matching keywords. A job interview, a medical appointment, and a final exam all rate high for the same underlying reason. 
Deliberately not school-specific: an app that only understands importance through coursework fails its user the moment life isn't coursework.

Urgency is tracked separately. Something due tomorrow isn't automatically consequential, and a final three weeks out doesn't stop mattering.

**The app never promises an outcome.**
It would be easy to write "follow this plan and you'll get an A." It would also be harmful: a student who follows the plan and gets a B has been told by the app that they failed. Nudge structures the work and surfaces what matters. The user owns the result.

**Honest about the situation, never about the person.**
Being agreeable is easy to ignore and doesn't help anyone start. So the app is direct about time pressure — what's due, how long is left, how long you took last time. 
But the urgency comes from stating facts, not from judging the user. *"Your exam is in six days; last time you started two days out"* rather than *"let's get you better prepared this time."* Present tense, no verdicts.

## Exam prep

The feature that ties it together: when an exam appears on your calendar, the app works out how far ahead to start — a coarse band of a few days to two weeks, judged from the course and exam type — and creates a study task for each day until then, telling you in the app that it did.

Deliberately coarse. There's no reliable data on how long anyone should study for a given exam; it depends on what you already know and how the professor writes tests. Precision the app can't justify would be worse than none.

<!-- SCREENSHOT: prep tasks in the task list -->

## Architecture

Two targets: the app and a widget extension, sharing a SwiftData store through an App Group.

- `NudgeArbiter` — notification decisions, gates, scheduling
- `DayPlanEngine` — deterministic placement into free gaps around fixed commitments
- `ClaudeService` — the two AI entry points
- `EisenhowerScorer`, `DurationModel`, `BusyWindowResolver` — the deterministic core

Fuller detail lives in [`ARCHITECTURE.md`](ARCHITECTURE.md) (how the code is arranged) and [`DESIGN.md`](DESIGN.md) (product intent and the rules above).

## Building it

Requires Xcode with an iOS 26.4 deployment target. Add a `Secrets.plist` with an Anthropic API key — the app degrades gracefully without one; capture and classification stop working, everything else continues.

## What's next

- Automatic day planning on first launch each morning
- A learning layer that reads accumulated outcome data and adjusts nudge timing per person
- Retrospectives — "how did that exam go?" — so the app learns whether its interventions actually worked, rather than only whether its notifications got tapped

## Notes

I researched, designed, and directed this project; the Swift implementation was written by Claude Code under my direction. The problem definition, user research, architecture, and every design decision above are mine. I also did my own research and conducted surveys to gather more detail about existing apps.

Three months into this project, I found [Tiimo](https://www.tiimo.com) — a well-funded, award-winning app in the same space. It's a better visual planner than mine and I'm not trying to out-build it. What it doesn't do, by its own users account, is prepare the user for a major event or exam. That's the part I'm building.
