# Addendum — post-08 direct design feedback (no plan pair)

**Plan:** none — Roman gave feedback directly in the implementation session,
outside the bus. Recorded here so the next planning turn doesn't reason from
the -08 report's now-stale description.
**Status:** complete
**Commits:** `142019f`

---

## What changed

1. **The -08 chat chip is gone.** The chat affordance is now a filled
   `primary` **circle** (36pt, bubble icon, white glyph) sitting **overtop
   of the message box's bottom-right corner** — a badge straddling the
   border (bottomTrailing overlay, 10pt offset). Costs the box no height;
   the content row is back to exactly its pre-chip layout. Same shell, same
   rendered-only-when-wired rule.
2. **Plan my day and Start Session are one compact row**: side by side,
   44pt, centered content — replacing the two stacked 52pt slabs so the
   task lists sit ~72pt higher without scrolling. The active-session banner
   keeps its full-width row (live content doesn't fit a half-width form).
   The pair still shares the primary treatment; the visual distinction
   remains Roman's open call, untouched.
3. **List-tab content indicators**: unselected chips (Unscheduled / Today /
   Events / Overdue) carry a 1.5pt stroke when their tab has tasks or
   events behind it — `primary` blue, except the Overdue chip which strokes
   in its existing overdue red. Membership comes from `tabHasContent`,
   which uses the exact rules each tab body renders with. Selected chips
   show no indicator.

## Verification

Both schemes build clean (zero warnings). On-device look not verified here —
the circle's 10pt overhang past the box border and the indicator stroke
inside the horizontal tab strip (1pt vertical padding added against
clipping) are the two spots to eyeball.
