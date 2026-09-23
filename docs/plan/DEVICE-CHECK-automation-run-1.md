# Device check — `automation-run-1` (fresh, covers the whole branch)

Replaces the four-cycle checklist. This one covers **everything on the
branch**: cycles `2026-07-29-01/-02/-03`, `2026-07-30-01`, `2026-07-31-01`
(tier veto), and the eleven-item batch `2026-07-30-02`. Nothing on the branch
has ever run against a real store; every check below is outstanding for that
one reason.

**Realistic time: about 35 minutes for the main sitting** (§0–§6, phone in
one hand, Xcode console open), **plus three consecutive mornings** for the one
check that cannot be compressed (§2's no-repeat rule), plus an optional
10-minute calendar-import setup (§6e). Not ten minutes. Plan accordingly.

Legend: **📱 = look at the phone**, **⌨️ = read the Xcode console.** Work top
to bottom — §0 and §1 are order-dependent and unrecoverable once skipped.

---

## 0 — BEFORE you install the branch build (📱, 3 min — UNRECOVERABLE)

These observations use the **currently installed (pre-branch) build**. Once
the new build launches it mutates the store, and this state is gone forever.

- [ ] 📱 **Hunt for a vanished task.** Think of any unfinished task you placed
      on the timeline on some earlier day. Check Unscheduled, Scheduled, and
      the timeline: if it appears in **none of them**, that's the
      vanishing-task bug live — **write its name down**. §1 checks that the
      new build resurrects exactly it. (Finding none is fine; the rollover
      check in §1 still runs, it just proves less.)
- [ ] 📱 **Stats tab → completed history: note any "Urgent" pill.** If one
      exists, §1's priority sweep must fold it; if none, that check reduces
      to "still none."
- [ ] 📱 **Screenshot the widget** (medium size). §6 compares the new palette
      against the app; the old screenshot is your reference for "what
      changed" if something looks off.

**Falsifier for the branch as a whole:** none here — this section only
captures baselines.

---

## 1 — First launch: capture the one-shot console blocks (⌨️, 4 min — UNRECOVERABLE)

Build and run the branch on the device. Console open, no filter. **Three
blocks on this first launch print once and never again — capture all three
(screenshot or copy) before doing anything else in the app.**

**(a) The outcome dump — BEFORE half of cycle 1's comparison:**

```
[NudgeOutcomeDump] N outcome row(s) in the last 7 days
  RESULT        FEEDBACK    KIND           SCHEDULED     TASK
  ...
  → by kind:
      eventBlock     ...
      idle           ...
      getAhead       ...
      morningPrompt  ...
      floater        —
  → feedback: none given yet
```

- [ ] ⌨️ Last line reads `→ feedback: none given yet`. If not, a pre-existing
      row carries feedback and cycle 1's "no row ever held `markedHelpful`"
      premise needs re-checking.
- [ ] ⌨️ **The by-kind list has NO `breakItDown` row — expected, not a
      fault.** The kind was removed outright in the batch (item 5); the old
      build printed it with `—`. Its absence from here on is the removal
      working.

**(b) The placement rollover — batch item 1, and this launch is the only
record of what it cleared:**

```
🧹 PlacementRollover — N stale placement(s):
   • <task> [manual, placed Jul 28, 3:00 PM] OPEN — was in no list section → Unscheduled
   • <task> [auto, placed Jul 29, 10:15 AM] complete, placement inert → Unscheduled
```

- [ ] ⌨️ If you wrote a task name down in §0, **it must appear in this list**
      with `OPEN — was in no list section`.
- [ ] 📱 Then check the Tasks tab: that task is now visible under
      **Unscheduled**. This is the headline of batch item 1 — **tasks placed
      on past days disappearing from wherever they were and reappearing in
      Unscheduled is expected new behavior, not data loss.** Manual
      placements are cleared too, deliberately (a placement is a slot on one
      specific day).
- [ ] ⌨️ No block at all is fine **only if** §0 found no vanished task and
      nothing was ever left placed on a past day.

**(c) The priority sweep — batch item 6:**

```
🧹 LegacyPriorityNormalizer: folded N "urgent" row(s) into "high".
```

- [ ] ⌨️ Prints iff §0 found "Urgent" anywhere. 📱 After launch, the Stats
      history shows **no "Urgent" pill anywhere** — those rows now read
      "High".

**Also expect the normal launch sequence** (not order-dependent, sanity only):

```
[NudgeArbiter] Reevaluate triggered: appLaunch. notificationsEnabled=true
[NudgeArbiter] Built N raw candidates (events + morning + idle + getAhead + floater).
[NudgeArbiter] N candidates passed the gates.
[NudgeArbiter] Scheduling N winner(s).
[NudgeOutcomeClassifier] Classified N delivered nudge(s).
```

Note the parenthetical: **five builders, no `breakDown`** — the old build
printed six.

**Falsifiers:** a §0-noted invisible task absent from the 🧹 list and still
invisible in every section (rollover missed it); an "Urgent" pill surviving
in Stats after launch (sweep missed `CompletedTaskRecord`).

---

## 2 — The morning prompt names a task (⌨️, 3 min now + 3 mornings)

Read the `[MorningPrompt]` block from the launch you just did. It prints
without waiting.

```
[MorningPrompt] fire=Fri Jul 31 08:30  (gating unchanged: toggle, day-fullness, fire-moment busy)
  BEFORE: "What do you want to get done today? Tell me and I'll set it up."  ← fired with nothing open too
  AFTER : "Biggest thing on your list: "<task>" — due ..."
  no-repeat rule idle: "<task>" has not yet been named 2 mornings running.
  named-task history (most recent first): ...
  ranked N contender(s) in the top stakes tier (stakes ▸ deadline proximity ▸ id):
      high          0.42  Thu Jul 31 17:00  Chem lab report
      unclassified  0.31  —                 ...
```

- [ ] ⌨️ The task in `AFTER` is the top row of the `ranked` list. (If not,
      builder and dump disagree — a bug, not a display quirk.)
- [ ] ⌨️ It's genuinely your highest-stakes open task. **Most tasks will show
      `unclassified`** — stakes is only written by capture/import; that
      ranking above `low` is deliberate.
- [ ] ⌨️ Deadline clause matches: `due today at 5:00 PM` (specific time),
      `due today` (date only), **nothing at all if already passed** — dropped
      on purpose so the first thing read in the morning can't be an
      accusation.

The `no-repeat rule …` line has four forms: `idle` (task hasn't held the slot
long enough), `BIT` (stepped aside), `HELD (tier veto)` (the only alternative
is more than one stakes tier below — **repeating on purpose; this is the rule
working, not failing**, and with mostly-`unclassified` lists it's the likely
outcome), `HELD (nothing else open)`.

**⏳ Cannot be done in one sitting: the no-repeat rule needs three
consecutive mornings.** Day 1 and 2 name the same task (`idle`), day 3 prints
either `no-repeat rule BIT: … stepped aside for "<other>"` or a `HELD` line
with its reason. A same-day check proves only the ranking, never the rule.
Shortcut for the *ranking* half today: complete the named task (or add a
higher-stakes one), foreground the app, confirm `AFTER` names the new top.

**Falsifier:** the same task named three consecutive mornings while another
open task **within one stakes tier** exists — means the history isn't being
written; check `named-task history` gains a row each day.

---

## 3 — Deliver one of each kind and long-press it (📱 + ⌨️, ~10 min)

**Action buttons render only in the expanded interface — long-press or pull
down on the banner. A glance proves nothing.**

The arbiter schedules at most one discretionary nudge per day, so don't wait:
**temporarily shift your wake time in Settings so the anchors land minutes
out** (morning prompt = wake+30m, idle = wake+3h, floater = wake+6h),
foreground the app to force a reevaluate, and read
`[NudgeArbiter] Scheduling N winner(s).` for the fire times. Restore wake
time in §7.

| # | Notification | Long-press → you should see | Proves |
|---|---|---|---|
| 1 | **Event heads-up** ("Heads up…") | **NO buttons at all** | cycle 1 |
| 2 | **Get-ahead** ("Time to get ahead") | Start session · Snooze 30 min · 👎 — **no Break it down** | cycle 1 + batch 5 |
| 3 | **Floater** ("Are you working on something?") | Start session · Snooze 30 min · 👎 | cycle 1 |
| 4 | **Idle** ("Checking in") | Yes, I'm good · Not yet · 👎 | cycle 1 |
| 5 | **Morning prompt** ("Good morning") | **👎 only** — no 👍 | cycle 1 |

- [ ] 📱 **No 👍 anywhere. No "Break it down" anywhere.**
- [ ] ⌨️ **Idle on a school day — expected new noise, not a fault (batch
      item 4).** If any calendar event falls in the 3h before idle's fire
      time (tomorrow's morning class counts, post-rollover), the old build
      silently skipped it. Now it builds, and prints the proof:

```
[NudgeArbiter] idle: BEFORE/AFTER — old event-window rule would have SUPPRESSED this candidate; new rule builds it (busy-window gate still applies at the fire moment).
```

- [ ] ⌨️ If the idle fire moment itself lands **inside** a class, it should
      still die at the busy-window gate — check it's absent from
      `Scheduling N winner(s)` on such a day, not absent from the builders.

**Falsifier — a stale action rendering.** Any banner showing a button that
should be gone probably means iOS cached the old categories: delete the app
and reinstall before calling it a code bug. (The `category.breakDown`
*category* was removed in the batch; no request has ever carried it.)

---

## 4 — Outcome rows still get written (📱 + ⌨️, 4 min)

The failure this catches: an action removal breaking the delegate path that
writes rows, silently stopping the data `ROADMAP.md` §1 waits on.

- [ ] 📱 **Tap** one notification body (not a button) — morning prompt lands
      in Home chat, everything else in the Tasks tab.
- [ ] 📱 **Swipe away** a different one.
- [ ] ⌨️ Foreground the app; in the new `[NudgeOutcomeDump]`, the tapped row
      reads `tappedStart` and the cleared one `dismissed`.
- [ ] ⌨️ Compare `→ by kind:` against your §1 capture: every kind that
      produced rows before still produces them. `floater` showing `—` is
      still its own known gap, not this branch's failure.
- [ ] ⌨️ `→ feedback: none given yet` — unless you pressed 👎 in §3, then
      exactly `markedUnhelpful=1`.

**Falsifier:** a kind with rows in §1's dump and none now.

**Note the cut point for baseline readers: rows from this install onward
(2026-07-31) cannot carry `markedHelpful`, `tappedBreakDown`, or kind
`breakItDown`, and were emitted under the reduced action sets.**

---

## 5 — A focus session no longer kills unrelated nudges (⌨️, 4 min)

1. ⌨️ Note the current `Scheduling N winner(s)` list.
2. 📱 **Start a focus session** on any task. Its reevaluate prints:

```
[ActiveSession] session running until Fri Jul 31 15:00
  BEFORE: session active → old rule BLOCKED ALL N candidate(s), event blocks included.
      PASS*  Fri Jul 31 14:00  eventBlock   Heads up
      BLOCK  Fri Jul 31 14:30  getAhead     Time to get ahead
      PASS   Sat Aug 1 14:00   floater      Are you working on something?
  AFTER : N of M candidate(s) freed. PASS* = budget-exempt, never sees this gate at all.

[ActivityCooldown] lastSessionStart=Fri Jul 31 14:00 cooldown=90m → window ends Fri Jul 31 15:30
  BEFORE: session started 0m ago → old rule BLOCKED ALL N budget-counting candidate(s), whatever their fire date.
  AFTER : K of N candidate(s) freed — they fire after the cooldown ends...
```

- [ ] ⌨️ `session running until` is in the **future** (no ⚠️ ordering
      warning).
- [ ] ⌨️ Every `eventBlock` row reads `PASS*` — **the headline**: pre-class
      reminders survive you being mid-session.
- [ ] ⌨️ Candidates firing tomorrow+ read `PASS`; ones landing inside the
      session/cooldown window read `BLOCK`.
- [ ] ⌨️ `Scheduling N winner(s)` still lists your event heads-ups (the old
      code zeroed this list).
- [ ] 📱 End the session; ⌨️ a `Reevaluate triggered: sessionEnded` follows
      and candidates return.

**Falsifier:** `AFTER : 0 of N candidate(s) freed` while a session runs and
future-day candidates exist — a gate still reading the clock, not the fire
date.

---

## 6 — Batch spot-checks (📱, ~8 min)

**(a) Widget shows today's events — item 2.**
- [ ] 📱 With a full calendar imported (more than 20 events across the
      window), today's classes appear in the widget's events row and chart.
- **Falsifier:** an event happening today missing from the widget while
  distant-future events exist in the store.

**(b) Event durations agree everywhere — item 7.**
⏳ Needs an event with a learned duration: one with no explicit
`estimatedMinutes` whose title has an `EventDurationStats` row (e.g. a lab
you've confirmed at 3 h). Skip if none exists yet.
- [ ] 📱 That event's block spans the same width-per-hour on the app timeline
      and the widget chart.
- **Falsifier:** widget draws it one hour wide while the timeline draws three
  — the truncated lookup came back.

**(c) Countdown boundary — item 8.**
- [ ] 📱 For a task due 48–72 h out: the app row says `N days away` and the
      widget's most-urgent label says `… · N days away`. **The old widget
      said "in ~60 hours" in this band** — that disagreement is what the fix
      removed.
- **Falsifier:** widget shows hours where the app shows days (or the two
  disagree anywhere in wording *band*, not phrasing — widget phrasing is
  deliberately shorter).

**(d) Row order matches — item 9.**
- [ ] 📱 The widget's first six rows are the same tasks in the same order as
      the app's list (plan tasks first, numbered order; then
      overdue → dated → floaters).
- **Falsifier:** any ordering difference between widget and app list.

**(e) Palette — item 10.**
- [ ] 📱 Widget background, text grays, and dividers read as the *same
      palette* as the app side-by-side. Goal rows and the session "All Done"
      tint are the same green. **Small shifts vs your §0 screenshot are
      expected** (the widget surface picks up the app's slight translucency;
      grays snap to theme values) — the check is app-vs-widget agreement
      *now*, not old-vs-new sameness.
- **Falsifier:** a visibly different background tint or text gray between
  app and widget on the same screen brightness.

**(f) Imported exams get the exam category — item 3.** ⏳ Needs setup: add an
event named e.g. "CHEM 101 Final Exam" to Apple Calendar inside the import
window, refresh the calendar connection, then open the imported item in the
Tasks-tab editor.
- [ ] 📱 Its category reads **exam**, not school. (Chat capture already did
      this; the import paths are what changed.)
- **Falsifier:** the fresh import lands as "school".

---

## 7 — Wrap up (2 min)

- [ ] 📱 Restore your wake time if you shifted it in §3.
- [ ] ⌨️ Save the two `[NudgeOutcomeDump]` blocks (§1 and §4) and the two 🧹
      blocks — together they're the before/after evidence five cycles of
      reports couldn't produce on this machine.
- [ ] Back at the desk, optional: open `ContentView.swift`'s `#Preview` in
      the Xcode canvas — it should render (its schema list was re-synced in
      batch item 11; previews-only, no device involved).

**Anything that fails goes back to the planner as a new cycle with the
console block pasted in — report, don't fix.** The branch is unmerged and
unpushed; nothing here is load-bearing until you say so.
