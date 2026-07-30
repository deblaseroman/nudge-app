# Report — 2026-08-01-03 (item 3 of 4) — Morning prompt says when the named task is overdue

**Plan:** `archive/2026-08-01-03-plan.md` (§3)
**Status:** complete
**Commits:** see the item-3 commit on `automation-run-1` (this report is committed with it)

---

## What changed

- `Nudge/Services/NudgeArbiter.swift` — `morningDeadlinePhrase` no longer
  returns nil for a deadline that has already passed; it returns a neutral
  past-tense marker on the same granularity ladder as the future branch:
  `was due earlier today` / `was due yesterday` / `was due Saturday`
  (2–6 days) / `was due Jul 26` (further). The future branch is untouched
  byte-for-byte. Doc comments on `morningPromptBody` and
  `morningDeadlinePhrase` updated — the "never imply failure" note now
  records why total silence was replaced (the device pass this item cites)
  and what the marker deliberately omits.
- The bare-`dueDate` granularity guard from cycle 2026-07-29-02 is
  preserved: a task due *today* with no clock time still reads "due today"
  (future branch) all day, not "was due earlier today" from 00:01 — only a
  passed `specificTime` lands in the past branch on its own day.

## Verification

- **Copy harness extended and executed, not eyeballed** — same technique as
  cycle 2026-07-29-02: `morningPromptBody` / `morningDeadlinePhrase` /
  `morningStakesRank` extracted from `NudgeArbiter.swift` by line range
  (`sed`, not retyped) into a scratch file with a three-field `NudgeTask`
  stub; fire date Mon 2026-08-03 08:30. Six original future/undated cases
  reproduce the 2026-07-29-02 output exactly; seven overdue cases cover the
  new branch:

  ```
  due later today, clock time       … "Chem lab report" — due today at 5:00 PM.
  due today, NO clock time          … "Pay tuition deposit" — due today.
  due tomorrow, clock time          … "Stats problem set" — due tomorrow at 9:00 AM.
  due 3 days out, no clock          … "Read chapter 7" — due Thursday.
  due 7 days out (falls to date)    … "Passport renewal" — due Aug 10.
  undated                           … "Study for the MCAT".
  OVERDUE: earlier today (clock)    … "Move the car" — was due earlier today.
  OVERDUE: yesterday, clock         … "Psych reading" — was due yesterday.
  OVERDUE: yesterday, no clock      … "Return library books" — was due yesterday.
  OVERDUE: 2 days ago (weekday)     … "Renew parking permit" — was due Saturday.
  OVERDUE: 5 days ago (weekday)     … "Lab safety quiz" — was due Wednesday.
  OVERDUE: 8 days ago (date)        … "Scholarship form" — was due Jul 26.
  OVERDUE: 30 days ago (date)       … "Email advisor" — was due Jul 4.
  ```

  The device-pass case the plan cites ("Psych reading", due the previous
  day, no clause at all) now renders the marker.
- Both schemes build (`xcodebuild`, iOS Simulator): **Nudge** ✅,
  **NudgeWidgetExtension** ✅.
- Work-order item 5: copy-only change — no candidate, gate, fire time, or
  selection is touched, so there is no arbiter before/after to run; the
  harness above is the copy's before/after.

## Deviations from the plan

- **No clock time on past-tense markers.** "was due yesterday at 5:00 PM"
  is precision in service of nothing on a line already walking the
  accusation edge; the plan's own examples ("— was due yesterday" /
  "— was due Tue") carry none. Future phrases keep their clock rule.
- **Full weekday names** ("was due Tuesday", not "Tue"), matching the
  future branch's existing style; the plan's "Tue" read as illustrative.
- **Added a "was due earlier today" rung** for a passed `specificTime` on
  the fire day itself — the plan named yesterday/weekday only, but a 7 AM
  deadline read at 8:30 has to say something, and "was due yesterday"
  would be false.

## Noticed but not done

- The message box's overdue state (`TasksMessageBox`) phrases lateness via
  `CountdownState.remainingLine` ("was due N hours ago" style) — a second
  phrasing family for the same fact. Consistent, both factual; unifying
  them is a copy-polish item for some later cycle, not this one.
- `morningPromptRanking` can still *select* a long-overdue task every
  morning (stakes doesn't decay); the no-repeat rule caps it at 2 mornings.
  With the marker the repeat now at least says why it keeps coming up.

## Open questions

- None.
