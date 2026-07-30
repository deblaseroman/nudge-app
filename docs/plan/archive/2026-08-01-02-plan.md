# NEXT — Message box: sized, bordered, and AI-ready

**Status:** APPROVED
**Cycle ID:** 2026-08-01-02
**Source:** design feedback on cycle `2026-08-01-01`

> Still on `automation-run-1`. Commit, do not push, do not merge.

---

## What to build

Three changes to `TasksMessageBox`. The composer's logic and its four
states are correct — this is about how it looks and what can plug into it.

### 1 — Form factor

It should read as **a row in the list, not a banner above it**. Match the
scheduled-task row: same height, same corner radius, same horizontal
insets. The difference is a visible border — a task row is a filled card,
this is an outlined one. Use `NudgeTheme.border`; do not introduce a color.

The leading accent bar from the current version goes away — the border is
the treatment now.

### 2 — Room for a character

Reserve a square on the **left**, vertically centred, sized like the
leading element of a task row so the two align down the tab. For now fill
it with a plain grey placeholder from `NudgeTheme` — no icon, no glyph, no
image asset.

A mascot goes here later (a messenger pigeon; there will eventually be
several, one per surface). So: **make the slot a named subview taking a
single parameter**, not a rectangle inlined into the layout. Swapping the
placeholder for an image should be one line and touch nothing else.

Since the row height is now fixed, say what happens to text that doesn't
fit — truncation, or does the row grow on expand. Tap-to-expand should
still work.

### 3 — An AI seam, unused for now

The composer is deterministic and stays that way **in this cycle**. But
build the surface so an AI-written message can be dropped in without
restructuring:

- The composer should return a message *value* — text plus whatever the
  view needs — rather than the view deriving strings inline.
- There should be one obvious place where an AI-written message would take
  precedence over the deterministic one, marked in a comment. Don't call
  anything. Don't add a config flag for a feature that doesn't exist.
- Say in the report exactly what a future cycle would have to change to
  plug `ClaudeService` in, and what it would *not* have to touch.

**Offline behaviour and token cost are explicitly not concerns this
cycle** — noted because prior cycles treated them as hard constraints and
that's now relaxed for this surface. The deterministic composer stays as
the fallback when an AI message is absent for any reason, which handles it
anyway.

### 4 — Fold in the rationale banner

Your own report flagged it: the AI Refine rationale strip is a second "app
speaks" surface on the same tab. Make it a fifth composer state so there's
one voice in one place. Where it sits in the priority order is your call —
say which and why.

## Why

The box is the app's voice and it currently looks like an announcement
bolted above the content. Sized like a row with a border, it reads as part
of the list — something the app added, not something layered on top. The
character slot is what will eventually carry personality; leaving the seam
now means the mascot lands without a refactor.

## Constraints

- `NudgeTheme` only. No new colors, no inline literals, no image assets.
- No `ClaudeService` call this cycle.
- No text input. Still display-only.
- Don't change the composer's four existing states or their priority order
  beyond inserting the rationale.
- Presentation-only — say so rather than skipping work-order item 5.

## Evidence it worked

- Both schemes build.
- Description or screenshot of the box beside a task row, showing the
  height and leading-element alignment match.
- Each of the five states renders.
- Tap-to-expand still works at the fixed height.
- The character slot swaps to an image in one line — show the line.

## Out of scope

- The actual mascot asset.
- Any AI call.
- Conversational input; extracting the capture pipeline.
- Retiring AI Refine as a button (`ROADMAP.md` §3) — folding its *rationale*
  into the box is not the same thing and doesn't do it.
- The Lexend fonts.
- Merging or pushing.
