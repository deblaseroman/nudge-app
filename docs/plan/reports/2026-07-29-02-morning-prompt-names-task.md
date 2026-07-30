# Report — 2026-07-29-02 — Morning prompt names the day's biggest task

**Plan:** `archive/2026-07-29-02-plan.md`
**Status:** complete (code); **on-device evidence outstanding** — see Verification
**Commits:** second commit on `automation-run-1`

---

## What changed

All of it in `Nudge/Services/NudgeArbiter.swift` except one comment.

- `buildMorningPromptCandidates` — body is now a statement naming a task;
  gating is untouched (toggle → day-fullness → fire-moment busy, same order,
  same thresholds). One new gate at the end: **no open task ⇒ no candidate**.
- `morningPromptRanking(fireDate:modelContext:)` — new, split out of the
  builder the way `floaterTargets` is split out of the floater builder, so the
  DEBUG dump runs the real selection instead of a paraphrase. Fetches open
  non-event tasks (limit 50, same shape as `buildGetAheadCandidates`), keeps
  the top stakes tier, ranks it by deadline proximity.
- `morningStakesRank` — `high 3 / medium 2 / nil 1 / low 0`. See Deviations.
- `morningDeadlineUrgency` — the tie-break, via the existing
  `EisenhowerScorer.urgency` curve at the fire date, `DurationModel` for
  effort. Computed only for the top tier, so the common case is 1–3 duration
  lookups rather than 50.
- `morningPromptBody` / `morningDeadlinePhrase` — the copy and its date
  rendering.
- `debugMorningPromptImpact` — before/after dump, called from `reevaluate`'s
  DEBUG block next to `debugQuietHoursImpact`.
- `Nudge/Services/NudgeOutcomeClassifier.swift` — **comment only, no code.**
  Flags that the `.morningPrompt` branch of `performedAction` is now stale (see
  Deviations).
- `ARCHITECTURE.md` — the `NudgeArbiter` entry's morning-prompt paragraph.

Copy, as it renders:

```
Biggest thing on your list: "Chem lab report" — due today at 5:00 PM.
Biggest thing on your list: "Study for the MCAT".
```

Title stays "Good morning". `categoryID` stays `.morningPrompt`, so the tap
still routes to Home chat — that routing keys on `kind` in the delegate, which
is untouched.

## Verification

**Both schemes build.** `** BUILD SUCCEEDED **` for `Nudge` and
`NudgeWidgetExtension`.

**The copy and its date branches were executed, not eyeballed.** I extracted
`morningPromptBody`, `morningDeadlinePhrase` and `morningStakesRank` from
`NudgeArbiter.swift` **by line range** (`sed`, not retyped) into a scratch file
with a three-field `NudgeTask` stub, and ran them against a fire date of Mon
2026-08-03 08:30:

```
due later today, clock time     Biggest thing on your list: "Chem lab report" — due today at 5:00 PM.
due today, NO clock time        Biggest thing on your list: "Pay tuition deposit" — due today.
due tomorrow, clock time        Biggest thing on your list: "Stats problem set" — due tomorrow at 9:00 AM.
due 3 days out, no clock        Biggest thing on your list: "Read chapter 7" — due Thursday.
due 6 days out, no clock        Biggest thing on your list: "Group project draft" — due Sunday.
due 7 days out (falls to date)  Biggest thing on your list: "Passport renewal" — due Aug 10.
due far out, clock time         Biggest thing on your list: "Book flights home" — due Aug 28.
undated                         Biggest thing on your list: "Study for the MCAT".
OVERDUE yesterday               Biggest thing on your list: "Return library books".
OVERDUE yesterday, no clock     Biggest thing on your list: "Renew parking permit".
due 20 min BEFORE the prompt    Biggest thing on your list: "Move the car".

stakes rank: high=3 medium=2 unclassified=1 low=0
```

**This caught a real bug before it shipped.** The first run rendered *"due
today, NO clock time"* with no deadline clause at all. A bare `dueDate` is a
**day**, stored as that day's midnight, so the original `deadline > fireDate`
guard called anything due today "already passed" from 00:01 onwards — silently
dropping the clause for what is probably the single most common case. The guard
now compares at the deadline's own granularity: instants for `specificTime`,
whole days for a bare `dueDate`. The last two rows above confirm genuinely-past
deadlines still drop the clause in both forms.

**Work-order item 5 — the DEBUG before/after — is shipped but not yet run on
real data.** Same situation as cycle 1: the only `Nudge.store` reachable from
here is an empty simulator one whose schema predates `stakesRaw` entirely, so
there is no real data on this machine to dump. Rather than report nothing, the
comparison ships as `debugMorningPromptImpact`, following the existing
`debugFloaterImpact` / `debugQuietHoursImpact` convention. On Roman's device the
next foreground prints:

```
[MorningPrompt] fire=Mon Aug 3 08:30  (gating unchanged: toggle, day-fullness, fire-moment busy)
  BEFORE: "What do you want to get done today? Tell me and I'll set it up."  ← fired with nothing open too
  AFTER : "Biggest thing on your list: ..."
  ranked N contender(s) in the top stakes tier (stakes ▸ deadline proximity ▸ id):
      high          0.42  Thu Jul 31 17:00  Chem lab report
      ...
```

