# Eval harness

A case file you can read and add to by hand, and a runner that exercises
the real app code and prints pass/fail. Read-and-report only: it changes no
app behavior, writes to no app store.

```
eval/run.sh                # everything: arbiter cases locally, capture cases through the API
eval/run.sh --local-only   # arbiter cases only, free, run it often
eval/run.sh --no-build     # reuse the last build
eval/run.sh --model <id>   # capture model for this run only; default is what the app uses
eval/run.sh --cases <file> # run another case file, e.g. a draft
eval/run.sh --fill --cases <file>   # also write <file>.filled.json with expected = what the app did
```

Output: one line per **failing** case (`FAIL <id> | input: … | expected: … |
actual: …`), then `SUMMARY arbiter N/M passed, capture N/M passed (X%)`.
Passing cases print nothing. When capture cases ran, one more line follows:
`CACHE capture calls N: cache_read=… cache_creation=… uncached_in=…`, the
prompt-cache totals across those calls (a second run within five minutes
should show most of the prompt as `cache_read`). The app's own console
chatter is in `eval/.last-run.log`.

How it reaches the real code: the runner builds the Debug app for the
simulator and launches it with `-nudge-eval eval/cases.json`. Inside the
app, `EvalHarness` (DEBUG only) runs each case on an in-memory store through
the same entry points the app uses: the Home chat's routers, `sendChat`,
`CaptureWriter.apply`, `NudgeIntelligence.refreshIfNeeded`,
`PlacementRollover.sweep`, `NudgeArbiter.reevaluate`.
Nothing is reimplemented; the case file is read by path, not bundled.

## Drafting cases from real captures

`scripts/export-captures.sh` (phone plugged in or wirelessly connected,
unlocked, DEBUG build installed) launches the app with
`-nudge-export-captures`, pulls `eval/cases.draft.json` and prints the
counts. The draft is in this file's shape, every case `"unverified": true`,
with a `draft` object per case the harness ignores: capture date, the
assistant's reply, each row's reconstructed `dueKind`, and `floaterTarget`
from the arbiter. Captures since the DEBUG capture log shipped are exact
(`alignment: logged`); older ones are paired by day and order with the rows'
creation bursts (`exact`, or `ambiguous` with the day's bursts listed for
hand pairing). Messages the small-talk or plan routers took are their own
`swallowed-` / `plan-` cases whose `expected` records the swallow. Review,
then move what you keep into `cases.json` by hand. The draft is
git-ignored.

## Case shape

```json
{
  "id": "unique-slug",
  "kind": "capture" | "arbiter",
  "input": { … },
  "expected": { … },
  "note": "one line: why this case exists",
  "unverified": true,           // optional: expectation not confirmed against the rules
  "author": "roman"             // optional: whose case it is; the harness ignores it
}
```

### capture

`input.text` is the message, sent exactly as if typed into the Home chat
with an empty history and an empty task list. Non-deterministic, so the
summary reports a percentage.

`expected`:
- `routedTo`: `"capture"` (default), `"smallTalk"`, or `"plan"`. The two
  non-capture lanes never write rows; the harness reports the route and
  stops.
- `replyKind`: `"template"` when the reply is one of `ChatRouter`'s lines
  (chitchat, or a capture that found nothing), `"model"` when the model's
  own message is shown, `"plan"` for the planner lane.
- `rowCount`: rows written.
- `intelligenceCalls`: per-task signal API calls made for the new rows.
  Checked on every capture case even when omitted: the default expectation
  is one call per new row (the cache answers repeats). The run ends with an
  `INTEL` totals line.
- `rows`: each entry names a row by `titleContains` (case-insensitive
  substring of the stored title) plus any of the row fields below.

### arbiter

`input.tasks` are rows to insert; `input.rolloverSweep: true` runs the
day-rollover sweep before the arbiter. Deterministic, hard pass/fail.

Row fields on input (all optional except `title`): `isEvent`, `dueDate`,
`specificTime`, `intendedDate`, `plannedStartDate`, `plannedDurationMinutes`,
`plannedIsAuto`, `estimatedMinutes`, `priority`, `category`, `source`
(default `capture`), `sequenceIndex`, `skipCount`, `stakes`, `isComplete`,
`createdAt`. A bare-day `dueDate` becomes that day's 23:59, as capture
does. A `specificTime` with no `dueDate` also sets the day's 23:59
`dueDate`, as capture does for timed deadlines and events.

`expected.tasks` names rows by exact `title` plus row fields.

`input.profile` (arbiter) sets `bedtime` / `wakeTime` as `"HH:mm"` on the
case's profile; the default is bedtime 23:00 and wake 08:00, a quiet window
of 22:00 to 08:30.

`input.goals` (both kinds) inserts active goals: a string is a title; a
dict may add `lastActivityAt`, `createdAt` (relative dates) and
`isActive`. Capture cases pass them to the model exactly as the Home chat
does; a row's `goalTitle` is the linked goal's title or `null`. Arbiter
cases may assert on goals: `expected.goals[]` by `title` with
`candidates` / `eligible` / `scheduled` matched on the candidate's goal.

`input.intelligence` seeds a per-task signals row for each task before
the arbiter runs (`seedRow`, default true; `seedHash` true stores the
current freshness hash, false leaves it empty like a row from before the
column) and then asks for a refresh `asks` times (default 2) with nothing
changed. `expected.tasks[].intelligenceCalls` is the list of asks that
made a call, e.g. `[1, 0]`. A case with `seedHash: false` makes one real
call and is skipped under `--local-only`. The `INTEL` line reports both
paths: calls for new rows from capture, and calls for refresh asks on
existing rows.

### Dates

Relative to the day the run happens: `"+1d"`, `"-2d"`, `"today"`,
`"tomorrow"`, `"yesterday"`, with an optional clock `"+1d 09:00"`. Fields
that are days compare as `"+Nd"`; `plannedStart` compares as `"+Nd HH:mm"`.
`null` means the field must be empty.

### Row fields you can assert on

| field | meaning |
|---|---|
| `isEvent` | informational event, not a task |
| `hasDeadline` | owed work: has a `dueDate` or `specificTime` |
| `countdown` | the Tasks row shows a due/countdown line (open row with a deadline) |
| `isOverdue` | past its deadline and open |
| `isSkipped` | in the Skipped section |
| `intentIsFuture` | intended for a day still ahead |
| `intendedDay`, `scheduledDay`, `dueDay` | `"+Nd"` or `null` |
| `plannedStart` | `"+Nd HH:mm"` or `null` |
| `plannedIsAuto`, `estimatedMinutes`, `priority`, `sequenceIndex`, `skipCount`, `source`, `stakes` | as stored |
| `candidates` | `{ "<kind>": true/false }`: whether the arbiter built a raw candidate of that kind for this row, before gates. Kinds: `eventBlock`, `morningPrompt`, `idle`, `prep`, `dueSoon`, `floater`, `comeBack`, `placementLead`, `placementMissed`, `goalLapse` |
| `eligible`, `scheduled` | same shape: whether a candidate of that kind for this row passed the gates, and whether it was picked to fire. These read the clock (quiet hours, spacing), so assert them only where the fire time makes the answer stable |
| `fireDay`, `fireAt` | `{ "<kind>": "+Nd" }` / `{ "<kind>": "+Nd HH:mm" }`: the earliest raw candidate of that kind for this row (or goal), `null` when none |
| `goalTitle` | the linked goal's title, or `null` |

Assertions are on raw candidates, before gates, so quiet hours and the time
of day cannot flip a result. Fields you leave out are not checked.
