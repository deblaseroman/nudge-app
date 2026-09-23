# Report — 2026-08-03-04 — forced start day + interactive message box shell

**Plan:** `archive/2026-08-03-04-plan.md`
**Status:** complete
**Commits:** `5dfbcd8` (item 1), `5cdf543` (item 2)

---

## What changed

**Item 1 — a forced start day is acted on (`5dfbcd8`)**
- `Nudge/Services/ExamPrepSweep.swift`, two edits.
- **The mechanism of your 10:30pm incident:** `startDayDecision` worked correctly — zero plannable minutes left (the `DayWindow` had closed at bed−60), so it returned `tomorrowOnly` and the question was correctly skipped. The bug was one step later: the expansion's post-check *"split work needs a day before the deadline; deadline pressure beats bedtime"* saw that starting tomorrow left zero days before a deadline of **tomorrow**, and snapped the start back to today — generating one session due 23:59 tonight, at 10:30pm. So the specific shape is: split-work commitment, due tomorrow, captured after the plannable window closed.
- **The rule now used:** `tomorrowOnly` means tomorrow, unconditionally. When tomorrow *is* the deadline day, the one-day schedule lands on the deadline day itself — legitimate because a bare due date resolves to 23:59, so a session that day still precedes it. The split-work generation step now counts the start-equals-deadline day as one available day (previously its `daysRemaining >= 1` guard would have turned the forced-tomorrow start into "expanded into nothing", which is why the old snap-back existed). The only surviving snap-to-today is a start strictly *past* the end day — a rate/quantity ending today captured after the window — where today genuinely is the commitment's last day (end dates are inclusive for those shapes).
- Not a DEBUG-before/after case in the work-order-item-5 sense (this is the sweep, not the arbiter), but the existing expansion DEBUG line prints the chosen start day, so the next 10:30pm capture will show `start=<tomorrow's stamp>` in the console.

**Item 2 — interactive message box shell, prototype (`5cdf543`)**
- `Nudge/Views/Components/TasksMessageBox.swift` — the box gains `onCharacterTap` (default nil → every existing call site unchanged); the 56×56 character slot gets its own tap, which wins over the row's tap (child gesture precedence), so the row's detail expand/collapse behaves exactly as before. New `MessageBoxChatShell`: dimmed backdrop (tap anywhere outside → collapse), card anchored near the top (so the keyboard never covers it) with a stub conversation, a fake question ("Should the first session go today or tomorrow?") with two tappable option chips, and a free-text field with send. Options and free text both append to the conversation and get a canned reply that says out loud it's a prototype: *"Noted. (Prototype — nothing is saved yet.)"*
- `Nudge/Views/Tabs/TasksTabView.swift` — `isMessageShellOpen` state + the character-tap wiring + the shell as a whole-tab overlay. Hoisted to the tab because an in-row overlay would be clipped by the scroll container and couldn't catch outside taps.
- `NudgeTheme` only (primary/surfaceAlt bubbles, radiusSheet card, radiusButton input, standard animation/haptics). No `@Model`, no persistence, no API calls, Home chat untouched.

## Verification

- Both schemes build clean (zero warnings) after each commit.
- Evidence-list items verified by construction/code-review: character tap expands, backdrop tap collapses (also drops keyboard focus first), expanded state shows stub messages + field + two options, collapsed state unchanged (the composer and its states are untouched; `onCharacterTap` is additive with a nil default).
- **Not verified here: how it feels.** That's the point of the cycle and needs your hands on a device/simulator. Two things to specifically judge: (1) the shell appears with a plain fade/scale from the top — no matchedGeometryEffect morph from the row into the card, which is where the polish budget would go if the interaction survives; (2) the floating app tab bar renders **above** the dim backdrop (the overlay lives at the tab level, the bar at the shell above it) — visible rough edge, accepted under the timebox.
- Item 1: the deadline-tomorrow-late-capture path traced end to end (decision → expansion → generation → announcement copy: `startsTomorrow` + one day yields "for tomorrow", correct). Not run on device.

## Deviations from the plan

- The timebox was not needed — no fight with animation or keyboard (the top-anchored card sidesteps keyboard avoidance entirely). The rough edges that remain (no morph, tab bar above the dim) are listed above rather than polished.
- Item 1's plan framing was "when the start day is forced, act on it rather than skipping the question" — the code was already acting on `tomorrowOnly` in the general case; the actual defect was narrower (the deadline-tomorrow snap-back). I fixed the defect rather than restructuring the ask/skip flow, and stated the rule used.

## Noticed but not done

- The stub conversation's fake question is the real start-day question from item 1's flow — deliberate, so you can judge the interaction on the exact exchange it would first carry. Wiring it for real is the separate cycle the plan names.
- The whole-tab overlay pattern would need rethinking if the shell ever opens from other tabs (it's Tasks-only now, matching the box).
- `MessageBoxChatShell` and the come-back/copy work from cycle -03 will eventually want one shared "the app speaks" voice definition; nothing done, just noting the convergence.

## Open questions

- Does the interaction survive your judgment? If yes, the next decisions are the morph animation, what seeds the conversation (the composed message vs. a real question queue), and whether answers flow through the capture pipeline or a narrower path. If no, the shell is two small commits to revert (`5cdf543` and the `onCharacterTap` seam).