It also prints the one line that matters for the plan's third piece of
evidence — *with no open tasks, no morning prompt candidate is built* — as an
explicit `AFTER : SKIP — nothing open to name. THIS is the behaviour change`,
and distinguishes it from the pre-existing gates stopping the builder earlier.
That distinction can't be read off a candidate count, which is why it's a
sentence rather than a number. **Nobody has watched it print yet.** What it
takes: install the branch, foreground the app once.

**What the change cannot do**, checked rather than assumed:

- **Scoring is untouched.** `EisenhowerScorer.importance` is not called with
  `stakes:` anywhere; `morningPromptRanking` reads `task.stakes` directly, per
  the plan and work-order item 1. The candidate still carries
  `urgency: 1.0, importance: 1.0` exactly as before, so `pickWinners` sees the
  identical number.
- **Fire time is untouched.** No line between the toggle guard and the
  day-fullness check changed; the candidate ID still stamps the fire day.
- **Selection is deterministic.** The final sort key is the task UUID string,
  so two equally-urgent tasks in the same tier can't swap between reevaluates
  on fetch order. A notification naming a different task each run would be
  indistinguishable from a bug, and this is a `DESIGN.md` core-determinism
  constraint, not a nicety.

## Deviations from the plan

1. **`taskID` stays nil, and the plan expected me to check whether it could
   change.** What I found, in full, because the finding is bigger than the
   question:
   - In `performedAction` it **is** free. The `row.kind == .morningPrompt`
     branch returns before the `guard let taskID`, so setting it changes zero
     classifications. The plan's stated concern doesn't materialise.
   - It is **not** free for the other two `taskID` consumers, which the plan
     didn't ask about. `passesGates`' per-task fatigue check exempts kinds via
     `successIsObservableInApp`, and `.morningPrompt` *passes* that predicate —
     so the named task would accumulate fatigue from a nudge that isn't a push
     to work on it. `buildBreakItDownCandidates` counts the same rows, so an
     ignored morning prompt would push the user's **highest-stakes task** toward
     a break-it-down offer.
   - Both are inert today because `fatigueGateEnabled` is off — which is
     exactly what makes it a landmine rather than a bug. It would change
     behaviour on the day that flag flips, for the one task least able to
     afford it, and work-order items 2 and 3 exist to keep that flip clean.

   So: nil, with the reasoning written into the builder. The cost is that
   `.morningPrompt` outcome rows still show `—` in the dump's TASK column, so
   *which* task was named lives only in the DEBUG log. If the planner wants
   attribution in the outcome data, the prerequisite is an exemption in the two
   fatigue consumers, and that's its own item.

2. **Where `nil` stakes sorts was mine to decide.** The plan says "highest
   stakes, ties broken by deadline proximity" and stakes is optional, which it
   doesn't address. I put `nil` **above** `.low`: nil means "never classified"
   (absence of evidence), `.low` is a positive statement that the item is minor
   — the strongest argument against giving it the best slot in the app. It's
   also the common case rather than an edge case, since `stakesRaw` is only
   written by the capture/import path, so ranking nil last would hand the
   morning slot to whichever hobby item happened to get labelled. Say so if the
   intended order was different; it's one function.

3. **One comment added outside `buildMorningPromptCandidates`,** against the
   plan's "copy and targeting change to `buildMorningPromptCandidates` only".
   No code changed. `NudgeOutcomeClassifier.performedAction` infers `.acted`
   for a morning prompt from "any task created in the window", and its comment
   justified that by quoting the question the prompt used to ask. That question
   no longer exists, so the comment was actively misleading as of this commit. I
   annotated it rather than changing it — see Open questions for the real issue.

## Noticed but not done

- **Nothing scopes the named task to the near future.** Per the plan, stakes is
  the primary key with no horizon, so a high-stakes task due in three months
  ("Book flights home") outranks a medium-stakes one due today and gets named
  every single morning until it's done. That's the plan's design decision and I
  built it, but the repetition is worth a look once there's real output: an
  unchanging daily notification is the fastest way to teach someone to ignore
  the channel. A horizon, or a "don't repeat the same task N days running"
  rule, would be a separate item.
- **`.low` stakes tasks can still be named** — if every open task is `.low`,
  the top tier *is* `.low` and one of them gets the slot. Arguably the "no open
  task qualifies" rule should treat an all-`.low` list as not qualifying. Left
  as-is: the plan defines the no-fire condition as "no open task", not "no task
  worth naming", and inventing a second silence rule seemed like the wrong side
  to err on.
- **The morning prompt is still budget-exempt and still exempt from quiet
  hours**, so `ROADMAP.md` §2's "custom quiet hours can swallow the morning
  prompt" is untouched and unaffected by this.
- **`morningPromptBusyDayThreshold` (50%) still probably never triggers.** Out
  of scope, `ROADMAP.md` §1, and the new content gate doesn't change it.

## Open questions

- **What should `.acted` mean for the morning prompt now?** It's a statement,
  not a question, so "the user created a task in the response window" measures
  something the notification no longer asks for. The honest answer is probably
  "started or completed the named task" — which needs `taskID`, which needs the
  fatigue exemption in deviation 1. Three things that have to move together;
  none of them moved here. Until then, `.morningPrompt` rows keep their old
  meaning and the cut point is the same 2026-07-30 noted in cycle 1's report.
- **Is "Biggest thing on your list" the right register?** It states the app's
  ranking rather than a verdict about the user, promises nothing, and drops the
  deadline for anything already past due specifically so it can't read as an
  accusation before the user is out of bed. That's my reading of `DESIGN.md`,
  but the plan asked for tone review and this is the sentence to review.
