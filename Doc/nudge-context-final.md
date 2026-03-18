# Nudge App — Master Context Document (Final)
> Paste this entire document at the start of every Claude Code session.
> All 17 wireframes complete. Ready for Xcode build.
> Last updated: All screens complete, free vs Pro model defined.

---

## 1. App Overview

**Name:** Nudge
**Tagline:** "Your friendly focus companion" / "Made for the way your brain works"
**Platform:** iOS (iPhone), App Store
**Built with:** Xcode, SwiftUI, Claude Code
**Target audience:** College students with ADHD and executive dysfunction (primary), adults with ADHD (secondary)
**Core concept:** A notification-first, widget-based AI companion that acts like a personal secretary. The app works primarily through push notifications and a home screen widget. Minimal in-app UI. Users can go weeks without opening the app and still have a fully managed schedule.

---

## 2. Problem Statement

People with ADHD and executive dysfunction abandon productivity apps within 1-2 days because those tools increase cognitive demand instead of reducing it. Nudge solves this by doing the organizing for the user, living mostly in notifications and widgets, and using AI to handle all interpretation. The app adapts to the user — it never shames, always reschedules, and gets smarter every month.

---

## 3. Design System

### Colors
- **Background:** #FFF8F0 (warm cream)
- **Primary / Brand:** #FF6040 (coral orange)
- **Accent warm:** #FF8C5A
- **Accent pink:** #FF6B9D
- **Accent yellow:** #FFD166
- **Text primary:** #2D1B0E (dark brown)
- **Text secondary:** #7a5c48
- **Text muted:** #c4a090 / #a08070
- **Success:** #4CAF50

### Typography
- **Font:** Nunito (Google Fonts)
- **Heading weight:** 900 (black)
- **Body font:** Nunito Sans
- **Body weight:** 400 regular, 600 semi-bold
- **Wordmark:** "Nudge" in Nunito 900, with the "u" in #FF6040

### Shape & Spacing
- Border radius: 16px cards, 20px buttons, 50px phone shell
- Shadows: subtle, warm-tinted
- Background blobs: soft blur (60px) atmospheric color spots

### All colors defined in a single SwiftUI theme file
When building in Xcode, create `NudgeTheme.swift` with all color values. Every screen references this file. Changing the entire app palette = changing 6 lines.

---

## 4. Mascot / Character

- **Type:** Alarm clock cartoon character (megaphone left hand, clipboard right hand)
- **Asset location:** `https://raw.githubusercontent.com/deblaseroman/nudge-app/refs/heads/main/mascot.png`
- **GitHub repo:** github.com/deblaseroman/nudge-app
- **Expression variants needed (separate files):**
  - `mascot-hype.png` — excited, onboarding, task completion, celebrations
  - `mascot-calm.png` — neutral, daily home screen, chat
  - `mascot-concerned.png` — task due soon, doom-scroll intervention
  - `mascot-celebrating.png` — streak milestones, all tasks done
- **Character name:** TBD — needs to be named before final build
- **In-app usage:**
  - Full body: splash screen, onboarding completion
  - Small circular avatar (36-38px): chat header, message bubbles
  - Widget: expression changes based on task urgency state

### Widget expression logic (zero AI tokens)
```swift
// Pseudocode
if tasksOverdue > 0 { show: mascot-concerned }
else if allTasksDoneToday { show: mascot-celebrating }
else if taskDueWithinOneHour { show: mascot-concerned }
else { show: mascot-calm }
```

---

## 5. Tech Stack

| Feature | Framework / Tool |
|---|---|
| UI | SwiftUI |
| Widget | WidgetKit |
| Notifications | UserNotifications + UNTextInputNotificationAction |
| Calendar import | EventKit |
| Screen time / app blocking | FamilyControls + Screen Time API (requires Apple entitlement) |
| Sleep/wake detection | HealthKit |
| AI companion | Claude API — claude-sonnet model |
| Data storage | SwiftData |
| Version control | GitHub — repo: github.com/deblaseroman/nudge-app |
| Project management | Jira — Scrum board, 5 sprints |

---

## 6. Free vs Pro Model

