# Report — 2026-08-03-05 — framed dialogue styling and character expressions

**Plan:** `archive/2026-08-03-05-plan.md`
**Status:** complete
**Commits:** `260c9a6` (all three items — one commit, reasoning below)

---

## What changed

All in `Nudge/Views/Components/TasksMessageBox.swift` + the `TasksTabView` wiring + one `ARCHITECTURE.md` entry.

**Item 1 — framed dialogue look**
- The shell is now a framed dialogue box: portrait beside the text, dialogue lines sitting flat in the frame (no chat bubbles — app voice in `textPrimary`, user replies right-aligned in `primary`; the alignment + color split is enough to keep the two voices apart), options and the input field inside the frame.
- **What I added beyond the theme, as the plan asked:** the theme has no border *weights*, so the frame is a **2pt `textPrimary` outer stroke with the existing 1pt `border` hairline inset 5pt inside it** — the double line is what reads "dialogue frame" without pixel fonts or assets. Radius is the existing `radiusCard` (16); every color is `NudgeTheme`'s. No new theme constants — the weights are local to the shell, worth hoisting only if the style survives judgment.
- **No typewriter reveal** — text appears immediately (`seedLines` sets the array once; the only animations are the standard ones on append/dismiss).

**Item 2 — expression enum**
- `MessageBoxCharacterSlot` now takes `MessageBoxExpression` instead of `Image?`.
- **Cases chosen — three:** `neutral` (resting face; the collapsed box), `asking` (a question is on the table — the one state that must read differently at a glance, and the shell's whole reason to exist), `pleased` (an answer just landed; the acknowledgment beat). **Deliberately nothing in the worried/disappointed family** — a character that looks concerned about the user's list is DESIGN.md's never-shame rule violated in art instead of copy.
- The expression → image mapping is one computed property (`MessageBoxExpression.image`), all nil → grey placeholder today. Real art later = fill that one switch; no call site changes. The shell's portrait already tracks state: `asking` while the options are up, `pleased` after an answer, `neutral` otherwise — so the first real art drop immediately animates the conversation.

**Item 3 — the dropdown opens the chat too**
- `onCharacterTap` became `onOpenShell(TasksMessage)`: the character, the chevron, and the row tap all open the same shell. The composed message rides along and **seeds the shell's dialogue** (headline + detail as the opening app lines, then the stub question) — necessary, not decorative: the row tap used to expand the detail in place, so the shell replacing that tap must keep the detail reachable.
- Chevron *visibility* rule untouched (only when detail exists) and the collapsed appearance is unchanged — what changed is where the tap leads. A nil `onOpenShell` keeps the legacy in-place expansion, so the component standalone behaves exactly as before.

## Verification

- Both schemes build clean (zero warnings).
- Evidence list, by construction/code review: framed look with portrait ✓ (needs your eye for "reads as a dialogue box" — that's the judge-by-eye point); immediate text ✓; expression enum with a single mapping ✓ (verified the slot has exactly two call sites, collapsed box `.neutral` default and the shell's state-tracked one); both entry points open the shell ✓.
- Not verified here: feel on device. Same two rough edges as last cycle stand (no row→frame morph; tab bar floats above the dim layer).

## Deviations from the plan

- **One commit for three items** — previous cycles were commit-per-item, but the shell rewrite genuinely entangles them (the frame layout contains the expression-driven portrait; the seeding is what makes the row-tap redirect safe). Splitting would have been hunk-surgery on one file for audit cosmetics.
- Item 3 quietly retires the in-place detail expansion when the shell is wired (the plan didn't say what should happen to it). I read "one surface, two ways in" as superseding it, and moved its content into the shell's seed rather than leaving two different expanded states. If you want the in-place expansion back alongside the shell, it's still in the code behind the nil-callback path.

## Noticed but not done

- The frame weights (2pt/1pt/5pt inset) are local to the shell; if the style survives, they belong in `NudgeTheme` next to the radii.
- The collapsed box could also show `asking` when the (future, real) question queue is non-empty — the enum makes that a one-liner later; nothing does it now because there is no real question state to read.
- The stub "Noted. (Prototype — nothing is saved yet.)" reply now renders under a `pleased` portrait — fine for a stub, but the real ack copy should be written against DESIGN.md when wiring happens.

## Open questions

- Judge the frame: restrained enough? The double line is the entire retro gesture — easy to thicken, color (`primary` instead of ink), or drop.
- The three expressions: enough for the first art pass, or do you want a fourth (e.g. `sleeping` for quiet hours) before the art brief goes out?
