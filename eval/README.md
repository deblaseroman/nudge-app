# Eval harness

A case file you can read and add to by hand, and a runner that exercises
the real app code and prints pass/fail. Read-and-report only: it changes no
app behavior, writes to no app store.

```
eval/run.sh                # everything: arbiter cases locally, capture cases through the API
eval/run.sh --local-only   # arbiter cases only, free, run it often
eval/run.sh --no-build     # reuse the last build
```

Output: one line per **failing** case (`FAIL <id> | input: … | expected: … |
actual: …`), then `SUMMARY arbiter N/M passed, capture N/M passed (X%)`.
Passing cases print nothing. The app's own console chatter is in
`eval/.last-run.log`.

How it reaches the real code: the runner builds the Debug app for the
simulator and launches it with `-nudge-eval eval/cases.json`. Inside the
app, `EvalHarness` (DEBUG only) runs each case on an in-memory store through
the same entry points the app uses: the Home chat's routers, `sendChat`,
`CaptureWriter.apply`, `PlacementRollover.sweep`, `NudgeArbiter.reevaluate`.
Nothing is reimplemented; the case file is read by path, not bundled.

## Case shape

```json
{
  "id": "unique-slug",
  "kind": "capture" | "arbiter",
  "input": { … },
  "expected": { … },
  "note": "one line: why this case exists",
  "unverified": true            // optional: expectation not confirmed against the rules
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
- `rowCount`: rows written.
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

Assertions are on raw candidates, before gates, so quiet hours and the time
of day cannot flip a result. Fields you leave out are not checked.
