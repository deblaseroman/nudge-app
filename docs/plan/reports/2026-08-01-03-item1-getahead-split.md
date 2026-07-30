# Report — 2026-08-01-03 (item 1 of 4) — Split get-ahead into `prep` and `dueSoon`

**Plan:** `archive/2026-08-01-03-plan.md` (§1)
**Status:** complete
**Commits:** see the item-1 commit on `automation-run-1` (this report is committed with it)

---

## What changed

- `Nudge/Models/NudgeOutcome.swift` — added `.prep` and `.dueSoon` to
  `NudgeOutcomeKind`; `.getAhead` stays as a documented legacy case so
  pre-split rows keep their attribution (cut date noted in the doc
  comment: Aug 2026, this cycle). `successIsObservableInApp`: `.prep`
  true, `.dueSoon` **false** (structural fatigue exemption — success is
  handling the deadline, which may never touch the app), `.getAhead`
  unchanged. `fatigueBlindRawValues` picks `.dueSoon` up automatically
  (derived from `allCases`).
- `Nudge/Services/NudgeConfig.swift` — `getAheadAnchorHoursAfterWake`
  renamed `prepAnchorHoursAfterWake` (value unchanged, 2h); new
  `dueSoonLeadMinutes = 120` and `dueSoonBatchWindowMinutes = 60`.
- `Nudge/Services/NudgeArbiter.swift` —
  - `buildGetAheadCandidates` → `buildPrepCandidates`: emits `.prep` /
    `category.prep` / ID `nudge.arb.prep.<taskUUID>`. Behaviour otherwise
    byte-identical to the old builder: same `StartByPlanner` day math, same
    wake+2h anchor (`getAheadFireDate` → `prepFireDate`, rename only), same
    urgency floor, same copy, still discretionary (budget, quiet hours,
    spacing, fatigue-when-armed), still one per task per day at most.
  - New `buildDueSoonCandidates`: dated open tasks inside a 14-day horizon,
    fire at `sortDeadline − 120min`, batched by chained clustering when
    deadlines fall within 60min of each other (generalised the existing
    `clusterEvents` with a `gapSeconds` parameter; default keeps the event
    call site unchanged). Budget-exempt (`countsAgainstBudget: false`).
    Once-per-task via a new `dueSoonHistory` delivered-marker map in App
    Group defaults — the exact `eventReminderHistory` pattern, written in
    `schedule()`, checked in the builder, pruned in `cancelAll` (2-day
    cutoff). ASAP fallback (fire now+60s) when a task is captured inside
    its own lead window and the deadline is still >5min out, mirroring
    event blocks.
- `Nudge/Services/NudgeNotificationCategories.swift` — new `category.prep`
  (Start / Snooze / 👎, same as get-ahead) and `category.dueSoon`
  (**no actions** — event-block precedent; see Deviations). `category.getAhead`
  stays registered for delivered notifications that survive the upgrade.
- `Nudge/Models/UserProfile.swift` — new `dueSoonReminderNotificationsEnabled`
  (property-level default `true`). **Prep keeps
  `taskDueSoonNotificationsEnabled`** — that toggle always gated this code
  path, so user intent follows the behaviour, not the name; documented on the
  field. Same descendant-keeps-the-field convention as the floater split.
- `Nudge/Views/Tabs/SettingsTabView.swift` — "Task due soon" row renamed
  "Start early" with an honest subtitle; new "Due soon" row for the new
  toggle.
- `Nudge/ContentView.swift` — new toggle added to `notificationToken` so
  flipping it triggers a reevaluate.
- `Nudge/Views/Components/TodayTimelineView.swift` — `markerLabel` cases for
  `.prep` ("start early") and `.dueSoon` ("due soon").
- `Nudge/Views/Components/TasksMessageBox.swift` — tapped-nudge explanations:
  `.prep` shares `.getAhead`'s (same ask, new identity); `.dueSoon` gets its
  own factual explanation.

## Verification

- Both schemes build (`xcodebuild`, iOS Simulator destination): **Nudge** ✅,
  **NudgeWidgetExtension** ✅, run after the item's edits and before commit.
- Exhaustive-switch coverage was verified by the compiler: the two
  non-derived kind switches (`markerLabel`, `nudgeExplanation`) and
  `successIsObservableInApp` all updated; `fatigueBlindRawValues` and the
  outcome dump's by-kind tally derive from `allCases` and needed no edit.
  Tap routing string-compares `.morningPrompt` only, so both new kinds fall
  through to the Tasks tab — correct for both.
- Work-order item 5 (DEBUG before/after on real data): **not runnable
  unattended** — no device store in this environment. The structural
  argument: `prep` is the old get-ahead builder with only identity renamed
  (kind raw value, category ID, notification ID prefix); its fire dates,
  gates, scoring, and copy are unchanged, so its before/after is a no-op by
  construction. `dueSoon` is purely additive — no existing candidate's fate
  changes; it is budget-exempt so it cannot evict a discretionary winner,
  and `pickWinners`' spacing check runs against the winner set that includes
  it, exactly as for event blocks. The existing DEBUG dumps
  (`debugStakesImpact` etc. print per-kind rows; the outcome dump iterates
  `allCases`) will show both kinds on the next device run.

## Deviations from the plan

- **Due-soon carries no action buttons.** The plan specifies copy and
  exemptions but not actions. Followed the event-block precedent (factual,
  budget-exempt, states rather than asks) — also, a Start button on a
  batched "3 things due" banner is ambiguous. 👎 rides only on categories
  with actions, so due-soon has none; the per-kind toggle is the opt-out.
- **Due-soon uses `.normal` urgency tier deliberately** — no 🔴/ALL-CAPS, no
  `.timeSensitive`. The tier escalation exists for act-early nudges; the
  plan's "factual, low-pressure copy" reads as overriding it. Trivial to
  revisit if a 2h-out reminder should break through Focus modes.
- **Toggle assignment**: the plan is silent. Prep (the direct descendant)
  keeps `taskDueSoonNotificationsEnabled` despite the now-lying name;
  due-soon got the new field. Rationale on the `UserProfile` doc comment and
  above.

## Recorded decisions (per the plan's own asks)

- **Quiet hours and early-morning deadlines**: dueSoon is budget-exempt, and
  every shared gate in `passesGates` keys on `countsAgainstBudget` — so a
  4 AM deadline produces a 2 AM reminder. Accepted per the plan; recorded
  here so it's a decision, not an accident.
- **Kind-level baselines**: `.getAhead` rows end at this cycle's cut date;
  `.prep`/`.dueSoon` start fresh. The enum doc comment carries the same
  note for anyone reading dumps later.

## Noticed but not done

- The morning-prompt/floater comment blocks still say "get-ahead" in a few
  historical narratives; left where the sentence describes pre-split
  behaviour truthfully.
- If a due-soon batch's membership changes after delivery (a new task
  captured due in the same hour), the marker map keys on the first task's ID
  + due day — a later-captured earlier-due task forms a new ID and re-fires
  naming the whole batch; a later-captured later-due task inside the same
  hour stays silent (the batch's marker blocks it). Both edges accepted for
  v1; a per-task marker would fix the second at the cost of the batching
  guarantee.
- `rescheduleSnoozed` gives snoozed notifications an un-tracked ID
  (`<originalID>.snoozed` — not in `scheduledIDs`), pre-existing and shared
  by all kinds; unchanged.

## Open questions

- Should prep's copy ("Time to get ahead" / "…Start session 1 now?") be
  revised now that it is purely the start-early half? Left as-is — the plan
  scoped copy changes to due-soon.
