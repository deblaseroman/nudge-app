# Report — 2026-07-29-01 — Notification cleanup (three removals)

**Plan:** `archive/2026-07-29-01-plan.md`
**Status:** complete (code); **verification partial** — see Verification
**Commits:** see `git log automation-run-1` — first commit on the branch

---

## What changed

- `Nudge/Services/NudgeNotificationCategories.swift` — the only definition site
  for categories and actions, so all three removals land here.
  - `.eventBlock` now carries `actions: []`. It keeps `.customDismissAction`,
    so tap-to-open and swipe-to-dismiss (both category-level, not actions) are
    untouched and `.dismissed` outcome rows still get written.
  - `NudgeNotificationActionID.markHelpful` and its `UNNotificationAction`
    deleted; removed from `.eventBlock` (moot — it has no actions now) and
    `.morningPrompt`, which is left with 👎 alone.
  - `NudgeNotificationActionID.breakItDown` and its `UNNotificationAction`
    deleted; removed from `.getAhead` (now Start / Snooze / 👎) and
    `.breakDown` (now Snooze / 👎).
  - Comment block rewritten — the old one explained *where 👍 goes and why*,
    which is now a lie in every direction.
- `Nudge/Services/NudgeNotificationService.swift` — deleted the two delegate
  branches whose action IDs no longer exist (`markHelpful` → `recordFeedback`,
  `breakItDown` → `.tappedBreakDown` + tab route). Nothing else in the delegate
  moved; the dismiss, default-action, start, snooze and idle yes/no branches
  are byte-identical.
- `Nudge/Models/NudgeOutcome.swift` — `NudgeOutcomeResult.markedHelpful`
  deleted, `isExplicitFeedback` reduced to `self == .markedUnhelpful`. Comment
  rationale for the two-column design rewritten around the pair that's still
  reachable (`.acted` + `markedUnhelpful` — did the thing, still didn't want to
  be asked); the old text was built on `.ignored` + `markedHelpful`, which can
  no longer occur. `tappedBreakDown` kept and annotated as having **no writer**
  (see Deviations).
- `Nudge/Services/NudgeOutcomeClassifier.swift` — `feedbackLabel` loses its
  `.markedHelpful` case; header and dump comments updated to say the feedback
  channel is now negative-only.
- `ARCHITECTURE.md` — four places: the data-flow "Feedback loop" step, the
  "Two columns, two signals" invariant, the `NudgeNotificationCategories` file
  entry, and the `NudgeOutcome` file entry. No file's *responsibility* shifted;
  the descriptions had specifics in them that stopped being true.

Nothing in `NudgeArbiter` changed. No builder, gate, score, or fire time was
touched.

## Verification

**Both schemes build.** `xcodebuild … -scheme Nudge` and `… -scheme
NudgeWidgetExtension`, both `generic/platform=iOS Simulator`, both
`** BUILD SUCCEEDED **`. The widget was unaffected as the plan predicted —
categories are app-side and the widget target doesn't reference them.

**Work-order item 5 does not apply here, and the plan is right about why.**
The arbiter's builders, gates, `pickWinners`, and every fire time are
untouched; a before/after candidate dump would print two identical columns.
What changed is payload actions and two delegate branches. Recording this
explicitly rather than skipping it, per the plan.

**The on-device evidence the plan asked for was NOT produced.** Being precise
about which parts and why, because the plan named these as the only real
proof:

- *Deliver one of each kind and look at it* — not done. Requires the app
  running on a device with a real profile, real tasks and real events, and a
  long-press on each delivered banner (iOS renders action buttons only in the
  expanded interface). There's no way to drive that from this environment:
  `simctl` can push a payload but cannot long-press the banner it renders.
- *Tap and dismiss one of each kind, confirm `NudgeOutcome` still records
  `result`* — not done, same reason.
- *A by-kind outcome dump before and after* — **not possible here at all.** I
  went looking for real data to run it against. The only `Nudge.store` outside
  the phone is on simulator `iPhone 17` (`6F836B66`), and it is useless for
  this: 0 `ZNUDGETASK` rows, 0 `ZNUDGEOUTCOME` rows, and a schema that predates
  both `ZSTAKESRAW` and `ZFEEDBACKRAW` (last written 23–24 Jul). Seeding a
  fresh simulator would produce a dump of my own fixtures, which is not the
  question the plan is asking.

What it would take: install this branch on the device that holds the real
store, let one of each kind fire, long-press each banner, and run the existing
`debugDumpRecentOutcomes` on foreground before and after. That is a
~10-minute manual pass and it is the only thing that closes this out.

**What I verified statically instead**, against the three falsifiers the plan
named:

- *"an outcome row that still records `markedHelpful`"* — the case is gone from
  the enum, so this is now a compile error rather than a runtime possibility.
  `grep -rn "markedHelpful\|markHelpful" --include="*.swift"` returns three
  hits, all of them prose comments explaining the removal.
