# Report — 2026-08-03-07 — chat button, and button reshuffle

**Plan:** `archive/2026-08-03-07-plan.md`
**Status:** complete
**Commits:** `ce4b302`

---

## What changed

- `Nudge/Views/Tabs/TasksTabView.swift` — control order below the message box is now: timeline → **Plan my day** → **Start Session** → **Chat** → tab strip. Details:
  - **Plan my day** moved out of the Today header row into a full-width button directly above Start Session, in Start Session's exact existing treatment (height 52, `primary` background, white text, leading icon, `radiusButton`) — the plan's own framing ("same treatment... read as a pair") is what made this the right reading of "moved here" rather than carrying the small capsule down. The Today header row keeps its label and the conditional Clear plan capsule.
  - **Chat** is new, same shape, quiet `surfaceAlt` treatment with `textPrimary` text and a speech-bubble icon. It opens the same shell as every box tap target — one surface, four ways in — seeded via a new `composedMessage` property that runs the exact same pure `TasksMessageComposer.compose` the box runs, so the shell opens on precisely what the box is showing (not a stale or stubbed seed).
- `ARCHITECTURE.md` — the TasksTabView layout-order line updated.

## Verification

- Both schemes build clean (zero warnings).
- Order verified in the body (message box → timeline → planMyDayButton → startSessionButton → chatButton). Chat's action sets `messageShellSeed`, the same state every other entry point sets.
- **The note the plan asked for — how the adjacent same-styled pair reads:** stacked, Plan my day and Start Session are two identical 52pt `primary` slabs, distinguishable only by icon (wand vs bolt) and label. At a glance they read as *one two-row control* rather than two actions — the shared background color does more grouping work than the labels do separating work. Two observations for your styling decision, not actions taken: (1) the eye reads the *top* slab as the primary action, and Plan my day now occupies it — if Start Session is the day's main verb, the color assignment fights the ordering; (2) Chat's `surfaceAlt` quietness accidentally demonstrates the fix: one primary slab among quieter neighbors reads instantly. Deliberately not solved, per the plan.
- On-device feel not verified here (no simulator run in this environment).

## Deviations from the plan

- The plan's parenthetical "Chat takes Plan my day's old position" conflicts with its own numbered list (Plan my day's old position was the Today header row, above the timeline; the list puts Chat 5th, below Start Session). **The numbered list won** — it's explicit, self-consistent, and the color note only makes sense if Plan my day and Start Session are adjacent, which only the numbered-list reading produces. I read the parenthetical as "Chat fills the roster spot Plan my day vacated." If you meant Chat as a capsule in the Today row instead, say so — it's a ten-minute change.
- Chat's `surfaceAlt` treatment is a judgment call the plan left open ("existing button styling" — both the primary slab and the surfaceAlt capsule are existing styles). A third primary slab would have buried the two real actions, so Chat went quiet. Reversible in one line.

## Noticed but not done

- Clear plan now sits alone in the Today header row when auto-placements exist — slightly orphaned; it may want to move next to Plan my day when the pair gets its visual treatment.
- `composedMessage` and the box's internal compose call are the same expression in two places; if a third caller appears, hoist it.

## Open questions

- The pair's visual distinction — your call, with the two observations above as input.
