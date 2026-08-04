# Report — 2026-08-03-06 — revert the dialogue frame, keep the tap targets

**Plan:** `archive/2026-08-03-06-plan.md`
**Status:** complete
**Commits:** `19ca050`

---

## What changed

- `Nudge/Views/Components/TasksMessageBox.swift` — the shell body is the -04 plain card again: dimmed backdrop, header row with portrait + "Nudge", chat bubbles (user in `primary` with white text, app in `surfaceAlt`), `radiusSheet` corners, single 1pt `border` hairline, padding 16, conversation max-height 300. The 2pt/1pt double stroke, the flat in-frame dialogue lines (`dialogueLine`), the portrait-beside-text layout, and the local frame weights are all gone — no new theme constants exist, none were left behind.
- `ARCHITECTURE.md` — the shell's entry now records the styling as reverted-after-device-look, with an explicit "do not reintroduce unprompted".

## Verification

- As the plan directed, the revert was driven by git, not reconstruction: I took `260c9a6`'s diff for the file, restored the styling hunks to their -04 form, and then **diffed the result against `5cdf543` (the -04 commit) to prove the residue is exactly the keep-list and nothing else**. The remaining delta, code lines only: the `MessageBoxExpression` enum + its single `image` mapping, the slot taking an expression, `onOpenShell` replacing `onCharacterTap` (character/chevron/row all open the shell), `seed`/`seedLines()`/`answered`, and the header portrait using the state-tracked expression. Zero styling lines in the residue — no stroke, radius, padding, or layout deltas.
- Both schemes build clean (zero warnings).
- Evidence list: shell looks as it did in -04 ✓ (by the diff above); tapping anywhere in the collapsed box opens it ✓ (the -05 tap wiring was untouched); expression routes through one mapping ✓ (slot has the same two call sites: collapsed box `.neutral`, shell state-tracked).
- Collapsed box untouched by this commit entirely — the diff contains no changes to the collapsed body.

## Deviations from the plan

None. The keep-list and the revert-list partitioned the -05 commit cleanly; nothing needed a judgment call.

## Noticed but not done

- The expression currently *shows* nowhere visible (all three cases map to the same grey placeholder), so the revert leaves no visual trace of -05 at all until art exists. Fine — that was the point of the enum being structure, not styling.
- The two -04 rough edges still stand (no row→card morph; the floating tab bar renders above the dim layer). Out of scope: "any further styling — I'll say when."

## Open questions

None — awaiting your word on styling direction before anything visual moves again.
