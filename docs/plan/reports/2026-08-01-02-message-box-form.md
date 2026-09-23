# Report — 2026-08-01-02 — Message box: sized, bordered, and AI-ready

**Plan:** `archive/2026-08-01-02-plan.md`
**Status:** complete
**Commits:** `3c0b52c` (plan archived), `f352d9b` (the change), plus this report.

---

## What changed

- `Nudge/Views/Components/TasksMessageBox.swift` — form factor rebuilt,
  character slot added, AI seam added, rationale state added. Composer's four
  existing states and their order untouched.
- `Nudge/Views/Tabs/TasksTabView.swift` — the standalone rationale banner is
  removed; `refineRationale` now feeds the box.
- `ARCHITECTURE.md` — component and Tasks-tab entries updated.

## The four asks

**1 — Form factor.** The box now shares the task row's footprint exactly:
`padding(16)`, `NudgeTheme.radiusCard` corners, and the same horizontal
insets (both live in the tab's `padding(.horizontal, 20)` VStack, so the
edges align by construction). The distinction is carried by fill alone: task
rows are filled cards (they also carry a 1-pt `NudgeTheme.border` stroke —
so border alone wouldn't have distinguished them), the box is **outlined
only**, `NudgeTheme.border` stroke over no fill. The accent bar is gone. Side
by side: same width, same corner radius, same edge positions; the box reads
as a hollow row, a task row as a solid one.

**Text that doesn't fit — the answer to the plan's question:** collapsed, the
headline truncates at **two lines** (the footprint of a task row that has a
subtitle), with the chevron indicating there's more. Expanding **grows the
row in place** — same width, same corners — to the full headline plus the
detail text; tapping again collapses it back. So: truncation while collapsed,
growth on expand, and tap-to-expand works unchanged at the fixed collapsed
height.

**2 — Character slot.** `MessageBoxCharacterSlot`, a named subview with a
single parameter (`image: Image?`), 28×28 — the size of the task row's
leading checkbox, vertically centred with the same 14-pt gap the rows use, so
the two align down the tab. Placeholder is a `NudgeTheme.textPlaceholder`
rounded square — no icon, no glyph, no asset. **The one-line swap:**

```swift
MessageBoxCharacterSlot(image: Image("pigeon-tasks"))
```

at the single call site in `TasksMessageBox.body`; nothing else changes.

**3 — AI seam.** `compose` gains `aiMessage: TasksMessage? = nil`, returned
ahead of every deterministic state, with the seam marked in a comment at that
early return. Nothing produces one — no call, no config flag. What a future
cycle **has to change** to plug `ClaudeService` in:

- produce a `TasksMessage` somewhere (a service call, presumably cached the
  way `DayPlanRefiner` caches its rationale), and
- hand it to `TasksMessageBox` (one new parameter pass in `TasksTabView`)
  so the view forwards it into `compose`.

What it does **not** have to touch: the view layout, the character slot, the
five deterministic states, the priority logic, the tapped-nudge keys, or any
call site of the composer — the deterministic composer is already the
fallback for nil, which is also the offline/no-key story arriving for free.
`TasksMessage` is the contract: anything that can build one can speak here.

**4 — Rationale folded in, placement my call:** it sits **between
high-stakes and resting** (fifth of six branches, state 4 of 5 user-visible
states). Why there: overdue and high-stakes-approaching are the day's
actionable facts — the things the arbiter would interrupt for — while the
rationale is stable all-day context whose visible result (the placements)
already sits on the timeline directly below the box. In the common
just-refined case the user has just planned their day and rarely has
something overdue-and-unaddressed at that moment, so the rationale surfaces
immediately anyway. The standalone banner is deleted, so the tab now has one
voice in one place.

## Verification

- Both schemes build.
- **Five states render** (by code path; no device here, same standing gap as
  the whole branch): tapped-nudge, overdue, high-stakes, rationale ("Here's
  the thinking behind today's plan." + the rationale as expandable detail),
  resting. The rationale state is reachable exactly when `DayPlanRefiner`
  cached a rationale today and nothing above it applies.
- **Tap-to-expand at fixed height:** the tap toggles `isExpanded`, which
  lifts the two-line limit and reveals the detail; the collapsed footprint is
  fixed by the line limit + padding, not a hard frame, so Dynamic Type can't
  clip it.
- **Presentation-only** (work-order item 5, stated rather than skipped): no
  builder, gate, scheduling, or outcome code touched. A before/after
  candidate dump would print two identical columns.

## Deviations from the plan

- **"Same height" is implemented as same vertical metrics** (padding, font
  sizes, line counts) rather than a hard-coded frame height. A hard
  `frame(height:)` would clip under Dynamic Type; matching the metrics gives
  the same rendered height at default type size and degrades the same way
  task rows do. Worth one glance on device.
- The plan's premise that a border alone distinguishes the box turned out
  half-true — task rows already carry the same 1-pt border. The distinction
  as built is filled-vs-hollow, which still uses only `NudgeTheme.border` and
  reads as intended; noting it since the plan's wording ("the difference is a
  visible border") didn't survive contact with the row's actual styling.

## Noticed but not done

- The device checklist now trails the branch by two cycles (this one and
  `-01`). A message-box section covering the five states, the row-alignment
  glance, and the cold-launch tap path is small and could ride the next
  checklist touch.
- `restingMessage` always returns a detail, so the resting box always shows
  a chevron — unchanged from last cycle; still a one-line change if it reads
  as noisy on device.
- The AI Refine **button** itself stays (explicitly out of scope; only the
  rationale's rendering moved).

## Open questions

- When the mascot asset lands: does the pigeon appear in every state, or
  only when the box has something beyond resting to say? The slot renders
  unconditionally today; a per-state character (or a per-state pose) is a
  parameter change, but which states get one is a design call.
- For the AI cycle: does the AI message replace the composer's *text* only,
  or may it also decide expandability (detail vs none)? `TasksMessage`
  supports both today; worth deciding before the prompt is written.