### Free (always free, no credit card)
- Home screen widget (all 4 styles)
- Task management — manual entry, check-off, reschedule
- Template-based notifications — morning briefing, wind-down, task check-ins, evening plan review
- App blocking + doom-scroll detection (Screen Time API)
- Stats screen + streaks + productivity score
- Calendar import (EventKit, Canvas iCal URL)
- Habits and goals tracking
- Settings — all manual controls

### Pro ($4.99/month)
- Word vomit task capture (Claude API)
- Screenshot to task — any calendar format (Claude vision API)
- Conversational edits — "move gym to Thursday" (Claude API)
- Nudge insight on task detail — one-line suggestion per task (Claude API, cached)
- Evening chat replies — when user types back to notification (Claude API)
- Monthly check-in AI conversation (Claude API)
- Canvas iCal interpretation (Claude API)
- Unlimited history

### 14-day free trial
- Shown on Screen 09 (onboarding completion) at peak motivation
- No credit card required
- Full Pro features during trial
- User can skip and use free version
- Trial offer also available from Settings at any time

---

## 7. AI Integration & Cost Optimization

### Model
claude-sonnet via Anthropic API

### Critical architecture rules — follow these exactly

**Rule 1: One AI call per interaction maximum**
Never chain multiple API calls. One user message = one Claude call. Claude returns both the conversational reply AND structured data changes in a single JSON response:
```json
{
  "message": "Done! Grocery moved to Tuesday.",
  "task_updates": [
    {"id": "grocery", "date": "tuesday"}
  ]
}
```

**Rule 2: Message batching — 3 second queue**
Hold messages in a local queue for 3 seconds. If user sends another message within that window, combine into one call. Show a "Nudge is reading..." state with a subtle timer bar. This prevents paying for multiple calls when users send rapid-fire messages.

**Rule 3: Soft input lock after send**
After user taps send, dim the send button for 3 seconds. Input field stays open so user can keep typing (adds to queue). Prevents accidental double-sends.

**Rule 4: Local pattern matching first**
Before calling Claude, check if message matches a known pattern:
- "add X to my list" → direct database insert, no AI
- "move X to [day]" → direct task update, no AI
- "mark X done" → direct task completion, no AI
Only call Claude when message is ambiguous or complex.

**Rule 5: Template-based notifications**
Morning briefing, evening summary, wind-down, habit reminders — ALL template-based. Zero API calls. Claude only fires if user replies with something typed.

**Rule 6: Cache AI responses**
- Nudge insight per task: generated once, cached permanently unless deadline changes
- Monthly check-in insights: generated once per month, stored locally
- Never regenerate cached content

**Rule 7: Settings = zero AI**
All settings changes are manual controls (sliders, toggles, pickers). If user says "change my bedtime to 10:30" via chat, one Claude call parses the intent, then the same code as the manual picker executes the change.

### Estimated cost at scale
- Active free user (no AI): ~$0/day
- Active Pro user (~5 AI interactions/day): ~$0.01/day
- 1,000 Pro users: ~$10/day / ~$300/month

---

## 8. Notification System

All core interactions happen via iOS push notifications. Users can respond without opening the app.

### Inline reply notifications (UNTextInputNotificationAction)
The evening check-in uses inline reply — user swipes down on notification and types directly, like replying to an iMessage. Claude processes the reply and sends a follow-up notification with the updated plan.

### Evening check-in flow (template — no AI until user replies)
```
9:30 PM notification:
"Hey Alex, here's tomorrow 👋
• Finish essay (high)
• Gym at 7am  
• Call mom
Anything to change or add?"

Quick actions: [Looks good ✓] [Make a change] [See full plan]
```

| Trigger | Message | Actions |
|---|---|---|
| Task due soon | Friendly reminder with task name | Done / Snooze / Reschedule |
| Task check-in | "Did you work on X today?" | Yes / No / Working on it |
| Screen time limit hit | "You've hit your X hour limit" | Lock it / Give me 15 min |
| Wind-down (30 min before bed) | "Wrap it up, sleep in 30 mins" | Got it / Snooze |
| Morning briefing | Today's top tasks | Open app |
| Goal nudge | Suggests working on goal when free | Let's do it / Later |
| Monthly check-in | "Time for your monthly review" | Open check-in |

