# Device check — `automation-run-1`

One pass, ~10 minutes, closing out four cycles: `2026-07-29-01` through `-03`
and `2026-07-30-01`. Nothing on this branch has ever run against a real store —
there is no `Nudge.store` outside the phone (the one simulator copy has zero
tasks and a schema predating `stakesRaw`), so every item below is outstanding
for that single reason.

Work top to bottom; §0 and §1 set up everything the rest reads.

---

## 0 — Setup (2 min)

1. Build and run `automation-run-1` on the device that holds your real data.
   Keep Xcode's console open and filtered to nothing (the dumps are prefixed,
   you'll want to scroll).
2. **Before doing anything else, screenshot or copy the console block starting
   `[NudgeOutcomeDump]`.** This is the BEFORE half of cycle 1's by-kind
   comparison, and it's the only chance to capture it — the app writes new rows
   from this launch onwards.
3. Confirm the last line of that block reads `→ feedback: none given yet`. If
   it doesn't, a pre-existing row carries feedback and cycle 1's "no row ever
   held `markedHelpful`" premise needs re-checking.

**What you should see on launch**, in roughly this order:

```
[NudgeArbiter] Reevaluate triggered: appLaunch. notificationsEnabled=true
[NudgeArbiter] Built N raw candidates (...)
[NudgeArbiter] N candidates passed the gates.
[MorningPrompt] fire=...
[ActivityCooldown] ...
[ActiveSession] no session running — gate inert this run...
[NudgeOutcomeClassifier] Classified N delivered nudge(s).
[NudgeOutcomeDump] N outcome row(s) in the last 7 days
```

---

## 1 — The morning prompt names a task (cycle `-02`, `-03` item 1)

Read the `[MorningPrompt]` block. It prints without any waiting.

**Expect:**

```
[MorningPrompt] fire=Tue Aug 4 08:30  (gating unchanged: toggle, day-fullness, fire-moment busy)
  BEFORE: "What do you want to get done today? Tell me and I'll set it up."  ← fired with nothing open too
  AFTER : "Biggest thing on your list: "<some task>" — due ..."
  no-repeat rule idle: "<task>" has not yet been named 2 mornings running.
  named-task history (most recent first): ...
  ranked N contender(s) in the top stakes tier (stakes ▸ deadline proximity ▸ id):
      high          0.42  Thu Jul 31 17:00  Chem lab report
      ...
```

**Check, in order:**

