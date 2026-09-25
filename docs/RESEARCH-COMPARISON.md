# Research findings vs. the build

Written Sep 25 2026 against `main` at `a110c24`. Four sources Roman read
while designing Nudge, compared finding by finding with what the app does
today. Each row says where the app embodies the finding (with the rule or
file), where it does not, and where the research simply does not reach.
"Gap" means the research points somewhere the app does not go; "conflict"
means the app does the opposite; "n/a" means the finding is about
something the app does not attempt.

Sources:

1. Deshmukh, *Toward Neurodivergent-Aware Productivity: A Systems and
   AI-Based Human-in-the-Loop Framework for ADHD-Affected Professionals*,
   arXiv 2507.06864, July 2025. Survey of 25 ADHD professionals plus a
   proposed framework. No deployment data.
2. Guy-Evans (Simply Psychology, Dec 2025) summarizing Xu et al. 2025,
   *Psychology Research and Behavior Management*: 563 adults, structural
   equation modeling of ADHD symptoms and problematic short-video use.
3. Shou, Yamashita, Mizuno, *Association of screen time with ADHD symptoms
   and their development: the mediating role of brain structure*,
   Translational Psychiatry 2025. ABCD cohort, 10,116 children aged 9–10
   at baseline, 7,880 at two-year follow-up.
4. Louk, *ADHD and Workplace Productivity: Why Traditional Systems Fall
   Short* (Medium). **Not yet read**: Medium blocks automated readers.
   Section reserved below; paste the text and it gets filled in.

---

## 1. Deshmukh 2025 (the framework paper)

The closest source to what Nudge is. Its survey numbers are the only
quantified preferences among the four.

| Finding | Where the app stands | Verdict |
|---|---|---|
| Users find existing tools "rigid, impersonal or guilt-inducing" | `DESIGN.md` "Never shame the user" is a hard rule; nudge copy is factual, never streak or failure language; the come-back nudge names what is coming, never the absence. | embodied |
| 55% want gentle pop-up reminders; 54% want scheduled quiet check-ins | Both exist and are separate kinds: placement heads-up / due-soon are the pop-ups; the morning prompt, idle check and floater check-in are the scheduled check-ins. Daily budget 10, 90-minute spacing, so "gentle" is enforced structurally, not by copy alone. | embodied |
| 59% want weekly summaries and usage patterns | The Stats tab has daily stats, completion records, "Sessions missed". There is no weekly digest and no summary notification. | gap |
| "Accountability, not prompting … if I tell the tool I'm going for 2 hrs, knowing it checks on me drives motivation" | Focus sessions are exactly this: the user declares a block, the Live Activity and widget show it, and the placement follow-up asks after a slot passes unstarted. The Sep 23 reflow makes the session own its slot on the timeline. | embodied |
| Nudges should fire on behavioral thresholds (tab churn, missed re-entry), not rigid timers | Mixed. Placement-missed and floater are behavior-keyed (a slot passed, a task sits open). Morning prompt and idle are clock-anchored to wake time. The arbiter records outcomes (tapped, dismissed, ignored) but the fatigue gate that would consume them is deliberately off until baseline data exists. | partial |
| Strong rejection of intrusive automation; "maybe, depending on how it works" | The app never acts without a decision the user can see: plan proposals ask Yes/No, the planner places but never moves anchored items, the reflow warns before a forced overlap. AI is at the edges, arbiter is deterministic. | embodied |
| Tone should adapt to the user (affirming, playful, calming) | `UserProfile.coachingStyle` exists and is set in onboarding. It reaches the AI copy prompts; the template lines (small talk, empty capture) are one voice. | partial |
| Privacy: 77% rate it very important or mandatory; discomfort with telemetry that transmits data externally | All task data is on-device SwiftData; no analytics, no telemetry, no accounts. The one external transmission is the capture text and task list context sent to Anthropic. That is not disclosed in-app today. | partial, disclosure gap |
| "Where was I?" activity recall | Nothing equivalent. The capture log is a DEBUG tool, not a user surface. | gap |
| Digital body doubling: periodic presence cues during a session, brief check-ins after long inactivity | Sessions are a solo timer with a completion card. No presence cues during a session; the idle check-in covers inactivity between sessions, not within one. | gap |
| Voice interface | None. | n/a by choice |
| DopBoost micro-interventions (breathing, playlist, reward) | None. | n/a by choice |
| Reinforcement learning over user response to nudges | The outcome rows are the raw material; nothing learns from them yet. The morning prompt varies the named task by history, which is the one adaptive loop live. | gap, deliberately sequenced |

