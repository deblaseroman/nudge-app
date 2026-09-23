# Report — 2026-08-03-08 — move the chat button into the message box

**Plan:** `archive/2026-08-03-08-plan.md`
**Status:** complete
**Commits:** `e4f9ec0`

---

## What changed

- `Nudge/Views/Components/TasksMessageBox.swift` — the box carries the chat affordance itself now: a compact chip in its bottom-right, opening the same shell as every other tap target (`onOpenShell(message)`, so seeding is the box's own composed message — no duplicate compose anywhere anymore). Rendered only when a shell is wired; callers that never opted in see the box exactly as before.
- **Treatment chosen, as the plan asked:** a primary-stroked capsule — bubble icon + "Chat", 30pt tall, `fontMedium` 13, `NudgeTheme.primary` text and 1pt stroke, no fill. It deliberately matches the shell's own option chips, so the doorway previews the interaction idiom waiting inside; and on the outlined box a stroked chip reads as "part of the box" where a filled button would read as content.
- **The content-shift question, answered explicitly:** nothing shifted or truncated. The chip is a new row *below* the untouched content row (character / headline / detail / chevron all keep their exact layout), so the box grows downward by ~40pt (chip + spacing) when the shell is wired. Growth instead of crowding was the only way to satisfy "don't shift, don't truncate" — a corner overlay would have collided with long headlines, and reserving trailing space would have narrowed the text.
- `Nudge/Views/Tabs/TasksTabView.swift` — the stack-level `chatButton` and its `composedMessage` helper are gone (that helper existed only to seed the external button; the chip needs nothing — the box already holds the message). Remaining stack: box → timeline → Plan my day → Start Session.
- `ARCHITECTURE.md` — layout-order line and the message-box entry updated.

## Verification

- Both schemes build clean (zero warnings).
- Evidence list: chip sits bottom-right in the box ✓; gone from the stack below the timeline ✓ (builder deleted, not just unmounted); other content unaffected ✓ (the content row's code is character-for-character what it was — the diff only wraps it in a VStack and appends the chip row).
- On-device look not verified here; the chip is redundant with the row tap by design (visible affordance vs. convenience), which is worth confirming feels right rather than doubled.

## Deviations from the plan

None. The one judgment call the plan delegated (treatment) is described above.

## Noticed but not done

- The box now has a visible affordance, which re-opens a -05 question: the chevron's job (it also leads to the shell) is now arguably covered by the chip; the chevron could revert to meaning "there's more detail" or disappear. Left alone — one affordance change per cycle.
- `Noticed in -07 and still true:` Clear plan sits alone in the Today header row when auto-placements exist.
- The adjacent Plan my day / Start Session pair remains as -07 left it, per out-of-scope.

## Open questions

None blocking — the chip treatment and the ~40pt growth are the two things to judge on device.