### Unlock instructions (shown during Screen 04 onboarding)
Always tell user: "To unlock early, open Nudge and tap Override — no judgment."
Follow-up notification sent 5 mins after Screen 09b if widget not yet added.

---

## 9. Widget System

4 widget options — user picks preference during Screen 09b or from Settings.

### Widget 1 — Task widget (main)
Single dark card. Character + brand + streak top row. Task rows sorted by urgency (time until due). Daily goals pills at bottom. Tap checkbox = complete. Tap task name = opens app to reschedule.

### Widget 2 — Stats widget
Productivity score + progress bar. Week vs last week bar chart. Tasks done / goals hit / avg screen time. Live green dot. Tap = opens Stats screen.

### Widget 3 — Combined widget (tasks + stats)
Two column layout. Tasks left, stats right. Goals pills full width at bottom. Best of both worlds.

### Widget 4 — Companion widget
Small square (70×70pt). Just the character. Expression changes based on task state. Tap = opens task list. For users who want a clean home screen.

### Widget technical notes
- WidgetKit timeline refreshes every 15 minutes
- Instant refresh when task checked off or new task added
- Character expression driven by task data — zero AI tokens
- Tap on task name (not checkbox) → opens app to bottom sheet (Screen 12)
- Tap on checkbox → WidgetKit intent marks complete directly, no app open

---

## 10. Onboarding Flow (10 screens total)

Conversational chat interface throughout. Each step collects info AND previews the related feature. Progress bar shows current step. Skip available on every step.

| Screen | Step | Collects | Feature Preview |
|---|---|---|---|
| 01 | — | — | Splash — auto-advances 2s |
| 02 | 1/7 | Name | — |
| 03 | 2/7 | Target bedtime | Wind-down notification |
| 04 | 3/7 | Daily phone limit + watched apps | Screen time notification |
| 05 | 4/7 | Calendar import | Task list preview |
| 06 | 5/7 | Upcoming events (word vomit) | Parsed task list |
| 07 | 6/7 | Personal goals | Goal nudge notification |
| 08 | 7/7 | Habits to fix | Habit reminder notification |
| 09 | — | — | Completion + 14-day trial offer |
| 09b | — | — | Widget gate — add widget before entering app |

### Onboarding tone
Hype and energetic at start, progressively warmer and more personal. Never commands. Feels like texting a friend. "Don't think, just type."

### How-to guides
"?" info buttons on each option (Canvas iCal, Google Calendar etc) open small info modals. Not shown inline — keeps screens clean.

### Widget gate (Screen 09b)
Apple does not allow forcing a widget. Instead:
- Show "One thing before we dive in" screen
- Explain why widget is essential (always visible, zero friction, built for ADHD)
- Show real home screen mockup with widget glowing
- Primary CTA: "Add widget now" → opens iOS WidgetKit picker directly
- Secondary: "I'll do it later" → enters app with persistent banner until widget added
- Follow-up notification sent 5 mins later if widget not detected

---

## 11. Screen Index (17 screens + variants)

