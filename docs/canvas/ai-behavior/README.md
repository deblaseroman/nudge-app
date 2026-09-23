# AI-behavior design canvas — working files

Source artboards for the editable Claude Design canvas of Nudge's AI
call sites (one artboard per AI surface, `canvas.json` for layout).
These were authored Sep 14 2026 but could not be published as a live
canvas because the machine had no Node/bun runtime, which the canvas
seeding helper requires.

**To publish once Node is installed:** run `/design` in Claude Code and
point it at this directory — the artboards re-seed as-is. The
non-editable fallback that shipped instead is `AI-BEHAVIOR.md` at the
repo root (Roman's spec scaffold, 9 cards mirroring these artboards).

The content here mirrors SYS-AI-05 ("The AI of Nudge",
`docs/maps/`) as of that date; verify against `docs/plan/CONTEXT.md`'s
AI census before re-publishing, since call sites change.
