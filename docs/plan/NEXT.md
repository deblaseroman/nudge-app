# NEXT — Tasks tab: message box and layout reorder

**Status:** APPROVED
**Cycle ID:** 2026-08-01-01
**Source:** design discussion — first version, will be extended

> Still on `automation-run-1`. Commit, do not push, do not merge.

---

## What to build

A **read-only message surface** at the top of the Tasks tab, plus a layout
reorder. This is version one of the app's only place to *speak* — every
other surface either takes input or shows data.

### Layout

Current order, top to bottom: header + description → Start Session →
Completed → timeline → sections.

New order:

1. Header — **delete the "Overdue tasks rise to the top…" description
   line.** It explains a sort order the user doesn't need narrated.
2. **Message box** (new)
3. Timeline
4. **Start Session** (moved down from above the timeline)
5. Everything else unchanged

### The message box

- **No text input. None.** No field, no send button, no keyboard. It is a
  display surface. This is deliberate and not a v1 shortcut — Home already
  owns capture, and a second capture path doubles where a capture bug can
  live.
- Open box styled to read as the app speaking — not a card, not a task row.
  Use `NudgeTheme`; no new colors.
- Tappable to expand when there's more detail than fits. Collapsed shows a
  line or two; expanded shows the full message.

### What it says — deterministic, no AI this cycle

Everything below comes from data the app already has. **Do not add a
`ClaudeService` call in this cycle.** That keeps the box working offline and
with no API key, and it's the AI-at-the-edges rule in `DESIGN.md`.

Priority order — show the first that applies:

1. **A nudge was just tapped.** The user tapped a notification and landed
   here; the box explains that nudge in more detail than a banner allows.
   The idle "Not yet" flow already has a durable-intent pattern for exactly
   this (`pendingIdleTaskIDKey` in App Group defaults, consumed on
   appear/active) — reuse that mechanism rather than inventing a second one,
   and say whether it generalises cleanly to other kinds.
2. **Something is overdue.** Name what and by how long.
3. **Something high-stakes is approaching.** Name it and the days remaining.
4. **Resting state.** A plain line about the day — what's open, what's next.
   Never blank: an empty box at the top of the most-used tab is dead space.

### Tone

`DESIGN.md` applies and this is the surface where it bites hardest — it's
the app's voice. State facts. No verdict on the user, no promise of an
outcome, no implied failure for missed work. "Two things due today" is
right; "you're falling behind" is not.

## Why

The app has no way to explain itself. Notifications are 60 characters and
gone; the task list shows state without context. This is the surface for
the things we've designed but had nowhere to put: what a nudge meant, what
the app created and why, how a week is shaping up.

Read-only first because the valuable half is the app *speaking*, and that
half needs none of the capture machinery. Making it conversational later
means extracting `HomeTabView.sendMessage` into a service — real work, own
cycle, not this one.

## Constraints

- **No `ClaudeService` call.** Deterministic content only.
- **No text input.**
- No new `@Model` unless the message store genuinely needs persistence —
  say which you chose and why. If it does need a model, remember the three
  hand-synced schema lists.
- `NudgeTheme` only. No new colors, no inline literals.
- Moving Start Session must not break the session flow or the picker.
- `ROADMAP.md` §1 untouched.
- This is a layout and presentation change, not an arbiter change — say so
  explicitly rather than skipping work-order item 5 silently.

## Evidence it worked

- Both schemes build.
- Screenshots or a description of each of the four message states.
- The resting state is never blank.
- Start Session still starts a session from its new position.
- Tapping a notification body lands on Tasks and the box explains it.

## Out of scope

- Any conversational or input capability.
- Extracting the capture pipeline.
- AI-generated message text.
- Retiring the AI Refine button (`ROADMAP.md` §3 — still queued).
- Study tasks from exam events.
- The Lexend fonts.
- Merging or pushing.