- [ ] The task in `AFTER` is the top row of the `ranked` list. (If not, the
      builder and the dump disagree — that's a bug, not a display quirk.)
- [ ] That task is genuinely your highest-stakes open one. **Most of your tasks
      probably show `unclassified`** — stakes is only written by the capture and
      import paths, so anything older predates it. `unclassified` ranking above
      `low` is deliberate; see the report for `-02`.
- [ ] The deadline clause matches the task: `due today at 5:00 PM` for a task
      with a specific time, `due today` for a date-only one, **and nothing at
      all if the deadline has already passed** — the clause is dropped on
      purpose so the first thing you read in the morning can't be an
      accusation.
- [ ] `named-task history` is empty or short on this first run. It fills in one
      entry per day from here.

**The no-repeat rule needs three consecutive mornings to observe naturally.**
If you want it now: note the named task, then force it — mark that task
complete (or add a second, higher-stakes one), foreground the app, and confirm
`AFTER` names something different. To see the rule *itself* bite rather than
the ranking changing, you need two days of history; the line to watch for on
day 3 is `no-repeat rule BIT: "<task>" has been named 2 morning(s) running →
stepped aside for "<other>"`.

**Falsifier:** the same task named on three consecutive mornings while another
open task exists. That means the history isn't being written — check that
`named-task history` gains a row each day.

---

## 2 — Deliver one of each kind and look at it (cycle `-01`, the only real proof)

This is the item all three earlier reports flagged as outstanding. **Action
buttons are only visible in the expanded interface — long-press or pull down on
the banner. A plain glance proves nothing.**

Fastest way to get one of each: the arbiter schedules at most one discretionary
nudge per day, so rather than waiting, temporarily shift your wake time in
Settings so the anchors land a few minutes out (morning prompt = wake+30m, idle
= wake+3h, floater = wake+6h), foreground the app to force a reevaluate, and
read `[NudgeArbiter] Scheduling N winner(s)` for the fire times. Put the wake
time back afterwards.

| # | Notification | Long-press. You should see | The change being proven |
|---|---|---|---|
| 1 | **Event heads-up** ("Heads up — Class in 1 hour") | **NO buttons at all.** Not Start session, not 👍, not 👎 | Cycle 1, item 1 |
| 2 | **Get-ahead** ("Time to get ahead") | Start session · Snooze 30 min · 👎 Not useful — **no Break it down** | Cycle 1, items 2+3 |
| 3 | **Floater** ("Are you working on something?") | Start session · Snooze 30 min · 👎 Not useful | Cycle 1, item 2 |
| 4 | **Idle** ("Checking in") | Yes, I'm good · Not yet · 👎 Not useful | Cycle 1, item 2 |
| 5 | **Morning prompt** ("Good morning") | **👎 Not useful only** — no 👍 | Cycle 1, item 2 |

- [ ] **No 👍 "This helped" anywhere.** This is the one to sweep for across all
      five.
- [ ] **No "Break it down" anywhere.**
- [ ] The event heads-up shows a completely empty action area.

**Falsifier — a stale action rendering.** If any banner shows a button that
should be gone, iOS is holding a cached category from the previous install.
Delete the app and reinstall before concluding it's a code bug; the category
identifiers themselves did not change in cycle 1, only their action lists.

---

## 3 — Outcome rows still get written (cycle `-01`)

The failure mode this catches: removing an action broke the delegate path that
writes the row, silently stopping the data collection `ROADMAP.md` §1 is
waiting on.

- [ ] **Tap** one notification body (not a button). Confirm it deep-links —
      morning prompt → Home chat, everything else → Tasks tab.
- [ ] **Swipe away / clear** a different one.
- [ ] Foreground the app and read the new `[NudgeOutcomeDump]`.

**Expect** the tapped row to read `tappedStart` and the dismissed one
`dismissed`. Compare the `→ by kind:` block against the copy you took in §0:

- [ ] Every kind that produced rows before still produces them.
- [ ] `→ feedback: none given yet` — **unless** you pressed 👎 during §2, in
      which case exactly `markedUnhelpful=1` and never `markedHelpful`.
- [ ] `.floater` may still show `—`. That's expected and is its own known gap;
      it is not evidence of anything broken here.

**Falsifier:** a kind that produced rows in the §0 dump and produces none now.

**Note the date.** Rows from this install onward cannot carry `markedHelpful`
and were emitted under the reduced action sets. The cut point is
**2026-07-30**; anyone reading the §1 baseline later needs it.

---

## 4 — Focus session no longer kills unrelated nudges (cycles `-03`, `-30-01` item 2)

The motivating case: a focus session at 14:00 used to swallow the 15:00 class
heads-up, plus every candidate scheduled for the rest of the week.

1. Note what's currently scheduled: `[NudgeArbiter] Scheduling N winner(s)` and
   the bulleted list under it.
2. **Start a focus session** on any task.
3. The session start triggers its own reevaluate. Read the two new blocks:

```
[ActiveSession] session running until Mon Aug 3 15:00
  BEFORE: session active → old rule BLOCKED ALL N candidate(s), event blocks included.
      PASS*  Mon Aug 3 14:00  eventBlock     Heads up
      BLOCK  Mon Aug 3 14:30  getAhead       Time to get ahead
      PASS   Tue Aug 4 14:00  floater        Are you working on something?
  AFTER : N of M candidate(s) freed. PASS* = budget-exempt, never sees this gate at all.

[ActivityCooldown] lastSessionStart=Mon Aug 3 14:00 cooldown=90m → window ends Mon Aug 3 15:30
  BEFORE: session started 0m ago → old rule BLOCKED ALL N budget-counting candidate(s), whatever their fire date.
      ...
  AFTER : K of N candidate(s) freed — they fire after the cooldown ends...
```

**Check:**

- [ ] `session running until` is a time **in the future**, roughly now + the
      task's estimated duration (or +60m). If it says `.distantPast` or prints
      the ⚠️ ordering warning, the `SessionCoordinator` fix in `-30-01` didn't
      take.
- [ ] Every `eventBlock` row reads `PASS*`. **This is the headline** — factual
      pre-class reminders are no longer suppressed by you being mid-session.
- [ ] Candidates firing **tomorrow or later** read `PASS` in both blocks.
- [ ] Candidates firing **inside the session / cooldown window** read `BLOCK`.
- [ ] `Scheduling N winner(s)` after starting the session still lists your
      event heads-ups. Under the old code this list went to zero.

**Falsifier:** `AFTER : 0 of N candidate(s) freed` while a session is running
and candidates exist for future days. That means the gate is still reading the
clock rather than the fire date.

---

## 5 — Wrap up

- [ ] Cancel the focus session. Confirm a `[NudgeArbiter] Reevaluate triggered:
      sessionEnded` follows and candidates come back.
- [ ] Restore your wake time if you changed it in §2.
- [ ] Save the two `[NudgeOutcomeDump]` blocks (§0 and §3) — they're the
      before/after that cycle `-01`'s report couldn't produce.

**Anything that fails goes back to the planner as a new cycle**, with the
console block pasted in. The branch is unmerged and unpushed; nothing here is
load-bearing until you say so.
