# Report — 2026-07-31-01 — Tier-capped step-aside; the Lexend family is missing

**Plan:** `archive/2026-07-31-01-plan.md`
**Status:** item 1 complete; **item 2 is a finding, no code changed** — and it's
bigger than the plan assumed
**Commits:** fifth commit on `automation-run-1`

---

## What changed

**Item 1**

- `Nudge/Services/NudgeArbiter.swift`
  - `morningPromptRanking` restructured around an explicit *incumbent* (the
    task pure stakes says to name) rather than filter-then-rank. The
    step-aside now requires both that the incumbent has held the slot
    `morningPromptMaxConsecutiveDays` mornings **and** that the best
    replacement is within one `morningStakesRank` tier.
  - `rankPool(_:fireDate:modelContext:)` — extracted from it, so the two
    pools (all-open, not-recently-named) are ranked by one implementation.
    Comparing them is what the rule's decision is made of, so they can't be
    allowed to drift.
  - `debugMorningPromptImpact` now distinguishes the three outcomes:
    `BIT`, `HELD (tier veto)` with the gap and both stakes values, and
    `HELD (nothing else open)`. They were previously indistinguishable in the
    log, which would have made a tier veto look like a broken rule.
- `Nudge/Services/NudgeConfig.swift` — the constant's doc comment now names
  both stand-down conditions.
- `ARCHITECTURE.md` — the morning-prompt paragraph.

**Item 2** — nothing. The plan said report first; the finding changes what
there is to decide.

## Verification

**Both schemes build.** `** BUILD SUCCEEDED **` for `Nudge` and
`NudgeWidgetExtension`.

### Item 1 — simulated mornings, per work-order item 5

The decision block (lines 799–835), `wasNamedOnRecentMornings`,
`morningStakesRank` and `stamp` were extracted **verbatim by line range**;
only the SwiftData fetch and `rankPool`'s duration lookup are stubbed. Six
mornings each:

```
A. high + .low — THE BUG           B. high + medium — one tier apart
  Aug 3: Study for the MCAT [high]   Aug 3: Passport renewal   [high]
  Aug 4: Study for the MCAT [high]   Aug 4: Passport renewal   [high]
  Aug 5: Study for the MCAT [high]   Aug 5: Stats problem set  [medium]
  Aug 6: Study for the MCAT [high]   Aug 6: Passport renewal   [high]
  Aug 7: Study for the MCAT [high]   Aug 7: Passport renewal   [high]
  Aug 8: Study for the MCAT [high]   Aug 8: Stats problem set  [medium]

C. high + high — same tier         D. unclassified + .low — one tier apart
  Aug 3: Passport renewal   [high]   Aug 3: Email the registrar [unclassified]
  Aug 4: Passport renewal   [high]   Aug 4: Email the registrar [unclassified]
  Aug 5: Study for the MCAT [high]   Aug 5: Clean my desk       [low]
  Aug 6: Passport renewal   [high]   Aug 6: Email the registrar [unclassified]

E. high + unclassified — 2 tiers   F. ONE open task — fallback one
  Aug 3-8: Study for the MCAT        Aug 3-8: Study for the MCAT
```

- **A is the fix.** "Clean my desk" never takes the slot from a high-stakes
  task. Before this cycle it took every third morning.
- **B, C, D confirm rotation still happens** where it should — including D,
  which is the `nil`/`.low` adjacency the plan asked me to preserve.
- **F confirms the single-task fallback still stands down** rather than going
  silent.

### The consequence worth knowing before you merge this

**E is the case that matters most for your actual data, and it means the rule
will rarely fire.** Stakes is only written by the capture and import paths, so
most existing tasks are `unclassified`. With one `high` task and everything
else `unclassified`, the gap is 2 and the veto holds — that task gets named
every morning until it's done, which is precisely the behaviour cycle
`-30-01` was sent to fix.

That is the plan's own trade, taken deliberately ("a repeat is better than a
false claim"), and I think it's the right call — naming an unclassified task
as *the biggest thing on your list* while a high-stakes one sits open is worse
than repeating. But the practical effect is that **item 1 doesn't just narrow
the rotation, it switches it off for the common data shape.** The variation the
last cycle was after arrives when stakes coverage does, not before. Two ways
out if that's not acceptable, neither of them this cycle's work: backfill
stakes on existing tasks, or let `nil` count as adjacent to `high` on the
grounds that unknown isn't a claim of unimportance.

## Deviations from the plan

**None.** The tier rule, its measurement on `morningStakesRank`, the
`nil`-above-`.low` decision, and "repeat rather than false claim" are all as
written. Item 2 was investigated and not changed, as instructed.

