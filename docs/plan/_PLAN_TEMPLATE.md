# Plan template

The shape a usable instruction takes. Copy the sections into `NEXT.md` and
replace the guidance text wholesale — don't leave it in a real plan.

`NEXT.md` holds **one** work item: the current one. The planner overwrites it
each cycle; the approved version is copied to `archive/<cycle-id>-plan.md`
before any work starts, so overwriting never loses the record. Protocol:
[`README.md`](README.md). A filled-in example is whatever `NEXT.md` currently
holds.

---

## Header

Every plan opens with:

```
**Status:** awaiting approval | approved | superseded
**Cycle ID:** YYYY-MM-DD-NN
**Source:** where this came from — a ROADMAP.md section, a report's open
question, a bug hit in the wild
```

### What to build

The change itself, concretely enough to start on. Name files, symbols, and
call sites where they're already known — a plan that says "improve the
scoring" costs a discovery pass that the planner could have spent instead.

State the scope boundary explicitly. What's the smallest complete version of
this?

### Why

The problem this solves, and who has it. Not a restatement of the what.

If this is a product-behavior change — copy, what the user is told, when
they're interrupted, what the app decides for them — say which `DESIGN.md`
principle it serves. If it conflicts with one, say so here rather than letting
it surface mid-implementation.

### Constraints

What must stay true. Start from the standing ones and add what's specific to
this item:

- **`CLAUDE.md` work order.** Sequencing constraints in force right now, each
  a deliberate state. If this item touches one, say which and say why it's
  authorized — otherwise the implementer will refuse it, correctly.
- **`DESIGN.md`.** Product intent. The arbiter's path stays deterministic; no
  API calls in it. No promised outcomes, no shaming copy.
- **`ARCHITECTURE.md`.** Update it when adding, moving, or repurposing files.
- **Hand-synced lists.** A new `@Model` has to land in all three schema lists
  (app container, widget container, `#Preview`) — a mismatch is a runtime
  crash, not a build error.
- **Migration safety.** A new non-optional `UserProfile` field needs a
  property-level default; there's no `VersionedSchema`, so a defaultless
  attribute fails at launch on existing stores rather than at build.

### Evidence it worked

What observation would distinguish "this works" from "this compiles"? Be
specific about which of these applies:

- **Both schemes build** — the floor, not evidence. There are no test targets,
  so a green build means only that it's syntactically valid.
- **DEBUG before/after on real data** — required by work-order item 5 for any
  change that alters what the arbiter does. Name the comparison and what
  outcome would falsify the change, not just that a dump should be printed.
- **Inert by construction** — if the change genuinely cannot alter behavior
  (a default-true toggle, a pure addition), say so and say why, so the
  implementer reports the reasoning instead of silently skipping item 5.
- **Observed in the running app** — when the only real proof is a notification
  actually firing.

### Out of scope

Things adjacent to this that should be left alone this cycle, especially
known-wrong ones the implementer will otherwise trip over and want to fix.
`CLAUDE.md` lists known bugs that are deliberately unfixed; if one is in the
blast radius, name it here so it stays unfixed on purpose rather than by
accident.
