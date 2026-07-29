# Report — <cycle-id> — <short title>

**Plan:** `archive/<cycle-id>-plan.md`
**Status:** complete | partial | blocked
**Commits:** `<sha>` … (or "not committed")

> Copy this file to `<cycle-id>-<slug>.md` in this directory and fill it in.
> Same cycle ID as the archived plan — that shared ID is what pairs them.
> Leave the section headings even when a section is empty; a field that only
> appears when there's something to say stops being evidence of anything.

---

## What changed

Files touched, one line each, with the reason. Enough that the planner can
follow without repo access — it can read this directory and nothing else.

## Verification

What was actually run and what it returned. Distinguish what was *verified*
from what was *assumed*:

- Build results for both schemes.
- Any DEBUG before/after dump required by work-order item 5 — the actual
  output, and what it showed. If item 5 was skipped because the change is
  inert by construction, **say so explicitly and give the reasoning**; silence
  reads as an oversight.
- Anything that couldn't be verified here, and what it would take.

## Deviations from the plan

Where the implementation differs from what was written, and why. Includes
pushback: a constraint the plan missed, an assumption that didn't survive
contact with the code, a step that turned out unnecessary.

**"None" is a legitimate answer and should be written when true.** This field
and the next are the two the plan/report audit reads most closely — they're
where a plan being genuinely good and nobody checking look different.

## Noticed but not done

Problems spotted while in the area and deliberately left alone — out of scope,
blocked by the work order, or not worth it. Say which.

This is a queue for the planner, not a to-do list the implementer will get to.

## Open questions

Anything the next cycle needs a decision on before it can proceed.