| # | Screen | Key details |
|---|---|---|
| 01 | Splash | Character full body, warm cream bg, loading dots, auto-advances 2s |
| 02 | Onboarding Welcome | Chat UI, user types name, progress bar step 1/7 |
| 03 | Onboarding Bedtime | Time chips (9pm/10pm/11pm/midnight/custom), wind-down notification preview |
| 04 | Onboarding Phone Limit | Slider 30m–No limit, watched app chips (Instagram/TikTok/YouTube pre-selected), iOS notification preview, unlock instructions |
| 05 | Onboarding Calendar | 4 options: Apple Calendar (recommended), Canvas iCal URL paste, Google Calendar OAuth, Screenshot upload |
| 06 | Onboarding Events | Large free text "word vomit" input, "Let Nudge sort this" button, AI parsed result with edit pencils |
| 07 | Onboarding Goals | Preset chips (Gym/Reading/Language/Side project etc) + free text add, frequency badges, "how Nudge helps" pills |
| 08 | Onboarding Habits | Preset chips (Sleep/Water/Morning routine/Meds etc), smart nudge defaults per habit, no-shame yellow card |
| 09 | Onboarding Complete | Confetti, summary grid, 14-day Pro trial card (no credit card), "Let's go" CTA |
| 09b | Widget Gate | Why widget matters, home screen mockup, "Add widget now" primary CTA, skip with persistent banner |
| 10 | Home Screen | Chat interface, morning briefing + task card, suggested prompts, tab bar: Screentime·Tasks·Home·Stats·Settings, profile avatar top right |
| 11 | Widget | 4 widget options shown side by side (Task / Stats / Combined / Companion) |
| 12 | Task Detail | Bottom sheet: task name + meta chips, Nudge insight (cached), reschedule chips (Tomorrow/same time/next week/custom), Edit button, widget reminder note, Remove task link |
| 13 | Task Capture | Full screen, large text area, "Let Nudge sort this" button, X to dismiss |
| 14 | Task Confirmation | Parsed task cards with date + time chips, yellow card for tasks missing date, inline time picker (Morning/Afternoon/Evening/Custom), "Looks good" + "Edit all" + "Add missed task" |
| 15 | Stats | Productivity score + progress bar, weekly bar chart (this week vs last week), tasks/goals/habits/screen time breakdown, week navigation arrows |
| 16 | Settings | Profile, trial banner, notifications toggles, app limits (slider + watched apps + doom-scroll toggle), schedule (bedtime + calendar), AI features (free vs Pro grid + upgrade), AI personality slider, widget style picker |
| 17 | Monthly Check-in | 4-week bar chart, month stats, AI insights (good/warn/bad), suggested adjustments (old→new), "Apply changes" + "Edit" |

---

## 12. Tab Bar

Order: **Screentime · Tasks · Home · Stats · Settings**
- Home is center with raised coral circle button (standard iOS pattern)
- Profile = avatar in top right of Home screen header (not a tab)
- Settings moved to tab 5 (replaces old profile tab)

---

## 13. Calendar Integration

### Priority build order
1. **Apple Calendar via EventKit** — one permission prompt, covers users who sync Google/Canvas to Apple Calendar
2. **Canvas iCal URL** — user pastes feed URL (found at Canvas → Account → Settings → Calendar Feed). App parses iCal file. Critical for college audience.
3. **Screenshot upload** — Claude API vision reads any calendar image (paper planner, whiteboard, any app screenshot). Massive differentiator.
4. **Google Calendar** — OAuth login, Google Calendar API

### AI calendar processing
Pass events to Claude: *"Extract tasks, assignments, and deadlines and return a prioritized to-do list with suggested work sessions scheduled before each deadline."*

---

## 14. Key Design Decisions

| Decision | Reason |
|---|---|
| Notification-first UI | ADHD users abandon apps requiring regular opens |
| Widget as primary interface | Reduces friction — task visible without opening app |
| Tap checkbox = complete (widget only) | Completion never requires opening the app |
| Tap task name = opens reschedule sheet | Reschedule/edit only reason to open app for a task |
| No shame rescheduling | Shame causes ADHD users to abandon apps entirely |
| Conversational control everywhere | "Move gym to Thursday" faster than navigating menus |
| Message batching (3 second queue) | Combines rapid messages → one API call |
| Local pattern matching before AI | Simple commands never hit Claude API |
| Template notifications | Morning/evening/habits = zero AI tokens |
| One AI call per interaction | Never chain calls; return message + data changes together |
| Cache AI responses | Nudge insight per task generated once, never repeated |
| Settings = manual controls only | Zero AI tokens, fast, offline-capable |
| Free app with Pro AI tier | College students are broke; free gets downloads, Pro converts motivated users |
| 14-day trial at onboarding completion | Peak motivation moment, no credit card barrier |
| $4.99/month Pro | Accessible for students, sustainable for API costs |
| No voice input | Removed from v1 — keeps Speech framework complexity out |
| No notes field on task detail | Users won't use it; they can tell Nudge via chat instead |
| Screenshot-to-task via Claude vision | Works on any calendar format — massive differentiator |
| Canvas iCal URL over Canvas API | No API key needed, simpler build |
| Warm cream palette over white | Softer on eyes, warmer emotional tone, less clinical |
| Nunito font | Rounded, friendly, reads young without being childish |
| No-shame note on habits screen | Directly addresses why ADHD users abandon habit apps |
| "?" info modals for how-tos | Keeps screens clean, help available when needed |