- *"a notification rendering a stale action because a category identifier was
  updated in one place and not the other"* — there is no other place. Category
  and action identifiers are declared once each in
  `NudgeNotificationCategories.swift`, and every consumer (the arbiter's
  `categoryID`, the delegate's `switch`) reads the enum rather than a literal.
  **No identifier string changed in this cycle** — only the action *lists* —
  so a stale registration from a prior install cannot mismatch: the same
  category IDs are re-registered with fewer actions at every launch.
- *"a kind that stops producing outcome rows entirely"* — outcome rows are
  written by `NudgeArbiter.schedule`, which is untouched, and resolved by the
  delegate's dismiss/default-action branches or the classifier sweep, also
  untouched. The two deleted branches were the *only* code paths removed, and
  neither was a row-writing path for any surviving action: `markHelpful` wrote
  the `feedback` column only, and `breakItDown` was unreachable in production
  anyway (its kind can't fire while `fatigueGateEnabled` is off).

**Data cut point: 2026-07-30.** Rows scheduled before this date could in
principle carry `markedHelpful` (in practice none do — every dump to date ends
`feedback: none given yet`) and were emitted under categories that offered 👍,
Break it down, and Start session on event reminders. Rows after it cannot.
Whoever reads the `ROADMAP.md` §1 baseline needs this date; the floater
baseline hadn't started accumulating yet, so the cut lands before it rather
than through it, which is what the plan was aiming for.

## Deviations from the plan

Two, both small, both flagged rather than assumed:

1. **`NudgeOutcomeResult.tappedBreakDown` was kept.** The plan says delete the
   *action*, and explicitly keeps the break-it-down kind and builder. Deleting
   the result case would have gone further than that. It now has **no writer**
   — the only branch that wrote it is gone — so it is dead in the same way the
   kind is paused, and it should leave with the kind (`ROADMAP.md` §2, "remove
   the break-it-down kind entirely") rather than before it. Annotated in place
   so it isn't mistaken for a live value, and recorded in `ARCHITECTURE.md`.
   Contrast with `markedHelpful`, which the plan told me to delete outright and
   I did.
2. **`.eventBlock` lost `startSession` too, which the plan didn't call out by
   name.** It says "remove all action buttons", and Start session was one of
   them, so this is compliance rather than scope creep — but it's the removal
   with actual behavioural reach (the other two removed dead or paused
   channels), so it shouldn't pass silently. Consequence: you can no longer
   start a focus session from a pre-class heads-up without opening the app.
   That reads correct to me for the same reason the plan gives — the "task"
   attached to an event reminder is a calendar event the user is about to
   physically attend, not something to sit down and work on — but it is the one
   thing here a user could notice as missing.

**On the item-4 reading the plan asked me to confirm:** yes, removing the
action is a step toward removing break-it-down, not building on it. The kind,
the builder, and `deadlinePrepNotificationsEnabled` are all untouched, and the
builder still returns `[]` on the `fatigueGateEnabled` guard before anything
else runs.

## Noticed but not done

- **`.getAhead` and `.floater` now have identical action lists** (Start /
  Snooze / 👎) and differ only in category identity. That's still worth having
  — the identity is what makes their outcome rows attributable, which is the
  whole reason `.floater` was split out — but the comment justifying `floater`
  as "the same set minus Break it down" no longer distinguishes anything. I
  rewrote the comment; I did not merge the categories, and merging them would
  undo the split.
- **`NudgeNotificationService.rescheduleSnoozed` clones the delivered content
  including its `categoryIdentifier`.** Harmless today. Worth knowing that a
  snoozed re-fire re-renders whatever actions the category carries *at the
  moment it re-fires*, not the ones the original banner showed — so this
  cleanup applies retroactively to anything mid-snooze across an app update.
  No action needed; noting it because it's the one place a "stale action" could
  ever have appeared.
- **`SettingsTabView` still shows a "Break it down" toggle row** bound to
  `deadlinePrepNotificationsEnabled`. Left alone — explicitly out of scope, and
  it retires with the kind.
- **The `#Preview` container in `ContentView.swift` is still missing four
  models.** Untouched; it's `ROADMAP.md` §5 and nothing in this cycle went near
  it.

## Open questions

- **Who runs the on-device pass, and does the branch wait for it?** The three
  removals are inert by construction, so I don't think this blocks cycles 2 and
  3 — but the plan named banner inspection as "the only real proof", and it is
  outstanding. Cycles 2 and 3 proceeded on that reading.
- **Does the `.eventBlock` Start-session removal need a user-visible note?** It
  is the only one of the three a user could notice. My read is no — an assistant
  quietly offering less is not a change that needs announcing — but that's a
  `DESIGN.md` judgment call and it was made by me rather than by the plan.
