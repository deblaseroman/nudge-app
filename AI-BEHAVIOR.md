# How Each AI Should Act — Roman's behavior spec

This file is YOURS to edit (like DESIGN.md). Each card below is one AI
surface in the app. The **Today** lines are facts about current behavior.
The **How it should act** lines are yours — replace every [BRACKET] with
your own words: its voice, what it may read, what it must never do, when
it stays silent. When you're done, tell Claude Code to read this file —
it becomes the routing and wiring plan.

## Shared principles (edit these too)

- One brain: every surface reads the same data and speaks in one voice.
- Never shame the user; facts, not verdicts.
- [ADD A PRINCIPLE]

---

## 1 · Brain-dump capture — Opus 5 (low) · ~6¢ · 3–7s

**Today:** turns a dump into tasks/events/commitments/goal links; the
160-rule prompt handles due-vs-start, spans, plans, floaters; the only AI
allowed to WRITE tasks.

**How it should act:**
- [HOW SHOULD IT SOUND WHEN IT REPLIES?]
- [WHAT SHOULD IT ASK ABOUT vs JUST SAVE?]
- [WHAT SHOULD IT REMEMBER ABOUT HOW YOU PHRASE THINGS?]

**Model:** Opus 5 low today — should be: [KEEP / SONNET / OTHER]

## 2 · Small-talk lane — Haiku · ~0.05¢ · <1s

**Today:** answers provably work-free chat with one warm line; cannot see
your tasks; writes nothing; redirects real work to a fresh message.

**How it should act:**
- [WHAT PERSONALITY? PLAYFUL / CALM / MATCHING THE USER?]
- [SHOULD IT EVER SEE YOUR DATA?]
- [WHEN SHOULD IT HAND OFF TO ANOTHER LANE?]

**Model:** Haiku today — should be: [KEEP / OTHER]

## 3 · Tasks-tab memo box — Opus 5 (low) · ~1–2¢ · up to 4×/day

**Today (built Sep 16 2026):** the box's standing message is an Opus memo
written from your open tasks, today/tomorrow events, goals, and 7-day
completion habits: what you missed, what's coming, what to prepare for,
a neglected goal. Regenerates when those facts change (a dump lands, a
task tips overdue), capped at 4 a day. Talk only: no reply options, no
text field, no corner bubble; tapping the row opens the message in full.
One-time news (study-time notes, planner outcomes) still shows first.
Offline or no key: the deterministic message, exactly as before.

**Plans (built Sep 16 2026, your "go"):** for a task or event with a due
date that is worth preparing for, Opus reads it and proposes 2 to 8 short
dated sessions. The box shows Opus's one sentence with **Yes** and **No**.
Yes adds the sessions to the list and timeline as scheduled work before
the due date, never as due-dated tasks of their own. No changes nothing
and is final for that due date. A dumped exam gets one question in the
chat instead ("Want me to build a study plan for X?"); a Yes there writes
the plan at once. Your own study task always wins. At most two reader
calls a day, about 3¢ each, most days zero.

**How it should act** (started from your Sep 14 answers):
- Talk only, for now — a more detailed reminder about important tasks
  and events. *(your Q1)*
- Reads and interprets data; never writes. *(your Q2)*
- One brain: takes no capture input; reads what you planned; maybe
  tracks key words you used when describing tasks during brain dumps.
  *(your Q4)*
- [WHAT SHOULD IT SAY FIRST WHEN IT OPENS?]
- [WHAT QUESTIONS SHOULD IT BE GOOD AT ANSWERING?]
- [WHEN SHOULD IT STAY QUIET?]

**Model:** Opus 5 at effort low (your call, Sep 16 2026: "the text box
for opus"). Sonnet 5 is the cost lever if the memo ever needs one.

## 4 · Advice questions — UNROUTED TODAY (leaks to Opus at ~6¢)

**Today:** "do you think I should study first, or go to the gym?"
contains task words, so the router sends it to expensive capture. No
lane exists for opinions about your work.

**How it should act:**
- [SHOULD NUDGE GIVE ADVICE AT ALL?]
- [IF YES: WHAT MAY IT WEIGH? STAKES? DEADLINES? ENERGY? HABITS?]
- [WHICH LANE / MODEL SHOULD CATCH THESE?]

**Model:** [ ]

## 5 · Day-plan refine — Haiku · <1¢ · once/day

**Today:** AI pass over the deterministic day plan; writes placements
only; runs from Home chat's plan intent.

**How it should act:**
- [WHAT MAY IT MOVE? WHAT IS UNTOUCHABLE?]
- [HOW SHOULD IT EXPLAIN ITS CHANGES?]

**Model:** Haiku today — should be: [KEEP / OTHER]

## 6 · Notification copy — Haiku · <1¢ · batched, cached 3 days

**Today:** writes nudge bodies ahead of time; the arbiter swaps text at
scheduling; never writes event or due-soon bodies (exact clock times).

**How it should act:**
- [WHAT TONE FOR EACH NUDGE KIND?]
- [WORDS IT MUST NEVER USE?]

**Model:** Haiku today — should be: [KEEP / OTHER]

## 7 · Background enrichment — Haiku · <0.5¢ · cached 7 days

**Today:** per-task signals (urgency phrasing, suggested first step);
stakes classification on old rows; all cached, read synchronously by
scoring.

**How it should act:**
- [WHAT ELSE SHOULD IT LEARN ABOUT A TASK?]
- [YOUR Q4 IDEA: TRACK KEY WORDS FROM DUMPS — WHICH WORDS MATTER?]

**Model:** Haiku — [KEEP]

## 8 · Screenshot import — Haiku · <1¢ per screenshot

**Today:** OCR text from a schedule image → events; the only import that
needs AI (photos have no structure).

**How it should act:**
- [WHAT SHOULD IT DO WHEN UNSURE ABOUT A SHIFT?]

**Model:** Haiku — [KEEP]

## 9 · Goal-lapse hook — Haiku · <0.5¢ · after bait tap, cached/day

**Today:** writes the one AI message in the Tasks message box after you
tap the goal-lapse nudge; deterministic fallback offline.

**How it should act:**
- [HOW PERSONAL SHOULD IT GET ABOUT A NEGLECTED GOAL?]

**Model:** Haiku — [KEEP]