---

## 15. AI Personality System Prompt Direction

The system prompt defines everything. Key principles:
- **Warm** — like a friend who happens to be very organized
- **Humorous** — light jokes, never clinical language
- **Never shaming** — missed a task? "No worries, want to reschedule?" not "You missed this"
- **Hype during onboarding** — high energy to keep user engaged through setup
- **Calm day-to-day** — doesn't overwhelm with enthusiasm every morning
- **Concerned for interventions** — "Hey, you've been on Instagram for 47 mins" not "STOP DOOMSCROLLING"
- **Celebrating wins** — tasks done, streaks maintained, goals hit
- **Personality adjustable** via Settings slider: Gentle ↔ Blunt

---

## 16. GitHub Repo Structure

```
nudge-app/
├── Assets/
│   ├── mascot.png                    ← base character (hype expression)
│   ├── mascot-hype.png               (to be added)
│   ├── mascot-calm.png               (to be added)
│   ├── mascot-concerned.png          (to be added)
│   └── mascot-celebrating.png        (to be added)
├── Docs/
│   └── nudge-context-final.md        ← this file
├── Wireframes/
│   ├── screen-01-splash.html
│   ├── screen-02-onboarding-welcome.html
│   ├── screen-03-onboarding-bedtime.html
│   ├── screen-04-onboarding-phone-limit.html
│   ├── screen-05-onboarding-calendar.html
│   ├── screen-06-onboarding-events.html
│   ├── screen-07-onboarding-goals.html
│   ├── screen-08-onboarding-habits.html
│   ├── screen-09-onboarding-complete.html
│   ├── screen-09b-widget-gate.html
│   ├── screen-10-home.html
│   ├── screen-11-widgets.html
│   ├── screen-12-task-detail.html
│   ├── screen-13-task-capture.html
│   ├── screen-14-task-confirmation.html
│   ├── screen-15-stats.html
│   ├── screen-16-settings.html
│   └── screen-17-monthly-checkin.html
└── README.md
```

---

## 17. Jira Board

- **Project key:** NUDGE
- **Board type:** Scrum
- **Sprints:**
  - Sprint 1 — Mockups & Setup (current)
  - Sprint 2 — AI Companion Layer
  - Sprint 3 — Core Feature Build
  - Sprint 4 — Testing & Beta
  - Sprint 5 — App Store Launch
- **GitHub connected:** Yes — include ticket ID in all commits e.g. `NUDGE-12: Add onboarding chat UI`

---

## 18. App Store & Business

- **Pricing:** Free download, Pro at $4.99/month
- **14-day free trial:** No credit card, full Pro features
- **Target ASO keywords:** ADHD, executive dysfunction, college productivity, focus app, task manager ADHD
- **Target audience:** 9.1% of college students have ADHD (~1.5M in US)
- **Freemium conversion strategy:** Free app is genuinely useful → builds trust → Pro upgrade is easy sell for motivated users
- **Revenue estimate:** 1,000 Pro subscribers = ~$5,000/month - ~$300 API costs = ~$4,700/month net

---

## 19. How to Start a Claude Code Session

Paste this entire document, then say:
> "I am building the Nudge iOS app in SwiftUI. Here is the full context. Today I want to build [specific screen or feature]."

Reference wireframe HTML files from the Wireframes folder for exact visual specifications.
Mascot asset: `https://raw.githubusercontent.com/deblaseroman/nudge-app/refs/heads/main/mascot.png`

### Build order recommendation
1. SwiftData models (tasks, goals, habits, check-ins, screen usage)
2. Screen 10 — Home chat UI (establishes the design system)
3. Screen 11 — WidgetKit widget (highest daily visibility)
4. Screens 02-09 — Onboarding flow
5. Screen 12 — Task detail bottom sheet
6. Screen 13-14 — Task capture + confirmation
7. Screen 15 — Stats
8. Screen 16 — Settings
9. Screen 17 — Monthly check-in
10. Notification system
11. Claude API integration
12. FamilyControls / Screen Time
13. HealthKit integration
14. TestFlight beta
15. App Store submission