## Item 2 — the font finding

**It is not `Lexend-Bold.ttf`. Not one of the five Lexend files has ever been
in this repo.**

What I checked:

- `find . -iname "*.ttf" -o -iname "*.otf"` — **zero results** anywhere in the
  working tree.
- `Nudge/Info.plist` `UIAppFonts` declares five: `Lexend-Light`,
  `-Regular`, `-Medium`, `-SemiBold`, `-Bold`.
- `Nudge.xcodeproj/project.pbxproj` — **zero** references to `.ttf` or `.otf`.
  No file references, no target membership, no Copy Bundle Resources entry.
- The built `Nudge.app` — **no font files in the bundle.**
- `Nudge/NudgeTheme.swift:47` carries the comment *"Fonts (Lexend — add .ttf
  files to project and Info.plist)"*. The Info.plist half was done; the files
  half never was.

So the console line you saw is one of five, and **the app has never once
rendered in Lexend.** Every one of these falls back to the system font:

| Constant | Value | `.custom(...)` call sites |
|---|---|---|
| `fontSemiBold` | `Lexend-SemiBold` | 75 |
| `fontBody` | `Lexend-Regular` | 67 |
| `fontMedium` | `Lexend-Medium` | 39 |
| `fontBrand` | `Lexend-Bold` | 3 |
| `fontBold` | `Lexend-Bold` | 0 — unused |
| `fontLight` | `Lexend-Light` | 0 — unused |

186 call sites across 22 files, **all in the app target**. The widget target
has zero `.custom(` calls and no `UIAppFonts` key in `NudgeWidget/Info.plist`,
so it is genuinely unaffected — it has always used system fonts, and adding
files to the app target alone won't change that.

**Neither of the two fixes the plan anticipated applies.** There's no name to
correct — the names are consistent between `NudgeTheme` and `Info.plist`, and
correcting a name can't help when no file exists to point at. So:

**What I need from you:** four `.ttf` files, dropped anywhere in the repo (say
`Nudge/Resources/Fonts/`) — `Lexend-Regular.ttf`, `Lexend-Medium.ttf`,
`Lexend-SemiBold.ttf`, `Lexend-Bold.ttf`. Lexend is SIL Open Font License and
comes from Google Fonts. `Lexend-Light.ttf` is declared but has zero call
sites, so either supply it or let me drop that line from `Info.plist`.

Once they exist I add them to the `Nudge` target's Copy Bundle Resources and
confirm the `GSFont` lines are gone — that's a small, verifiable change.

**Before you do:** the app has looked the way it looks today for its whole
life. Adding the family is a **visual change to all 186 sites at once**, and
Lexend's metrics differ from the system font — expect line-height and
truncation shifts, particularly in the notification-adjacent UI and the
timeline. It is the design intent, so it's probably right, but it isn't a
silent bug fix and it shouldn't land the same day as a merge you're trying to
verify. Worth its own cycle with a screenshot pass.

The alternative, if Lexend has quietly been abandoned: delete the `UIAppFonts`
block and the six constants and replace 186 `.custom` calls with system font
styles. Bigger change, and it forecloses the design intent — I'd only do that
on your say-so.

## Noticed but not done

- **`fontBrand` and `fontBold` are the same string** (`Lexend-Bold`), and
  `fontBold` has no call sites. If the fonts land, one of the two should go.
- **`fontLight` has no call sites** either, yet `Lexend-Light.ttf` is one of
  the five declared. That's the one declaration that could be deleted with no
  effect whatsoever.
- **The tier veto makes `morningStakesRank`'s exact spacing load-bearing.** It
  used to be a sort key, where only the order mattered; it is now also a
  distance, where the gap between adjacent values matters. Anyone adding a
  stakes case has to think about both. Documented at the call site.
- **`recentActivityCooldownMinutes`' doc comment still claims the gate covers
  task completions.** Third cycle running that this is out of scope; still
  wrong.

## Open questions

- **Does the tier veto go too far for real data?** See "the consequence worth
  knowing". The honest summary: item 1 fixes a wrong notification and, on your
  current data, mostly turns item 1-of-last-cycle off. Both are defensible;
  you should pick knowingly.
- **Fonts: supply, or abandon?** And if supply — its own cycle with
  screenshots, or straight in?
- **The device pass from `2026-07-30-01` is still outstanding.** Nothing in
  this cycle changes what `DEVICE-CHECK-automation-run-1.md` asks for; §1's
  expected `[MorningPrompt]` block now has two extra `HELD` variants, which
  the checklist doesn't mention but which are self-describing in the log.