Where the paper's own limits matter for Nudge: 25 participants, all in
tech, no deployment. Its percentages say what people say they want, not
what changed their behavior.

## 2. Xu et al. 2025 via Simply Psychology (short-video scrolling)

About why ADHD adults scroll, not about task apps. Two mechanisms, two
different needs.

| Finding | Where the app stands | Verdict |
|---|---|---|
| Inattentive symptoms → boredom proneness → scrolling; the fix is managing boredom with attention-demanding, interesting activity, not restraint | The floater check-in and idle nudge offer a small concrete start ("Just 25 min. Start there?"). That is an offer of engagement, which is the right shape. The app does not know whether a given user is the boredom type or the distress type. | partial |
| Hyperactive-impulsive symptoms → poor cognitive reappraisal → distress → scrolling as an emotional pacifier | The never-shame rule keeps the app from adding distress. Nothing in the app addresses regulation itself, and it should not claim to. | embodied at the boundary, n/a beyond it |
| "Naming the urge is the first step"; tailor to the trigger | Nudge does not name states. Its one state-like signal is "you have been away" (come-back), phrased about what is ahead. | gap, and arguably out of scope |
| Apps engineered around immediate reward hijack the ADHD reward system | Relevant as a design constraint on Nudge itself: it has no feed, no streak-breaking, no infinite surface; the Tasks tab reads what is planned and stops. The Thinking bubble and completion haptics are the only reward-shaped moments. | embodied |

The study measured video use, not productivity tools; the article gives
no numbers. What transfers is the split: for some users the app's job is
to be interesting enough to start, for others to be calm enough not to
add pressure. The copy today leans calm for everyone.

## 3. Shou et al. 2025 (screen time and ADHD symptom development)

A children's cohort, ages 9 to 12. It does not speak to adult task
management, and its authors say the effect is small and not causal.

| Finding | Where the app stands | Verdict |
|---|---|---|
| More screen time → higher ADHD symptoms two years later (β = 0.032, p = 0.001), partly mediated by smaller cortical volume | Not applicable to adults, and Nudge is not aimed at children. The transferable design reading is only that an app for this population should minimize time in the app. Nudge is built that way: capture takes one message, the Tasks tab is a glance, nudges point out of the app and into the task. | n/a; direction consistent |
| Screen engagement may shift preference toward immediate over delayed rewards (putamen finding) | Same as above: nothing in Nudge rewards staying. The one long-dwell surface is a focus session, which is time on the task, not on the screen. | consistent |

If the target audience ever includes teenagers, this paper becomes a
constraint rather than background.

## 4. Louk (Medium) — pending

Paste the article text and this section gets the same treatment. From
the title, it likely covers why lists, calendars, and rigid time blocking
fail for ADHD, which maps onto the two-clock rule, the never-shame rule,
and the deliberate absence of streaks; but that is a guess about an
unread article, so it stays blank here.

---

## What the comparison says overall

Three findings the app already embodies more completely than most tools:
no shame, accountability by declared blocks, and decisions the user can
see. Three gaps worth a decision, in rough order of value:

1. **A weekly summary.** Wanted by 59% in the one survey, and the data is
   already collected. A once-a-week message-box memo or a Stats digest,
   no new data model.
2. **In-session presence.** The framework's body-doubling idea. A session
   today is a silent countdown; a single mid-session check-in ("still
   with you, 20 minutes left") on the Live Activity would be the smallest
   version.
3. **Disclosure.** The privacy finding is the strongest number in any of
   the four (77%), and the app's one external transmission is not stated
   in the app. One sentence in onboarding, plus the privacy policy the
   store requires anyway.

Two things the research does not support, so they stay out: voice, and
mood or dopamine interventions. And one thing it cannot settle: whether
the clock-anchored nudges (morning, idle) should become behavior-keyed.
The paper argues for it; the app's own outcome data, once the fatigue
gate is armed, is the evidence that would decide it.
