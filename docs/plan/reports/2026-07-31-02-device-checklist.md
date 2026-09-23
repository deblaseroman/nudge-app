# Report — 2026-07-31-02 — Fresh device checklist for the whole branch

**Plan:** `archive/2026-07-31-02-plan.md`
**Status:** complete
**Commits:** `8c69a00` (plan archived), `ae89783` (checklist), plus this report.

---

## What changed

- `docs/plan/DEVICE-CHECK-automation-run-1.md` — rewritten from scratch, not
  amended. Seven sections: §0 pre-install phone captures, §1 first-launch
  console captures (both order-dependent, marked unrecoverable), §2 morning
  prompt + no-repeat/tier-veto, §3 one-of-each-kind delivery with long-press,
  §4 outcome rows, §5 session/cooldown gates, §6 batch spot-checks (widget
  events, durations, countdown boundary, row order, palette, exam import),
  §7 wrap-up. Every check labeled 📱/⌨️; expected console output quoted from
  the current source (I re-grepped every print rather than trusting the old
  checklist — two of its quotes had drifted, see below); a falsifier per
  section; multi-sitting checks flagged explicitly.
- No source files touched. Docs-only cycle, as planned.

## Verification

- No code changed, so no builds were run for this cycle; the batch's
  twenty-two green builds stand as the branch's build state.
- Every quoted console line was checked against the current source
  (`grep print(` across the arbiter, classifier, `PlacementRollover`,
  `LegacyPriorityNormalizer`, `CalendarService`), including two claims
  inherited from the old checklist that I verified rather than copied:
  `sessionEnded` is a real `NudgeArbiterReason`, and a notification body tap
  does write `.tappedStart` (the delegate's
  `UNNotificationDefaultActionIdentifier` branch).
- Two of the old checklist's quotes were stale after the batch and are
  corrected in the new one: the raw-candidates parenthetical no longer lists
  `breakDown` (five builders now), and the by-kind dump no longer prints a
  `breakItDown` row at all — both called out as *expected*, so the reader
  doesn't misread the removal as a regression.

## The plan's specific questions

- **Does the placement rollover create a second unrecoverable case?** Yes,
  two-layered, and the checklist front-loads both: the pre-rollover state (a
  task invisible in every section) is only observable on the **old build
  before installing** — §0 has the reader hunt for and name one — and the
  first-launch `🧹 PlacementRollover` block is the only record of what was
  cleared, captured in §1 alongside the BEFORE outcome dump. The priority
  sweep (`🧹 LegacyPriorityNormalizer`) is a third one-shot print and sits in
  the same capture step.
- **Expected-noise callouts:** both in place — idle firing on school days
  (§3, with the `BEFORE/AFTER` console line quoted as the proof it's the fix
  working) and past-day placements reappearing in Unscheduled (§1, framed as
  "expected new behavior, not data loss").
- **Kept from the old checklist:** the wake-shift trick (§3, with the anchor
  offsets) and the long-press instruction (§3, verbatim spirit: "a glance
  proves nothing").
- **Realistic time:** ~35 minutes for the main sitting, stated up front, plus
  three consecutive mornings for the no-repeat rule and two optional setups
  (learned-duration event, calendar exam import) that are flagged ⏳ with
  what they need. Not rounded down.

## Deviations from the plan

- **Cycle ID.** The plan's header says `2026-07-31-01`, but that ID already
  exists in `archive/` and `reports/` (the tier-veto + fonts cycle). Archiving
  under it would have overwritten the record of what was approved — the exact
  thing the archive exists to prevent — so this cycle is filed as
  `2026-07-31-02` with the plan text captured verbatim. The planner should
  mint IDs against the archive listing, not memory.
- **Change count.** The plan says "fifteen changes across five cycles." By my
  count the branch carries **six** cycles (`2026-07-29-01/-02/-03`,
  `2026-07-30-01`, `2026-07-31-01`, and the eleven-item batch
  `2026-07-30-02`) and more like nineteen changes. The checklist covers
  everything actually on the branch, enumerated from the commit log, so
  nothing hangs on the count — but the discrepancy is worth the planner
  knowing about, since it suggests the batch was tallied as partially rather
  than fully landed.

## Noticed but not done

- **A body tap records `.tappedStart` for every kind** — the delegate's
  default-action branch reuses the same result value as the Start button, so
  "opened the notification" and "started a session from it" are
  indistinguishable in the outcome data. Pre-existing, known to the old
  checklist, and left alone (out of scope: report, don't fix) — but it slightly
  muddies the behavioural column that §1 of the roadmap will eventually read,
  and it deserves its own small cycle before the fatigue gate arms.
- The `.floater` `—` gap remains its own known issue; the checklist keeps the
  old stance (expected, not this branch's failure).
- The old checklist file's §0-§5 structure was decent; the rewrite reuses its
  best formulations rather than differing for its own sake. No bugs were
  surfaced by the writing itself beyond the two stale quotes noted above.

## Open questions

- Whether the checklist's §6b/§6f optional setups should block the merge or
  can trail it — the planner should decide what "device-verified enough to
  merge" means: §0–§5 plus §6a/c/d/e is one sitting; §2's three mornings and
  the two ⏳ setups are the tail.
- The ID collision above: does the planner want a rule change (e.g. "check
  `archive/` before minting") written into `docs/plan/README.md`? Not done
  here — that file is protocol, and protocol edits should be their own
  approved change.
