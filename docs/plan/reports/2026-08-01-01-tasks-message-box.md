# Report — 2026-08-01-01 — Tasks tab: message box and layout reorder

**Plan:** `archive/2026-08-01-01-plan.md`
**Status:** complete
**Commits:** `9af3f6e` (plan archived), `6a72be5` (the change), plus this report.

---

## What changed

- `Nudge/Views/Components/TasksMessageBox.swift` — **new.** The view
  (`TasksMessageBox`), the pure composer (`TasksMessageComposer`), and the
  tapped-nudge context reader (`TappedNudgeContext`). No input of any kind;
  no `ClaudeService`; `NudgeTheme` only. Styled as a leading accent bar +
  plain text — deliberately not a card, not a row. Collapsed shows the
  headline at two lines; tapping expands the detail (chevron shown only when
  detail exists, so the box never invites a dead tap).
- `Nudge/Views/Tabs/TasksTabView.swift` — layout reorder: header (description
  line deleted) → message box → plan controls + timeline → **Start Session**
  → Completed → sections. Reads the tapped-nudge context on appear/active,
  next to the existing `consumePendingIdleTask()` call.
- `Nudge/Views/Components/ScreenHeader.swift` — `subtitle` becomes
  `String? = nil`; other tabs pass theirs unchanged.
- `Nudge/Services/NudgeNotificationService.swift` — the body-tap branch now
  writes `tappedNudgeKindKey` / `tappedNudgeTaskIDKey` / `tappedNudgeDateKey`
  to the app group when routing to Tasks, before the tab-open post.
- `Nudge/Services/NudgeConfig.swift` — `messageBoxTapContextMinutes` (30) and
  `messageBoxHighStakesHorizonDays` (7).
- `ARCHITECTURE.md` — new component entry, Tasks-tab layout note, delegate
  keys note.

## The four states (as built — no device here, so descriptions, not screenshots)

1. **Nudge just tapped** (fresh within 30 min): per-kind explanation.
   Get-ahead with a resolvable task: headline `That nudge was about
   “Essay draft.”`, detail `It fires when starting now still leaves room
   before the deadline — “Essay draft” is due Aug 3rd, 5pm.` Idle: `That
   check-in asks whether today has gotten started.` Event block: `That was a
   heads-up before your next block of events.` Floater names the undated
   task. Morning prompt is handled too (it routes to Home today, but the box
   won't go speechless if routing ever changes).
2. **Overdue:** headline `“Essay draft” was due 3 hours ago.` — the "how
   long" comes from `CountdownState.remainingLine`, the same phrasing the
   task rows already use. Detail lists up to three more:
   `Also past due: “Form” (2 days ago), … and 1 more.`
3. **High-stakes approaching** (≤ 7 days, `stakes == .high`): headline
   `“Chem final” is 5 days away.`, detail `It's marked high stakes — due
   Aug 6th, 9am.`
4. **Resting — never blank by construction:** the fallthrough returns
   unconditionally. With open tasks: `3 tasks open. Next up: “Read ch. 4.”`
   (next = the shared plan-first comparator, so it matches every other
   "what should I start?" surface), detail `Due today: 2. 3 events on the
   calendar.` or `Nothing due today.` With nothing open: `Your list is
   clear right now.`, detail naming today's event count when there is one.

Tone check against `DESIGN.md`: every headline is a stated fact — no verdict
("falling behind" appears nowhere), no promised outcome, and the overdue
phrasing matches the calm "was due N ago" convention the list already ships.

## Verification

- Both schemes build.
- **Resting state never blank:** `compose` ends in an unconditional return;
  there is no path that yields an empty message.
- **Start Session from its new position:** the view moved as a unit —
  `startSessionButton` is the same view with the same `startSession` action,
  `showSessionTaskPicker` binding, active-session banner, and cancel alert;
  only its position in the `VStack` changed. Nothing in the session flow
  references layout order.
- **Tap-lands-here-and-box-explains:** verified by construction against the
  proven idle pattern — the delegate writes the keys *synchronously in
  `handleResponse`, before* the deferred tab-open post, so on both warm and
  cold launch the keys exist before `TasksTabView.onAppear` reads them. The
  same ordering argument that makes `pendingIdleTaskIDKey` work (that one is
  device-verified behavior in production… pending the same device pass as
  everything else on this branch).
- **Work-order item 5, stated explicitly rather than skipped:** this is a
  layout and presentation change, not an arbiter change. No builder, gate,
  scheduling, or outcome-writing code was touched; the one non-view change is
  the delegate writing three defaults keys that nothing in the arbiter reads.
  A before/after candidate dump would print two identical columns.
- Outstanding for the device pass: the four states rendered on a real store,
  and the cold-launch tap → box path. Both are one-glance checks.

## The plan's open question, answered

**Does the `pendingIdleTaskIDKey` mechanism generalise to other kinds?**
Yes, cleanly — the write-durable-to-app-group / read-on-appear-or-active
shape carries over with no changes, and one mechanism now serves both. The
one genuine difference is **consumption semantics**: the idle intent drives a
modal sheet and must fire exactly once (consume-on-read), while the message
context is passive display and should survive the tab re-appearing within
its window (expire-by-age instead). That difference is why the box has its
own three keys rather than piggybacking on the idle pair — folding both into
one set would force one consumption rule onto two behaviors.

**Persistence decision:** no `@Model`. The message is derived at render time
from data the app already holds; the only cross-launch state is the
tapped-nudge marker, and that is three app-group keys — same store, same
lifetime rules as the idle intent it mirrors. The schema lists are untouched.

## Deviations from the plan

- **The Completed button moved down with Start Session.** The plan named only
  Start Session; Completed was visually paired with it above the timeline,
  and leaving it stranded between the message box and the plan controls read
  as clutter above the fold. "Everything else unchanged" was read as
  *relative* order, which is preserved (Start Session → Completed →
  sections). Trivial to split back out if the pairing was wrong.
- **Body taps only.** The context is written for `UNNotificationDefault-
  ActionIdentifier` taps routed to Tasks — not for action buttons. Start
  begins a session immediately (self-explanatory), idle "Not yet" presents
  its own sheet, and 👎 never opens the app; writing context for those would
  have the box narrating over flows that already speak.

## Noticed but not done

- **The device checklist doesn't cover this cycle.** `DEVICE-CHECK-
  automation-run-1.md` was written one cycle ago and now trails the branch by
  one change — the thing its own preamble warns about. A §6 addition (four
  states + tap-landing) is small; left alone because checklist edits weren't
  in this cycle's scope.
- **`TasksMessage.detail` for the resting state always exists**, so the
  resting box always shows a chevron. Harmless, but if the detail lines feel
  noisy on device, making resting-detail conditional is a one-line change.
- The refine-rationale banner (`refineRationale`) still renders between the
  plan controls and the timeline — two "the app speaks" surfaces now exist on
  one tab. Folding the rationale into the message box as a fifth state is a
  natural follow-up, but it changes when the rationale is visible (freshness,
  priority vs overdue) — a product call, left for the planner.

## Open questions

- Should the AI Refine rationale become a message-box state (and that banner
  retire), unifying the tab's voice into one surface? It touches the Pro
  upsell surface, so it's a product decision, not a refactor.
- The plan calls this "first version, will be extended." When the
  conversational half arrives, `TasksMessageComposer` is the seam: it stays
  the deterministic fallback, and extracted-capture output would slot in as
  a new top-priority state — flagging so v2 extends rather than replaces.
