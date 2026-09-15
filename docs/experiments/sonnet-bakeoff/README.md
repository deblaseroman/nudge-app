# Capture model bake-off — Opus 5 (effort low) vs Sonnet 5, Sep 14 2026

Raw responses from running the real capture system prompt
(`capture_prompt.txt`, snapshot of that date) against three dump
fixtures (D1 ordered plan, D2 airport-in-5-days, D3 essay deadline) on
both models.

**Result:** Sonnet 5 was near-parity on extraction quality at roughly
3.5¢ per dump vs Opus 5 at effort low at roughly 6¢ (and 3–7s). Roman's
call: **keep Opus low for capture during the evaluation phase** — the
judgment calls (deadline-vs-intent, order-vs-time inference) are the
product; Sonnet is the standing cost lever to pull at launch if
economics demand it. See the cost-discipline notes in the session
memory and `docs/plan/CONTEXT.md`'s AI census for the live config.
