# The planning bus

Coordination infrastructure. **Nothing here is application code**, nothing here
is referenced by `Nudge.xcodeproj`, and nothing here ships in the built app —
see [Why this can't reach the app](#why-this-cant-reach-the-app) at the bottom.

This directory is a file-based bus between three parties who can't see each
other's context. It exists to remove the copy-paste step from the planning
loop, not to remove the human from it.

---

**New planning conversation?** Read [`CONTEXT.md`](CONTEXT.md) first — it
orients you on how the arbiter works and what's deliberately not armed, since
you can't reach the root docs from here.

## The three roles

| Role | Who | Writes | Reads |
|---|---|---|---|
| **Planner** | A separate Claude Desktop conversation, filesystem access scoped to `docs/plan/` | `NEXT.md` | `NEXT.md`, `reports/`, `archive/` |
| **Implementer** | Claude Code, in this repo | Everything: source, `reports/`, `archive/` | Everything |
| **Approver** | Roman | Whatever he likes | Everything |

### The rule that makes this safe

**The planner never touches source.** Its filesystem access is scoped to
`docs/plan/` and nothing else — it can direct work, but it cannot edit
`Nudge/`, `NudgeWidget/`, or the Xcode project. Claude Code remains the only
writer to the source tree.

This is enforced by the scope of the planner's filesystem MCP server, not by
convention. If the planner is ever granted wider access, this guarantee is
gone and this README is lying — re-scope it or update this file.

**What the scope does *not* enforce:** the planner has write access to all of
`docs/plan/`, so it could in principle overwrite `reports/` or `archive/` as
well as `NEXT.md`. The table above is the protocol, not a permission boundary.
Git is the backstop that matters here — archived plans and reports are
committed, so any edit to a past cycle shows up as a diff on a file that
should never change again, and is recoverable. Commit reports and archived
plans promptly for that reason; an uncommitted report is the one window where
the audit trail is genuinely unprotected.

---

## The cycle

1. **Planner writes `NEXT.md`**, replacing whatever was there. One work item.
   The template in that file lists the sections a usable instruction carries.
2. **Roman approves.** This is the load-bearing step — see [The approval
   step](#the-approval-step). Nothing proceeds without it.
3. **Claude Code archives the approved plan first**, before doing any work:
   copy `NEXT.md` → `archive/<cycle-id>-plan.md`. This captures the text *as
   approved*, so a later planner turn overwriting `NEXT.md` can't destroy the
   record of what was actually authorized.
4. **Claude Code does the work** — source edits, builds, whatever the item
   needs — under the constraints in `CLAUDE.md` and `DESIGN.md`.
5. **Claude Code writes `reports/<cycle-id>-<slug>.md`** using the template in
   `reports/_TEMPLATE.md`. Same cycle ID as the archived plan; that shared ID
   is what pairs them.
6. **Planner reads the report** on its next turn and writes the next
   `NEXT.md`. Back to step 1.

A cycle that gets abandoned still leaves an archived plan with no matching
report. That asymmetry is deliberate — it's a record of something approved and
then dropped, which is exactly the kind of thing worth being able to count
later.

---

## Cycle IDs and file naming

```
YYYY-MM-DD-NN
```

`NN` is a two-digit sequence within that date, starting at `01`. Multiple
cycles a day never collide, and the whole directory sorts chronologically in
any file listing.

The ID is shared across the pair:

```
archive/2026-07-29-01-plan.md          the plan, as approved
reports/2026-07-29-01-event-toggle.md  the report for that plan
```

Reports carry a short kebab-case slug after the ID so the directory is
scannable without opening files. Archived plans use the literal suffix `-plan`
rather than a slug, so a plan and its report never sort apart.

**Next ID:** look at the highest-numbered entry in `archive/` for today's date
and add one. If there is none for today, start at `01`.

---

## The approval step

Roman reads `NEXT.md` between steps 1 and 2 and says go. The point of this
bus is to make that a glance at one file instead of shuttling text between two
chat windows — the mechanical work goes away, the judgment does not.

**This history exists to be audited.** The open question is whether the
approval step is catching real problems or has decayed into rubber-stamping,
and that can only be answered by reading a few weeks of plan/report pairs
together. Two fields in the report template carry most of that signal:

- **Deviations from the plan** — where the implementer did something other
  than what was written, and why.
- **Noticed but not done** — things spotted and deliberately left alone.

If plans routinely sail through with no deviations and no pushback, either the
planner is unusually good or nobody is really reading. Those two look identical
from inside a single cycle and obvious across thirty of them. Write both fields
honestly even when the honest answer is "none" — a field that's only filled in
when something went wrong stops being evidence.

---

## Decisions

### Superseded plans are archived, not overwritten

`NEXT.md` is a single mutable pointer at the current item — one stable path
both agents can rely on. But every version of it survives in `archive/`,
copied at approval time.

The alternative (overwrite and let git history hold the record) fails the
audit above: reconstructing plan/report pairs would mean walking commits and
diffing a single file against itself, and any plan that was approved but never
committed wouldn't be there at all. Archiving makes the pair a pair of files
you can open side by side.

### These files are committed, not gitignored

The paper trail is the entire point of archiving, and gitignored files have no
history, no diff, no recovery, and vanish on a fresh clone. Committing also
timestamps the record in a way that can't be retroactively tidied, which
matters for an audit whose whole question is whether someone was paying
attention at the time.

The cost is real: planning chatter lives in the repo history. It's the right
trade for a single-developer private repo. **If this ever needs to become a
public or shared repo**, the exit is one command —

```bash
git rm -r --cached docs/plan && echo "docs/plan/" >> .gitignore
```

— which stops tracking it going forward while leaving the local files intact.
Scrubbing it from *past* history is a separate, more invasive job
(`git filter-repo`), so make the public/private call before the history gets
long.

---

## Why this can't reach the app

Three independent reasons, in order of how hard they are to accidentally undo:

1. **Not in the project graph.** `Nudge.xcodeproj/project.pbxproj` contains
   zero references to any `.md` file. Markdown here isn't compiled, isn't a
   target member, and isn't in any Copy Bundle Resources phase. `ARCHITECTURE.md`,
   `CLAUDE.md`, and `DESIGN.md` have always lived this way.
2. **Not Swift.** Nothing in this directory is a source file in any language
   the project builds.
3. **Not imported.** No code path reads these files at runtime — they're for
   humans and agents between sessions, never for the app.

The one way to break this is to drag `docs/` into the Xcode file navigator in a
way that adds it to a target. Don't. Committing these files (the decision
above) affects the *repository*, never the *bundle* — the two are unrelated,
and only reason 1 is what keeps the app clean.
