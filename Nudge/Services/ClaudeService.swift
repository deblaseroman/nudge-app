//
//  ClaudeService.swift
//  Nudge
//
//  Every AI call goes through here. Never call the Anthropic API from a View.
//
//  Integration points:
//  1. sendChat()            — brain dump conversation (Feature 1)
//  2. captureWordVomit()    — quick-capture task extraction (Feature 1)
//  3. generateTimeBlocks()  — schedule generation from tasks (Feature 2)
//  4. proposePlans()        — plan proposals for due-dated items (cycle 2026-09-16-01)
//

import Foundation
import SwiftData

class ClaudeService {
    static let shared = ClaudeService()
    private let apiKey: String = {
        // 1. Primary: read from bundled Secrets.plist. That file is
        //    gitignored — each developer pastes their own key into it
        //    so the secret never lands in source control.
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let key = plist["ANTHROPIC_API_KEY"] as? String,
           !key.isEmpty {
            return key
        }
        // 2. Secondary: Info.plist (e.g. wired via an xcconfig variable
        //    substitution). Kept for CI builds that want to inject via
        //    build settings rather than a checked-in file.
        if let key = Bundle.main.infoDictionary?["ANTHROPIC_API_KEY"] as? String, !key.isEmpty {
            return key
        }
        // 3. Tertiary: environment variable for unit-test runs that
        //    bypass the bundle entirely.
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }()
    private let model = "claude-haiku-4-5-20251001"
    /// Brain-dump capture ONLY (Sep 2026, Roman's call): the one call site
    /// where judgment quality is the product — reading "study python at 9am
    /// then work on my app" like a person. Opus 5 thinks before answering
    /// (adaptive thinking is on by default; no param needed), which is the
    /// step Haiku was structurally denied by "respond ONLY with JSON".
    /// Everything else (per-task enrichment, stakes, screenshots) stays on
    /// Haiku — cost discipline for the published-app future: tier the model
    /// per call site, not per app. ~5–10¢/dump at solo scale; re-tier before
    /// launch (Pro gets the big model, free tier Haiku — the DayPlanRefiner
    /// gating pattern).
    private var captureModel: String {
        #if DEBUG
        // `eval/run.sh --model <id>` passes this launch argument so one eval
        // run can try another model. Release builds never read arguments.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-nudge-capture-model"), i + 1 < args.count {
            return args[i + 1]
        }
        #endif
        return "claude-opus-5"
    }
    /// The daily Tasks-tab memo (Sep 2026). Opus by Roman's design: the
    /// Tasks-tab box is Opus's only user-facing surface, personalized memos
    /// written from the user's real data. Effort low, short output, at most
    /// `NudgeConfig.tasksMemoMaxPerDay` calls a day.
    private let memoModel = "claude-opus-5"
    private let baseURL = "https://api.anthropic.com/v1/messages"

    // MARK: - System Prompts

    /// The stakes rule — the definition of the CONSEQUENCE signal, written
    /// once and interpolated into the brain-dump system prompt below. (The
    /// batch classifier that also used it, the one-shot stakes backfill,
    /// was retired Sep 2026: imports get deterministic stakes at creation.) Says nothing about tasks-vs-events or the
    /// response schema on purpose — those differ per call site.
    static let stakesRuleText = """
    Stakes means CONSEQUENCE — how bad is it if this is missed or handled badly? It is NOT urgency and NOT category. Time pressure is scored elsewhere: something due tomorrow is not automatically high stakes, and a final exam three weeks away is still "high".
    "high" = lasting consequences if missed or flubbed: exams/midterms/finals, job interviews, flights, medical appointments, deadlines with real penalties (rent, visa, registration), significant personal occasions (a close friend's wedding, mom's birthday dinner).
    "medium" = matters but recoverable: regular assignments and problem sets, work shifts, classes, dated errands.
    "low" = minor or optional: someday tasks, loose intentions ("read more", "clean my desk"), hobby items.
    Stakes is not school-specific: a job interview, a doctor's appointment, and a final exam are ALL "high". A task can be priority "high" (do it soon) and stakes "medium" (recoverable if flubbed) — the two are independent.
    """

    private let chatSystemPrompt = """
    You are Nudge, a warm and energetic productivity companion for college students who want to combat executive dysfunction.

    Personality:
    - Warm, friendly, like a supportive organized friend
    - Light humor, never clinical
    - NEVER shame for missed tasks — always offer to reschedule
    - Celebrate wins genuinely

    Rules:
    - Short responses — 1-3 sentences max for the "message" field
    - No bullet points in the message
    - No clinical language (optimize, leverage, maximize)
    - NEVER ask the user "how long will this take?" or "what time?" — just add it. The user can edit duration or time later if they want to.
    - estimatedMinutes is the item's LENGTH, however the user states it: a direct duration ("an hour", "30 mins") OR a span / end time ("work 4–9", "class from 7 to 10", "until noon", "there till 9") — for a span, compute end minus start and set estimatedMinutes to the FULL span in minutes (7pm to 10pm → 180). A fuzzy end ("home by 9 or 10") uses the EARLIER end. This matters most on EVENTS: an event with estimatedMinutes null renders one hour long whatever its real length. If no duration is stated any way, leave estimatedMinutes null.
    - If the user volunteers a specific time (e.g. "at 3 PM", "tomorrow at 9"), set dueTime to that time string ("3:00 PM") AND set dueDate. Otherwise leave dueTime null and only set dueDate if a date was mentioned.
    - Assign priority: "high", "medium", or "low" (default "medium")
    - Categorize: "exam", "school", "work", "health", "personal", "errand", or "other". Use "exam" for tests/midterms/finals/quizzes; "school" for any other coursework (assignments, readings, papers); "work" for jobs/shifts/meetings; "health" for doctor/gym/therapy/medication; "personal" for friends/family/hobbies; "errand" for quick utilitarian tasks (pick up, return, pay).
    - Assign stakes: "high", "medium", or "low" on EVERY item. \(ClaudeService.stakesRuleText)
    - For TASKS, assign "timeWindow": when is this task APPROPRIATE to do, judged from its nature. EXACTLY one of: "anytime" (no constraint — study, reading, writing, laundry, tidying; THE DEFAULT, use it whenever unsure), "daytime" (reasonable waking hours — calling people, errands, chores that mean leaving the house or making noise), "businessHours" (weekday working hours — calling an office, a bank, a doctor's front desk, anything with staff). This is about the task's nature, never its deadline. Events get null.

    CRITICAL — TASKS vs EVENTS:
    Every item the user mentions is EITHER a task OR an event. You MUST decide which and set the "isEvent" boolean field:

    - EVENT (isEvent: true): a fixed-time commitment the user CAN'T move and doesn't "complete" by checking it off. They just attend or show up.
      Examples: "I have class at 9", "work shift tomorrow at 4pm", "doctor appointment Friday at 2", "meeting with my advisor", "soccer practice", "lunch with mom".
      If the user clearly names an event but gives NO time, STILL classify it as an event (isEvent: true) with dueTime null — do NOT demote it to a task. You will ask for the time in your reply (see FOLLOW-UP FOR TIMELESS EVENTS below).
      For work shifts use category "work". For class/lecture/lab use category "school". For appointments use "health" or "personal".

    - TASK (isEvent: false, the default): something the user needs to DO and check off.
      Examples: "study for bio quiz", "finish my essay", "do laundry", "email professor", "work on the assignment", "read chapter 5".
      Tasks may or may not have a specific time. They live in the Tasks list and get checked off.

    Tie-breaker phrases:
      - "I have ___ at [time]" → EVENT
      - "I need to ___" / "I have to ___" / "I should ___" → TASK
      - "Work on ___" / "study for ___" / "finish ___" → TASK
      - "class", "lecture", "shift", "appointment", "meeting" → EVENT
      - "assignment", "homework", "essay", "project" → TASK

    THE CORE CLASSIFICATION RULE (apply this to EVERY item):
    - An EVENT is something the user ATTENDS. It has a fixed start time and
      happens whether or not they are ready (classes, shifts, appointments,
      social plans). → isEvent: true
    - A TASK is something the user COMPLETES and checks off (assignments,
      studying, errands). → isEvent: false
    - A DEADLINE is NOT an event. "essay due Friday 11:59pm" is a TASK with a
      due date/time — the 11:59 is when it's DUE, not when the user shows up.
    - A task with a CHOSEN time is still a TASK. "study at 5pm" is a task,
      because it could be done at a different time and still get done.
    - A commitment WITH ANOTHER PERSON at a fixed time is an EVENT ("gym at 6
      with Jake"). Solo self-scheduled time is a TASK ("study at the library
      at 8" — could slide to 9 and still happen).
    - An exam, midterm, or presentation is an EVENT (you attend it) — but
      STUDYING or PREPARING for it is a TASK. These usually come as a pair.
    - An online quiz/assignment with an open/close WINDOW is a TASK, not an
      event, no matter how time-bound it sounds ("quiz closes Sunday night").

    LABELED EXAMPLES — study these classifications carefully:

    Dump 1: "I have work today at 5:30 then after I want to work on cleaning my room. tomorrow I need to complete my calc assignment by 11pm and I have dinner with my mom at 5pm"
      - work today 5:30 → EVENT
      - clean my room → TASK
      - calc assignment by 11pm tomorrow → TASK (deadline, not an event)
      - dinner with mom 5pm tomorrow → EVENT

    Dump 2: "bio lecture at 9 tmrw then lab at 2, need to print my lab report before that and grab a new notebook at some point"
      - bio lecture 9am → EVENT
      - lab 2pm → EVENT
      - print lab report before 2pm → TASK (time constraint, still something you complete)
      - grab a new notebook → TASK (undated floater)

    Dump 3: "study for the econ midterm this weekend, its on tuesday at 8am. also laundry lol"
      - study for econ midterm → TASK
      - econ midterm tuesday 8am → EVENT (an exam is attended — studying is the task, the exam itself is the event)
      - laundry → TASK

    Dump 4: "office hours with prof kim at 3:30 thursday, want to ask about the essay. essay is due friday 11:59"
      - office hours thursday 3:30 → EVENT
      - essay due friday 11:59pm → TASK (deadline time ≠ event)

    Dump 5: "gym at 6 with jake, then gonna study at the library at 8 for a couple hours"
      - gym at 6 with jake → EVENT (committed plan with another person at a fixed time)
      - study at library at 8 → TASK (self-scheduled — could slide to 9 and still happen; a task with a chosen time)

    Dump 6: "club meeting 7pm wed, email the group about fundraiser before then, also call mom tonight"
      - club meeting wed 7pm → EVENT
      - email group about fundraiser → TASK
      - call mom tonight → TASK (loose timing, still something you complete)

    Dump 7: "dentist moved to monday 10am ugh. reschedule my shift, and finish the stats problem set its due mon at noon"
      - dentist monday 10am → EVENT
      - reschedule my shift → TASK
      - stats problem set due monday noon → TASK

    Dump 8: "coffee w/ sarah 2pm, pick up my meds after, quiz opens friday and closes sunday night need to take it"
      - coffee with sarah 2pm → EVENT
      - pick up meds → TASK
      - take the quiz before sunday night → TASK (a window, not an appointment — online quizzes are tasks even though they have open/close times)

    Dump 9: "work 4-9 sat and sun, somewhere in there start the history reading, chapter 4 and 5"
      - work sat 4–9 → EVENT
      - work sun 4–9 → EVENT
      - history reading ch 4–5 → TASK

    Dump 10: "group project meeting at 6 in the library then I should outline my part after, presentation is next thurs at 1"
      - group project meeting 6pm → EVENT
      - outline my part → TASK
      - presentation next thursday 1pm → EVENT (attended — same logic as the exam)

    FLOATER tasks:
    A "floater" is a task with no date AND no time. It's something the user will get to whenever — low pressure. Floaters MUST have priority "low" (unless the user explicitly says it's urgent or high-priority). Do NOT default a missing date to today — leave dueDate null so the task is a true floater. Examples that should be floaters: "I should read more", "remember to clean my desk", "study spanish" (no time given).

    CRITICAL — Duplicate prevention and scope of "new":
    - You will receive an EXISTING_TASKS list. These tasks are ALREADY saved in the app from previous conversations (including previous days). Treat them as historical context, NOT as instructions to add now.
    - Only add a task to new_tasks if the user EXPLICITLY mentions it in the LATEST user message. Do not re-add tasks just because they appeared in earlier messages in the conversation history.
    - Before adding ANY task to new_tasks, check EXISTING_TASKS. If a task with a similar title AND the same due date exists, do NOT create a duplicate.
    - When the user wants to update something about an existing task, use task_updates with the existing task's id — never new_tasks.
    - If the user's latest message is conversational (e.g. "thanks", "ok", "how are you"), return empty new_tasks and task_updates arrays.

    FOLLOW-UP FOR TIMELESS EVENTS:
    - Save everything immediately — NEVER block or delay capture with questions.
    - If ONE OR MORE of the new events has no dueTime, your "message" MUST end
      with exactly ONE short question that names ALL of those events together in
      a single sentence. Example: "A few of these sound like plans — when are
      they? Birthday dinner, football game, office hours."
    - NEVER ask one question per item. NEVER send more than one follow-up per
      dump. If every event already has a time, ask nothing.
    - NEVER ask about tasks that are missing a due date — undated tasks are
      intentional floaters and must save silently.
    - When the user replies with the times, DO NOT create new events. Update the
      EXISTING events via task_updates (match by id from the task list), setting
      dueTime (and dueDate if the reply also implies a day).

    You MUST respond with ONLY valid JSON — no text before or after:
    {
      "message": "your conversational response here",
      "new_tasks": [],
      "task_updates": []
    }
    Two optional keys, absent unless the STUDY PLAN rule below applies:
      "plan_question": {"title": "<exam title>"}  — only in the turn where you asked the study-plan question.
      "plan_consent": [{"title": "<exam title>", "wants": true}]  — only in the turn where the user answered it.

    new_tasks format:
    {"title": "...", "isEvent": false, "priority": "...", "category": "...", "stakes": "medium", "estimatedMinutes": 45, "dueDate": "YYYY-MM-DD", "dueTime": "3:00 PM", "dueKind": "deadline", "sequenceIndex": null, "timeWindow": "anytime", "commitmentShape": null, "commitmentDailyCount": null, "commitmentSessionTitle": null, "goalRef": null}
    The "isEvent" boolean is REQUIRED on every new item.

    TITLES (the list, the timeline, and the widget have one line each): a short noun phrase, at most five words where the scope allows, condensed the way a person would write it on a sticky note — "Apply to a Masters program" → "Masters Application"; "go pick up the package from the mail room" → "Pick up package"; "I need to finish the reading for bio" → "Bio reading". Drop lead-in verbs and filler ("go", "try to", "I need to", "make sure I") unless the verb IS the task. Keep every identifying number or name (module 4, Chem 101, Portland), and keep an EVENT's own name as the calendar would show it. Never abbreviate into something the user would not recognize.

    DUE vs START — "dueKind" is REQUIRED on every TASK that has a dueDate (null on events, null when dueDate is null):
    - "deadline": the date is when the work is OWED. Signals: "due", "deadline", "submit", "turn in", "closes", "by [date] or I'm in trouble", assignments, essays, applications with cutoff dates, anything graded or externally enforced.
    - "start": the date is when the user MEANS TO DO IT. Signals: "I'll", "I want to", "I'm going to", "study at 7", "work on X tomorrow", chores given a day, plan items given times, self-scheduled anything.
    THE RULE: a date is when the user will DO the work unless the message says the work is OWED then. A study session before an exam is "start" (the EXAM is the fixed thing); the essay's 11:59pm is "deadline". When genuinely uncertain, use "start" — a wrong "start" just skips a countdown, a wrong "deadline" invents time pressure the app then acts on.
    THE FIELDS ARE THE TRANSPORT, dueKind IS THE MEANING: an intention still carries its day in "dueDate" and its stated clock time in "dueTime" — dueKind "start" is what tells the app to treat them as a self-scheduled start instead of a deadline. NEVER return dueDate/dueTime null on an intention that states a day or time; a stated start time the app can't see is a stated start time the app can't schedule.
    Example: "i want to study python tomorrow at 9am" → {"title": "Study Python", "isEvent": false, "dueDate": "<tomorrow>", "dueTime": "9:00 AM", "dueKind": "start", ...} — the app schedules the 9am block itself. "timeWindow" is "anytime" | "daytime" | "businessHours" on TASKS; null on events. "commitmentShape" / "commitmentDailyCount" / "commitmentSessionTitle" are set per the COMMITMENTS section; null on everything that isn't a commitment. "goalRef" is set per the PERSONAL GOALS section when one is present; null otherwise.

    ORDERED PLANS (sequenceIndex):
    - If the user states an ORDER — "first X, then Y, after that Z", "X then Y then Z", a numbered list, "do A before B" — assign sequenceIndex 1, 2, 3, … to those items in the STATED order (isEvent: false; these are plan tasks, not events).
    - Items NOT part of a stated order get sequenceIndex null.
    - CAPTURE-FIRST: every item in the plan MUST be saved in new_tasks. Never drop or merely ask about an item — even if a duration or detail is fuzzy, save it now (you may still ask a follow-up in "message"). A previous bug dropped an item that was only asked about; do not repeat that.
    - THE DUMP IS NOT ONLY THE PLAN: every distinct commitment or intention in the message becomes an item. Belonging to a stated sequence is a property of an item, not a filter on which items exist. A message that describes a plan may also contain things outside that plan — an appointment, an errand, a deadline mentioned in passing — capture those too, with sequenceIndex null and their own correct isEvent/dates. A dump that mentions nine things and yields eight items has dropped one.
    - Stated durations ("for an hour", "30 min") still go in estimatedMinutes. Do NOT INVENT dueDate/dueTime from a plan's order — being item 2 of a list implies nothing about when. But a day or clock time the user actually STATES on a plan item ("study python tomorrow at 9am, then work on my application") is captured exactly like any other stated time: dueDate/dueTime filled, dueKind "start". Order suppresses inference, never information.
    - STYLE: never use an em dash ("\u{2014}") anywhere in "message" or any field. Use commas, periods, or colons instead.
    - When you capture a plan, your "message" MUST render it back as a numbered list so the user sees the order, e.g. "Got it — here's your plan: 1. Gym  2. CVS  3. Shower + breakfast  4. Python (1h)". Plain text is fine.

    COMMITMENTS (rates, split work, daily quantities):
    Some dumps state ONGOING work rather than a one-shot task. Detect the shape and set "commitmentShape" on that task (isEvent: false always — commitments are work, never events):
    - "splitWork": a finite body of work with a deadline whose size the app can't know. "Finish module 4 by Friday", "get through the reading list before the exam". Set estimatedMinutes to the TOTAL effort in minutes IF the user states it ("about 6 hours" → 360); otherwise leave estimatedMinutes null.
    - "rate": a stated per-day cadence. "An hour a day", "30 minutes every day". Set estimatedMinutes to the PER-DAY duration (an hour a day → 60). Set dueDate to the end date if one is stated.
    - "quantity": a per-day COUNT. "Three job applications a day", "two chapters a day". Set commitmentDailyCount to the count (3, 2, …). This is ONE commitment, never N separate tasks. Set dueDate to the end date if stated.
    A plain task with a deadline ("finish my essay by Friday") is NOT a commitment — commitmentShape null. Only use a shape when the dump states ongoing/divisible/daily work.

    TWO NAMES on every commitment task (the app turns a commitment into one small task per day, so it needs both):
    - "title" states the GOAL and MUST keep the dump's specific scope — "finish module 4 of my python course" → "Complete module 4 of Python course". NEVER drop the module/chapter/unit number: the app remembers sizes by this name, and "module 4 ≈ 8 hours" is what lets module 5 skip the size question later.
    - "commitmentSessionTitle" is the SHORT name each daily session will show — "Python course", "Job applications", "App testing". A few words naming the work, nothing else: no "Complete"/"Finish" verb (a session doesn't finish the goal), no dates, no per-day amounts. The app adds a day label under it itself.
    Non-commitment items get commitmentSessionTitle null.

    FOLLOW-UP QUESTIONS — one judgment rule, not a list of cases:
    You MAY end "message" with a follow-up question only when ALL THREE are true:
    1. The answer genuinely cannot be inferred — not from the dump, not from the task list, not from the context you have (the dates, the CURRENT LOCAL CLOCK TIME, the known commitment sizes).
    2. The answer changes what the app CREATES — how many tasks, on which days, how long each is, what daily count. If the app would create the same thing either way, the question costs the user attention and returns nothing: do not ask it.
    3. You did NOT already fill the field. If you set dueDate, estimatedMinutes, or commitmentDailyCount on the task you are saving, that value is decided — asking about it (including "…right?" / "or keep going?" confirmations) is a re-ask, even bundled onto a legitimate question. The user can edit any task later; confirmation is what the editable list is for.

    Hard limits, non-negotiable:
    - Save everything FIRST. Capture is never blocked on a question — questions go at the END of "message", after the save.
    - AT MOST TWO questions per capture, combined into ONE short closing message. The timeless-event time question counts toward the two. Never a second follow-up message for the same dump.
    - Prefer zero. Two is a ceiling, not a target — an interrogation after a brain dump is the exact failure this app exists to avoid.
    - Something stated once is stated: "three things by friday" dates all three things, and a shared deadline IS the end date of any rate or quantity in the list. Never re-ask it — and never ask for CONFIRMATION of something you already set ("wrap up Friday, or keep going?" is a re-ask wearing a hat). If you set the field, the question is answered.
    - Never ask the start-today-or-tomorrow question (the app appends that itself — see START DAY), and never re-ask a size listed under KNOWN COMMITMENT SIZES.

    When the user answers, use task_updates on the saved task — total effort → estimatedMinutes (in minutes); an end date → dueDate; a per-day count → commitmentDailyCount. Do not create new tasks from an answer.

    JUDGMENT EXAMPLES:
    - "finish module 4 of my python course by friday" → split work; the size can't be inferred and it decides how the week gets divided (8 hours is four 2-hour days; 2 hours is one) → ask: "Roughly how many hours is module 4?"
    - "testing my app, an hour a day" → a rate with no end; without one it's infinite, and the end decides how many days get created → ask: "Until when should the testing run?"
    - "do laundry" → an undated one-off saves as a floater by design; a due date wouldn't change what's created → ask nothing.
    - "read chapter 5 by tomorrow" → the size can't be inferred here either, but the deadline leaves one day — one task tomorrow is what gets created at ANY size → ask nothing; the answer wouldn't change anything.
    - "apply to jobs every day" → a daily quantity with neither a number nor an end; both change what's created → one message, two questions: "How many a day — and until when?"
    - "finish the reading and the problem set by sunday" → the shared deadline covers both, and neither is ongoing/divisible work → ask nothing.
    - "by sunday: revise my resume, and practice interviews 30 minutes a day" → "by sunday" dates BOTH — it is the rate's end date, already set → ask nothing about dates; nothing else changes what's created either → ask nothing at all.
    - "by saturday: outline my thesis chapter, and stretch 15 minutes a day" → the outline is split work with no size → ask its size, and ONLY that. The stretching's end date is already Saturday because the shared deadline set it; asking "or keep going past Saturday?" is a confirmation of a field you already filled — a re-ask, not a question. One question total.
      WRONG closing: "How many hours is the chapter — and should the stretching wrap up Saturday, or keep going?"  (second half re-asks a dueDate you already set)
      RIGHT closing: "Roughly how many hours is the chapter?"

    KNOWN COMMITMENT SIZES: if the context lists a known size whose work is clearly the same kind (another module of the same course, the next chapter of the same book), set estimatedMinutes from it instead of asking. Mention the reuse briefly in "message" ("counting Module 5 at about 8 hours like the last one").
    START DAY: the app itself sometimes appends "start today, or from tomorrow?" to your message. NEVER ask that question yourself — the app only asks when the choice is real. When the user's reply answers it ("tomorrow", "start today", "tomorrow's fine"), emit task_updates for that commitment's task with "commitmentStartDay": "today" or "tomorrow" and change nothing else.
    STUDY PLAN: when this dump creates an exam-category EVENT with a date and the dump contains NO study task of the user's own for it, end "message" with ONE question, "Want me to build a study plan for <exam title>?", and set "plan_question": {"title": "<exam title>"}. It counts toward the two-question ceiling. If the dump DOES include the user's own study task for that exam, ask nothing: the app follows what they said. When the user's next message answers that question ("yes", "sure", "no", "not now"), set "plan_consent": [{"title": "<exam title>", "wants": true or false}], create nothing, update nothing, and reply in one short line. Never re-ask for an exam already answered.

    task_updates format (for updating existing tasks by id):
    {"id": "uuid-string", "estimatedMinutes": 60, "priority": "high", "dueDate": "YYYY-MM-DD"}
    Only include fields that changed. The "id" field is required.

    Example — floater tasks (no date / no time → priority "low", no dueDate):
    {
      "message": "Added study spanish and do laundry to your floaters — get to them when you can.",
      "new_tasks": [
        {"title": "Study Spanish", "isEvent": false, "priority": "low", "category": "school", "stakes": "low"},
        {"title": "Do laundry", "isEvent": false, "priority": "low", "category": "personal", "stakes": "low"}
      ],
      "task_updates": []
    }

    Example — user mentions a work shift (EVENT):
    {
      "message": "Got your work shift in — see you tomorrow at 4 PM.",
      "new_tasks": [
        {"title": "Work", "isEvent": true, "priority": "medium", "category": "work", "stakes": "medium", "dueDate": "2026-05-25", "dueTime": "4:00 PM"}
      ],
      "task_updates": []
    }

    Example — user mentions class (EVENT) AND an assignment (TASK):
    {
      "message": "Locked in class at 9 AM tomorrow and added the essay to your tasks.",
      "new_tasks": [
        {"title": "Bio 101 lecture", "isEvent": true, "priority": "medium", "category": "school", "stakes": "medium", "dueDate": "2026-05-25", "dueTime": "9:00 AM"},
        {"title": "Finish essay", "isEvent": false, "priority": "high", "category": "school", "stakes": "medium"}
      ],
      "task_updates": []
    }

    Example — no tasks mentioned:
    {
      "message": "Hey! Ready whenever you are — just tell me what's on your mind.",
      "new_tasks": [],
      "task_updates": []
    }
    """

    // Time block scheduling prompt removed — the time block system is being rebuilt.

    // MARK: - Feature 1: Brain Dump Chat Session

    /// Send a message in the brain dump conversation. Pass the full conversation
    /// history so Claude has context for clarifying questions and task extraction.
    ///
    // ── CLAUDE API INTEGRATION ──────────────────────────────────────
    // Endpoint: POST https://api.anthropic.com/v1/messages
    // Model: claude-haiku-4-5-20251001
    // Pass the full conversation history on every call.
    // System prompt: chatSystemPrompt (defined above)
    // Expected return: ClaudeResponse { message, new_tasks, task_updates, settings_updates }
    // ────────────────────────────────────────────────────────────────
    func sendChat(
        conversationHistory: [ChatMessage],
        userMessage: String,
        existingTasks: [ExistingTaskContext] = [],
        knownCommitmentSizes: [String] = [],
        activeGoals: [ActiveGoalContext] = []
    ) async throws -> ClaudeResponse {
        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        todayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let todayString = todayFormatter.string(from: Date())

        let todayISO: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        let nowClock24: String = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        let nowClock12: String = {
            let f = DateFormatter()
            f.dateFormat = "h:mm a"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        let tomorrowISO: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            return f.string(from: tomorrow)
        }()

        // Concrete weekday → ISO-date lookup for the next 14 days. The model
        // is BAD at computing "which date is next Thursday" on its own (it
        // put "Thursdays and Fridays" on the wrong dates), so we hand it an
        // exact table and forbid it from calculating.
        let upcomingDays: String = {
            let weekday = DateFormatter()
            weekday.dateFormat = "EEEE"
            weekday.locale = Locale(identifier: "en_US_POSIX")
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd"
            iso.locale = Locale(identifier: "en_US_POSIX")
            let cal = Calendar.current
            let today = Date()
            var lines: [String] = []
            // 21 days so "repeat for the next two weeks" always has every
            // occurrence available to look up (2 weeks + buffer).
            for offset in 0..<21 {
                guard let d = cal.date(byAdding: .day, value: offset, to: today) else { continue }
                let tag = offset == 0 ? "  (today)" : (offset == 1 ? "  (tomorrow)" : "")
                lines.append("- \(weekday.string(from: d)) → \(iso.string(from: d))\(tag)")
            }
            return lines.joined(separator: "\n")
        }()

        #if DEBUG
        print("[ClaudeService] Injected today's date: \(todayString) (ISO: \(todayISO)) time: \(nowClock12)")
        #endif

        // Prompt caching (Sep 23 2026): the system prompt is three blocks
        // with two breakpoints. Block 1 is the rulebook, byte-stable across
        // users and days. Block 2 is the date context and the 21-day table,
        // stable for a calendar day. Block 3 is everything that changes per
        // call: the clock line, the task list, commitment sizes, goals. The
        // clock used to sit inside block 2 (twice, once interpolated into
        // two rules), which would have missed the cache every minute; the
        // two rules now name the clock line instead of quoting its value.
        let dateBlock = """
        ===== DATE & TIME CONTEXT =====
        Today's date is \(todayString) (\(todayISO)).
        Tomorrow's date is \(tomorrowISO).

        Mapping rules — THE PRINCIPLE FIRST: any relative reference to a day
        or time, WHATEVER its phrasing, resolves against the date and clock
        above to a concrete date. A reference to the current day (however it
        says it — the day itself, its morning, its afternoon, its evening or
        night) → \(todayISO); to the day after → \(tomorrowISO). A phrasing
        that is not in the examples below still resolves by this rule — never
        leave an item undated, and never shift it to another day, because its
        wording isn't listed here.
        - "today" → dueDate = \(todayISO)
        - "tomorrow" → dueDate = \(tomorrowISO)
        - "tonight" → dueDate = \(todayISO), dueTime in the evening (after 6 PM)
        - "in N hours" / "in N hrs" → dueDate = \(todayISO), dueTime = (the CURRENT LOCAL CLOCK TIME line + N hours). Compute carefully — if the result crosses midnight, roll dueDate to \(tomorrowISO).
        - "in N minutes" / "in N min" → dueDate = \(todayISO), dueTime = (the CURRENT LOCAL CLOCK TIME line + N minutes). Same midnight-rollover rule.
        - "at HH:MM" / "at H PM" with NO day specified → dueDate = \(todayISO) IF that clock time is still in the future, otherwise dueDate = \(tomorrowISO).
        - NEVER place dueTime in the past. If the only interpretation produces a past time on \(todayISO), use \(tomorrowISO) instead.
        - If NO date AND NO time is mentioned → leave dueDate AND dueTime null. Floater rules apply (priority "low" unless explicitly urgent/high).
        - DEFAULT DUE TIME: if a due DATE is given (today, tomorrow, "by Friday", "this weekend", "by the 15th", any resolved date) but NO explicit clock time, set dueDate and leave dueTime NULL. The app treats a dateless-time due date as end-of-day (11:59 PM) for all deadline math while displaying it as date-only. Only set dueTime when the user states an explicit time ("due at 3pm", "by noon"). This applies to task due dates only, never to events.
        - Never infer dates from previous tasks or conversation history.
        - Always return dates as ISO 8601 yyyy-MM-dd. Always return times as "h:mm a" (e.g. "9:00 PM", "3:30 PM").

        NAMED WEEKDAYS — do NOT calculate these yourself. Look them up in this
        table of the next 14 days and copy the exact ISO date:
        \(upcomingDays)

        - A single named weekday ("Thursday", "this Friday", "next Monday") → use
          the ISO date of the SOONEST matching day in the table. Today counts as
          a match only if the event's clock time is still in the future today;
          otherwise use the following week's matching date.
        - A single "this <weekday>" / "next <weekday>" ("meet a friend this
          Saturday") → one event on the SOONEST matching date from the table.

        RECURRENCE — the app has no recurring-event type, so you MUST expand
        every recurrence into individual dated events: one object per
        occurrence, each with its exact ISO date copied from the table above
        and isEvent: true. Never emit a single "recurring" event.
        - Bare plural/every ("Thursdays", "every Monday", "Thursdays and
          Fridays" with no stated duration) → create the next 2 occurrences of
          EACH named day.
        - "for the next N weeks" / "repeat for N weeks" / "for N weeks" →
          create one event per named day per week, for N weeks. Multiple named
          days multiply with the week count.
          Example: "meet a friend Monday and Wednesday, repeat for the next two
          weeks" → 4 events: the next two Mondays AND the next two Wednesdays,
          each with a concrete ISO date from the table.
        - If a repeat/extend request in the LATEST message refers to an event
          already created earlier in this conversation (or present in the task
          list), add ONLY the new future occurrences — do not duplicate a date
          that already exists.
        - Never invent dates beyond the table. If the user asks for more weeks
          than the table covers, create everything the table allows and say so
          briefly in "message".
        ================================
        """
        // Block 3 opens with the clock, the one per-minute value.
        var perCallBlock = """
        The CURRENT LOCAL CLOCK TIME is \(nowClock12) (24h: \(nowClock24)).
        """
        if !existingTasks.isEmpty {
            let taskEntries = existingTasks.map { task -> String in
                var parts = [String]()
                parts.append("\"id\": \"\(task.id)\"")
                parts.append("\"title\": \"\(task.title)\"")
                parts.append("\"priority\": \"\(task.priority)\"")
                if let mins = task.estimatedMinutes {
                    parts.append("\"estimatedMinutes\": \(mins)")
                } else {
                    parts.append("\"estimatedMinutes\": null")
                }
                if let cat = task.category { parts.append("\"category\": \"\(cat)\"") }
                if let due = task.dueDate { parts.append("\"dueDate\": \"\(due)\"") }
                return "  {\(parts.joined(separator: ", "))}"
            }.joined(separator: ",\n")

            perCallBlock += """

            
            ===== THE USER'S CURRENT TASK LIST =====
            These tasks are ALREADY in the app. Do NOT put any of these in new_tasks.
            If the user mentions any of these, use task_updates with the matching id.
            If a task below has estimatedMinutes set, DO NOT ask about duration.
            [\n\(taskEntries)\n]
            =========================================
            """
        }

        // Sizes the user has already answered for past commitments — the
        // "remember the answers" half of the commitment questions: a second
        // module of the same course must not ask again. Sourced from
        // `NudgeCommitment` rows (splitWork with a totalMinutes answer);
        // matching "is this the same kind of work" is delegated to the
        // model so it rides the one capture call.
        if !knownCommitmentSizes.isEmpty {
            perCallBlock += """


            ===== KNOWN COMMITMENT SIZES =====
            The user has previously sized these. If a NEW splitWork commitment is clearly the same kind of work, set estimatedMinutes from the matching size and DO NOT ask.
            \(knownCommitmentSizes.map { "- \($0)" }.joined(separator: "\n"))
            ==================================
            """
        }

        // Goal matching rides this same call — no second round trip. Short
        // refs (G1, G2 …) instead of raw UUIDs because the model echoes a
        // two-character token far more reliably than 36 hex characters; the
        // write site maps the ref back to the goal's UUID.
        if !activeGoals.isEmpty {
            perCallBlock += """


            ===== THE USER'S PERSONAL GOALS =====
            Long-term goals the user has set in the app:
            \(activeGoals.map { "- \($0.ref): \($0.title)" }.joined(separator: "\n"))
            On each NEW TASK, set "goalRef" to the matching ref (e.g. "G1") ONLY when the task plainly serves that goal — "Practice Spanish", "Duolingo", "Spanish class homework" plainly serve a learn-Spanish goal. BE CONSERVATIVE: a wrong link corrupts the goal's activity history; a missed link costs almost nothing. Any doubt → null. Most tasks serve no goal, so null is the normal answer. Never set goalRef on events or task_updates.
            =====================================
            """
        }

        // History cap (Sep 2026): every turn re-sends the conversation, so
        // a long session grew the input bill linearly. The capture prompt
        // needs recent context (follow-up answers, "the essay I mentioned"),
        // not the whole morning.
        var messages: [[String: String]] = conversationHistory
            .suffix(NudgeConfig.chatHistoryMaxMessages)
            .map { msg in
                ["role": msg.role, "content": msg.content]
            }
        messages.append(["role": "user", "content": userMessage])

        // max_tokens covers thinking + the JSON — 1500 was Haiku's ceiling
        // and adaptive thinking would eat it and truncate the JSON.
        // `fallbacks: "default"` (server-side, beta): if Opus 5's safety
        // layer refuses a message, the request reroutes to a fallback model
        // instead of surfacing an error bubble for a grocery list.
        // effort "low" (cycle-less fix, Sep 2026): capture is structured
        // extraction against a detailed rulebook — deep adaptive thinking
        // at the default effort was burning ~7K thinking tokens (≈ 17¢ at
        // Opus output pricing) and most of the latency per dump. Low
        // effort keeps thinking on but shallow; if canonical dumps regress,
        // step to "medium" before blaming the model.
        let body: [String: Any] = [
            "model": captureModel,
            "max_tokens": 8000,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": [
                ["type": "text", "text": chatSystemPrompt,
                 "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": dateBlock,
                 "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": perCallBlock]
            ],
            "messages": messages
        ]

        return try await makeRequest(body: body)
    }

    /// Legacy single-message send (still used by quick actions).
    func send(userMessage: String, context: String = "") async throws -> ClaudeResponse {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1000,
            "system": chatSystemPrompt + "\n\nToday's date is \(Self.todayISO()). Default dueDate to \(Self.todayISO()) if none specified.",
            "messages": [
                [
                    "role": "user",
                    "content": context.isEmpty
                        ? userMessage
                        : "\(context)\nUser: \(userMessage)"
                ]
            ]
        ]
        return try await makeRequest(body: body)
    }

    /// Quick-capture: parse a brain dump into structured tasks.
    func captureWordVomit(_ text: String) async throws -> [TaskData] {
        let prompt = """
        Parse this brain dump into tasks. Today is \(Self.todayISO()).
        If no date is mentioned for a task, default dueDate to \(Self.todayISO()).
        Brain dump: "\(text)"
        Return ONLY JSON:
        {"message": "Got it! Found X tasks.", "new_tasks": [{"title": "", "dueDate": "YYYY-MM-DD", "dueTime": "afternoon", "priority": "high", "category": "school", "estimatedMinutes": 30, "recurrence": null}]}
        """
        return try await send(userMessage: prompt).tasks
    }

    // MARK: - Day plan refinement (AI layer over the deterministic planner)

    /// One API call that reorders/places today's open tasks into the free
    /// gaps the caller already computed. The model returns ONLY JSON: an
    /// ordered list of placements + a one-line rationale. Model is Haiku.
    /// The caller applies the placements (never this method) so all SwiftData
    /// mutation + arbiter reevaluation stays on the app side.
    func refineDayPlan(input: DayPlanInput) async throws -> DayPlanResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summaryJSON = (try? encoder.encode(input))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let prompt = """
        Here is a JSON summary of the user's day. Place tasks into the free gaps.

        \(summaryJSON)

        Return ONLY JSON — no prose, no markdown fences — matching this schema:
        {
          "placements": [
            {"taskID": "<id from tasks>", "startTime": "YYYY-MM-DDTHH:MM:SS", "durationMinutes": <int>}
          ],
          "rationale": "<ONE short friendly sentence>"
        }

        Hard rules:
        - Only place tasks that appear in "tasks"; use their exact taskID.
        - startTime is LOCAL time, format "YYYY-MM-DDTHH:MM:SS", no timezone.
        - Every placement MUST sit inside one of "freeGaps" and fit
          (startTime + durationMinutes ≤ that gap's end). The freeGaps already
          exclude events and their 15-minute buffers — never place outside them.
        - PLAN ORDER OUTRANKS SCORE: tasks with a non-null "sequenceIndex" are
          the user's stated plan. Place them in ASCENDING sequenceIndex order
          (lower number earlier in the day), before/around fixed events, and
          ahead of non-plan tasks regardless of score. Non-plan tasks (null
          sequenceIndex) fill remaining gaps by score.
        - Deep-work / long tasks (larger estimatedMinutes; categories exam,
          school, work) get the LONGEST gaps — apply this WITHIN each group,
          after honoring plan order.
        - Cluster errands together back-to-back when possible.
        - Nothing in the last hour before bedtime (\(input.bedtime)).
        - Leave ~15 minutes between placements.
        - Prefer fewer, well-fit placements over cramming; skip a task rather
          than force a bad fit.
        - "rationale" is ONE short sentence, no lists, calm tone.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "system": "You are a precise scheduling assistant. Return only valid JSON matching the requested schema. No prose, no commentary.",
            "messages": [["role": "user", "content": prompt]]
        ]

        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let anthropic = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = anthropic.content.first?.text else { throw ClaudeError.emptyResponse }
        let cleaned = normalizedJSONPayload(from: text)
        guard let d = cleaned.data(using: .utf8) else { throw ClaudeError.parseError }
        return try JSONDecoder().decode(DayPlanResult.self, from: d)
    }

    // MARK: - Feature 5: Screenshot Calendar Parsing

    /// Reads raw OCR text from a calendar screenshot and asks the model to
    /// emit structured events as JSON. Strict schema; expects ISO 8601
    /// datetimes anchored against today's date.
    func parseScheduleScreenshot(
        imageJPEG: Data?,
        transcript: String,
        defaultCategory: String
    ) async throws -> [ParsedScreenshotEvent] {
        let todayISO = Self.todayISO()
        let humanDate = DateFormatter.fullWeekday.string(from: Date())

        let prompt = """
        The image is a screenshot of someone's schedule. Below it is a LAYOUT TRANSCRIPT the app built from the picture: day headers were found and resolved to real dates, and every line is prefixed with the date of the header it sits under. Convert the schedule into structured events. Be GENEROUS — if a line could plausibly be an event, include it. The user is trying to import a real schedule and missing events is worse than including a bad one.

        Return ONLY a JSON array. No prose, no markdown fences. Schema:
        [
          {
            "title": "<short event name>",
            "startISO": "<datetime, format YYYY-MM-DDTHH:MM:SS, LOCAL TIME, no timezone suffix>",
            "durationMinutes": <int or null>,
            "category": "exam" | "school" | "work" | "health" | "personal" | "errand" | "other" | null,
            "stakes": "high" | "medium" | "low" | null
          }
        ]

        Rules:
        - Today is \(humanDate) (\(todayISO)).
        - THE DATE OF A LINE IS ITS BRACKETED PREFIX, e.g. "[2026-09-22 Tue] 5:00 PM - 5:15 PM | Server". Use that date exactly. Never move an event to today or to another day because of where it appears in the text. A day header with nothing under it is a day off: emit nothing for it.
        - Only a line with NO bracketed prefix needs a date inferred; then use the picture and today's date, preferring the current or coming week.
        - DATE FORMAT: Use "YYYY-MM-DDTHH:MM:SS" (e.g. "2026-06-03T09:00:00"). NO timezone, NO "Z", NO offset. We treat them as the user's local time.
        - For shift ranges like "9:00 AM - 5:00 PM" or "9a-5p", set startISO to the start time and durationMinutes to total minutes (e.g. 480 for 8 hours).
        - For class schedules like "MATH 220 MWF 10:00 AM", emit one event per implied day across the next 7 days at that time.
        - When in doubt about whether something is an event vs. UI text, INCLUDE IT. The user can delete bad ones.
        - Default category to "\(defaultCategory)" when unsure.
        - stakes = the CONSEQUENCE of missing the event, not its timing: "high" for exams/finals/interviews/flights/medical appointments; "medium" for regular classes and work shifts; "low" for optional or social items. Use null when you can't tell.
        - Two events under the same day with different times are two events (a double shift), never one.
        - Only return [] if there is genuinely zero date/time information anywhere in the text.

        LAYOUT TRANSCRIPT:
        \"\"\"
        \(transcript)
        \"\"\"
        """

        // The picture rides along so the model sees the real layout; the
        // transcript's prefixes are the rule for dates.
        var content: [[String: Any]] = []
        if let imageJPEG {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]
            ])
        }
        content.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": "You are a precise data extractor. Return only valid JSON matching the requested schema. No prose, no commentary.",
            "messages": [["role": "user", "content": content]]
        ]

        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = anthropicResponse.content.first?.text else {
            throw ClaudeError.emptyResponse
        }

        return try Self.decodeScreenshotEvents(from: text)
    }

    /// Strips fences and decodes the JSON array of events.
    private static func decodeScreenshotEvents(from raw: String) throws -> [ParsedScreenshotEvent] {
        #if DEBUG
        print("[ClaudeService] Screenshot raw response:\n\(raw)")
        #endif

        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```")    { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```")    { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract the JSON array body.
        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]") else {
            throw ClaudeError.parseError
        }
        let arrayString = String(cleaned[start...end])
        guard let arrayData = arrayString.data(using: .utf8) else {
            throw ClaudeError.parseError
        }

        let decoded = try JSONDecoder().decode([ScreenshotEventJSON].self, from: arrayData)
        #if DEBUG
        print("[ClaudeService] Screenshot decoded \(decoded.count) JSON events")
        #endif

        let mapped = decoded.compactMap { json -> ParsedScreenshotEvent? in
            guard let start = Self.parseFlexibleISO(json.startISO) else {
                #if DEBUG
                print("[ClaudeService] Dropped event — couldn't parse date: \(json.startISO)")
                #endif
                return nil
            }
            let title = json.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ParsedScreenshotEvent(
                title: title,
                startDate: start,
                estimatedMinutes: json.durationMinutes,
                category: json.category,
                stakes: TaskStakes.parse(json.stakes)
            )
        }
        #if DEBUG
        print("[ClaudeService] Screenshot final mapped: \(mapped.count) events")
        #endif
        return mapped
    }

    /// Tolerant ISO-ish date parser. Handles:
    ///   - "2026-06-03T09:00:00Z"
    ///   - "2026-06-03T09:00:00.000Z"
    ///   - "2026-06-03T09:00:00+00:00"
    ///   - "2026-06-03T09:00:00"        (no timezone — assumed local)
    ///   - "2026-06-03 09:00:00"        (space instead of T)
    ///   - "2026-06-03"                 (date only — assumed 9 AM local)
    private static func parseFlexibleISO(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try strict ISO 8601 first.
        let isoStrict = ISO8601DateFormatter()
        isoStrict.formatOptions = [.withInternetDateTime]
        if let d = isoStrict.date(from: trimmed) { return d }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }

        // Fall back to local-time formats.
        let candidates = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ]
        for format in candidates {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            if var date = formatter.date(from: trimmed) {
                if format == "yyyy-MM-dd" {
                    // Date-only → bump to 9 AM local on that day.
                    date = Calendar.current.date(
                        bySettingHour: 9, minute: 0, second: 0, of: date
                    ) ?? date
                }
                return date
            }
        }
        return nil
    }

    // MARK: - Batch nudge-copy generation (cycle 2026-08-03-03)

    /// Writes notification body copy for a batch of (kind, task) pairs in
    /// ONE request — the cache-ahead pass `NudgeCopyGenerator` runs a few
    /// times a day. One call per pass, never one per kind.
    ///
    /// Coverage contract (once shared with the retired stakes classifier): matching is by INDEX,
    /// and the response must cover the request exactly or the whole pass
    /// is thrown away — a partial answer applied silently would leave some
    /// kinds "generated" and some not, with nothing to say which.
    ///
    /// The tone rules live HERE, in the prompt (DESIGN.md governs every
    /// generated string): facts not verdicts, propose never promise, no
    /// implied failure, never shame. The copy may be delivered up to three
    /// days after it is written, so relative day words are banned outright
    /// — "tomorrow" is a lie two days later; the absolute phrase in
    /// `due` never goes stale before the cache does.
    func generateNudgeCopy(
        requests: [NudgeCopyGenerator.NudgeCopyRequest]
    ) async throws -> [Int: String] {
        guard !requests.isEmpty else { return [:] }
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }

        let kindBriefs = """
        NUDGE KINDS (what each notification is for):
        - morningPrompt: the first thing the user reads in the morning. States the day's biggest item and, when it has one, its deadline. A statement, never a question.
        - prep: an invitation to start early on a task whose deadline still has room. May propose one small first step.
        - floater: a mid-day check-in about an open task with NO deadline — it points the task out for a day with room. Mention it's there; never invent urgency for it.
        - idle: asks whether the day has gotten started. Names NO task — keep it a single gentle, concrete question.
        - comeBack: delivered only after several quiet days with no engagement. Factual and forward-looking about the named upcoming thing — a reason to come back. NEVER mention absence, time away, quiet days, streaks, or anything missed; the reader may have had a bad week, and noticing their absence is one more thing telling them they failed.
        """

        let items = requests.map { request -> String in
            var line = "\(request.index). kind=\(request.kind.rawValue)"
            if let title = request.taskTitle {
                line += " | task: \"\(title)\""
            }
            if let due = request.dueDescription {
                line += " | \(due)"
            }
            return line
        }.joined(separator: "\n")

        let prompt = """
        Write iOS notification BODY copy for a task app's nudges. One body per item below.

        \(kindBriefs)

        TONE RULES — every one is a hard rule, not a style preference:
        - State facts, never verdicts. The deadline, the task, what's possible now.
        - Propose, never promise. No "you'll be fine", "you've got this", "and you're all set" — no outcome the app can't deliver.
        - Never use an em dash ("\u{2014}"). Use commas or periods.
        - Never imply failure, lateness, or a pattern of avoidance. No guilt framed as motivation.
        - Warm and plain, not peppy. No exclamation marks, no emoji (the app adds its own urgency markers).
        - NEVER use "today", "tomorrow", "tonight", or any relative day word — this copy may be delivered up to three days after you write it. Use the absolute day given in the item ("Friday", "Aug 7") or no day at all.
        - Name the task naturally (quotes optional); don't rename or summarize it.
        - One sentence, two short ones at most. Under 140 characters.

        Return ONLY a JSON array. No prose, no markdown fences. Schema:
        [
          {"index": <the item's number below>, "body": "<the notification body>"}
        ]
        Return exactly one object per item, covering every index from 0 to \(requests.count - 1).

        ITEMS:
        \(items)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": "You write concise, honest notification copy. Return only valid JSON matching the requested schema. No prose, no commentary.",
            "messages": [["role": "user", "content": prompt]]
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = anthropicResponse.content.first?.text else {
            throw ClaudeError.emptyResponse
        }
        return try Self.decodeGeneratedCopy(from: text, expectedCount: requests.count)
    }

    /// Strips fences, decodes, and enforces exact index coverage — the
    /// same discipline as `decodeStakesClassifications`, for the same
    /// reason: a truncated or renumbered response is well-formed JSON.
    private static func decodeGeneratedCopy(
        from raw: String,
        expectedCount: Int
    ) throws -> [Int: String] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```")     { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```")     { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              let arrayData = String(cleaned[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([GeneratedCopyJSON].self, from: arrayData)
        else {
            #if DEBUG
            print("[ClaudeService] generateNudgeCopy — unparseable response:\n\(raw)")
            #endif
            throw ClaudeError.parseError
        }

        let returnedIndices = Set(decoded.map(\.index))
        guard decoded.count == expectedCount,
              returnedIndices == Set(0..<expectedCount) else {
            #if DEBUG
            print("[ClaudeService] generateNudgeCopy — response does not cover the request: sent \(expectedCount), got \(decoded.count) over \(returnedIndices.count) distinct index/indices. Abandoning pass.")
            #endif
            throw ClaudeError.parseError
        }

        var result: [Int: String] = [:]
        for row in decoded {
            let body = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty body holds its index (coverage) but contributes no
            // entry — the template covers that slot.
            guard !body.isEmpty else { continue }
            result[row.index] = body
        }
        return result
    }

    // MARK: - Goal-lapse hook (cycle 2026-08-04-03)

    /// What the hook writer gets to see. READ-ONLY arbiter/list state —
    /// assembled by the caller from data the app already has; nothing here
    /// feeds back into any scheduling decision.
    struct GoalLapseHookContext {
        let goalTitle: String
        /// "about 2 months" — precomputed so the model can't do date math.
        let elapsedPhrase: String
        /// The zero case: goal set, never worked on. The elapsed phrase
        /// then measures from creation and the copy must say "you set
        /// this…", never imply a lapse that never started.
        let neverWorked: Bool
        /// A few open task titles, so the offer can be concrete.
        let openTaskTitles: [String]
        /// Nudges ignored over the recent window — context about how
        /// reachable the user has been, not ammunition.
        let ignoredNudgeCount: Int
    }

    /// The message-box HOOK for a goal-lapse bait: the one AI-written
    /// message with real weight. Called live on app open (the app is
    /// running, unlike notification copy) by the Tasks tab, which shows
    /// the deterministic fallback until/unless this returns.
    func generateGoalLapseHook(
        context: GoalLapseHookContext
    ) async throws -> (headline: String, detail: String) {
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        let openList = context.openTaskTitles.isEmpty
            ? "(their list is empty)"
            : context.openTaskTitles.prefix(5).map { "- \($0)" }.joined(separator: "\n")

        let situation = context.neverWorked
            ? "They set the goal \"\(context.goalTitle)\" \(context.elapsedPhrase) ago and NOTHING toward it has ever made it onto their list. Frame the elapsed time as \"you set this \(context.elapsedPhrase) ago\" — do NOT imply they lapsed on work they never started."
            : "It has been \(context.elapsedPhrase) since \"\(context.goalTitle)\" last got any of their time."

        let prompt = """
        Write the in-app message a task app shows when the user opens it after a goal-lapse notification. This is the one message allowed to carry weight: showing someone how much time has passed on a goal they said matters is uncomfortable, and that discomfort is the point — it's the information they'd want.

        SITUATION:
        \(situation)
        Nudges ignored over the last two weeks: \(context.ignoredNudgeCount).
        Open tasks on their list right now:
        \(openList)

        HARD RULES:
        - State the elapsed time plainly. It is a fact and it is allowed to sting.
        - Facts, never verdicts. "It's been \(context.elapsedPhrase)" is a fact; "you keep putting this off" is a judgment — never that.
        - No guilt framed as motivation, no streak language, no "again".
        - END with one small, concrete offer to put a single small step toward the goal on today's list. Small: 15–30 minutes of it, not the whole goal.
        - Warm and plain, not peppy. No exclamation marks, no emoji.
        - Never use an em dash ("\u{2014}"). Use commas or periods.
        - "headline": one sentence stating the elapsed-time fact, under 90 characters.
        - "detail": two or three short sentences — why it's worth a look now (you may reference what's on their list), then the offer. Under 280 characters.

        Return ONLY a JSON object, no prose, no markdown fences:
        {"headline": "...", "detail": "..."}
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "system": "You write honest, warm in-app messages for a task app. Return only valid JSON matching the requested schema. No prose, no commentary.",
            "messages": [["role": "user", "content": prompt]]
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = anthropicResponse.content.first?.text else {
            throw ClaudeError.emptyResponse
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```")     { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```")     { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        struct HookJSON: Codable {
            let headline: String
            let detail: String
        }
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              let objectData = String(cleaned[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(HookJSON.self, from: objectData),
              !decoded.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            #if DEBUG
            print("[ClaudeService] generateGoalLapseHook — unparseable response:\n\(text)")
            #endif
            throw ClaudeError.parseError
        }
        return (
            decoded.headline.trimmingCharacters(in: .whitespacesAndNewlines),
            decoded.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Tasks-tab memo (Sep 2026)

    /// What the memo writer gets to see. READ-ONLY, assembled by the Tasks
    /// tab from data the app already has, every date already turned into a
    /// phrase so the model never does calendar math. Nothing here feeds
    /// back into any decision the app makes.
    struct TasksMemoContext {
        let userName: String
        /// "Wednesday, September 16, morning"
        let nowLine: String
        /// One line per open task, soonest deadline first, preformatted:
        /// `"Problem set 4" | due today at 3 PM | high stakes | toward "Pass chem"`.
        let taskLines: [String]
        /// `Today 2:00 PM: Chemistry lecture`, today and tomorrow only.
        let eventLines: [String]
        /// `"Read more": last worked on about 3 weeks ago; nothing on the list toward it`.
        let goalLines: [String]
        /// Habit facts, preformatted sentences.
        let habitLines: [String]
    }

    /// The daily memo shown in the Tasks tab's message box: the app's
    /// standing voice, a personal read of the day written from the facts
    /// above. Talk only: it explains, never asks, never changes anything.
    /// The Tasks tab shows the deterministic ladder until this lands and
    /// whenever it can't (no key, offline, parse failure, daily cap).
    func generateTasksMemo(
        context: TasksMemoContext
    ) async throws -> (headline: String, detail: String) {
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        func block(_ lines: [String]) -> String {
            lines.isEmpty ? "(none)" : lines.map { "- \($0)" }.joined(separator: "\n")
        }

        let prompt = """
        Write today's memo for the message box at the top of the user's Tasks tab. It is the one place the app speaks: a short, personal read of their day, written from the facts below. It takes no input and changes nothing; it explains.

        USER: \(context.userName)
        NOW: \(context.nowLine)

        OPEN TASKS (soonest deadline first):
        \(block(context.taskLines))

        EVENTS TODAY AND TOMORROW:
        \(block(context.eventLines))

        GOALS:
        \(block(context.goalLines))

        HABITS:
        \(block(context.habitLines))

        WHAT THE MEMO COVERS, in priority order:
        1. What they missed: anything past due, stated plainly with how long ago.
        2. What's coming up: the next deadline or event that matters, and the shape of today.
        3. What to prepare for: a high-stakes deadline inside the next week, and what a small first step could be today.
        4. A neglected goal, if one has had nothing toward it for weeks: name it once, lightly.
        Cover only what the facts support. Skip anything with nothing behind it. If everything is quiet, say so in one line.

        HARD RULES:
        - Facts, never verdicts. "Problem set 4 was due yesterday" is a fact; "you keep putting this off" is a judgment, never that.
        - Never shame: no "again", no streak language, no guilt framed as motivation.
        - Never promise an outcome. The app helps; it does not guarantee.
        - Never invent a task, event, date, or time. Use only the phrases given. Never compute dates or durations yourself.
        - Warm and plain, not peppy. No exclamation marks, no emoji.
        - Never use an em dash. Use commas or periods.
        - Speak to the user as "you". Name tasks by their titles in quotes.
        - "headline": one sentence, the single most useful thing right now, under 90 characters.
        - "detail": two to four short sentences covering the rest, under 420 characters.

        Return ONLY a JSON object, no prose, no markdown fences:
        {"headline": "...", "detail": "..."}
        """

        // Opus 5 thinks by default; effort low keeps that shallow (the
        // memo is a rewrite of given facts, not a puzzle) and max_tokens
        // leaves room for the thinking block ahead of the JSON. Refusal
        // fallbacks ride along as they do for capture.
        let body: [String: Any] = [
            "model": memoModel,
            "max_tokens": 3000,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": "You write honest, warm in-app messages for a task app built for people with ADHD. Return only valid JSON matching the requested schema. No prose, no commentary.",
            "messages": [["role": "user", "content": prompt]]
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        #if DEBUG
        if let usage = anthropicResponse.usage {
            print("[ClaudeService] USAGE: in=\(usage.inputTokens ?? 0) out=\(usage.outputTokens ?? 0) (out includes thinking) model=\(memoModel) site=tasksMemo")
        }
        #endif
        // First TEXT block: the thinking block leads the array.
        guard let text = anthropicResponse.content
                .first(where: { $0.type == nil || $0.type == "text" })?.text,
              !text.isEmpty
        else {
            throw ClaudeError.emptyResponse
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```")     { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```")     { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        struct MemoJSON: Codable {
            let headline: String
            let detail: String
        }
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              let objectData = String(cleaned[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MemoJSON.self, from: objectData),
              !decoded.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            #if DEBUG
            print("[ClaudeService] generateTasksMemo — unparseable response:\n\(text)")
            #endif
            throw ClaudeError.parseError
        }
        return (
            decoded.headline.trimmingCharacters(in: .whitespacesAndNewlines),
            decoded.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Plan proposals (cycle 2026-09-16-01)

    /// One anchored candidate as the reader sees it. Every date is already
    /// a phrase; the model never does calendar math.
    struct PlanProposalCandidate {
        let id: String
        let title: String
        /// "task" | "event"
        let kind: String
        /// "in 18 days (Oct 4th, 9:00 AM)"
        let anchorLine: String
        let daysUntilAnchor: Int
        let category: String
        let stakes: String
        let estimatedMinutes: Int?
        /// The user already said yes in the chat: build the plan, do not
        /// judge whether it is worth one.
        var consented: Bool = false
    }

    struct PlanProposalSession: Codable {
        let title: String
        let dayOffset: Int
        let minutes: Int
    }

    struct PlanProposalResult: Codable {
        let id: String
        let worthPlan: Bool
        let reason: String
        let sessions: [PlanProposalSession]

        enum CodingKeys: String, CodingKey {
            case id, reason, sessions
            case worthPlan = "worth_plan"
        }
    }

    /// The reader: judges each due-dated candidate and, when it is worth
    /// preparing for, proposes the sessions. Proposes only; writes nothing.
    /// Opus by design (the Tasks-tab box is Opus's surface), effort low,
    /// one batched request for the whole candidate set.
    func proposePlans(
        candidates: [PlanProposalCandidate]
    ) async throws -> [PlanProposalResult] {
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        guard !candidates.isEmpty else { return [] }

        let lines = candidates.map { c -> String in
            var parts = ["id: \(c.id)", "\(c.kind): \"\(c.title)\"", "when: \(c.anchorLine)",
                         "days available before it: \(c.daysUntilAnchor) (offsets 0 to \(max(c.daysUntilAnchor - 1, 0)))",
                         "category: \(c.category)", "stakes: \(c.stakes)"]
            if let m = c.estimatedMinutes { parts.append("estimated: \(m) min") }
            if c.consented { parts.append("THE USER ALREADY ASKED FOR THIS PLAN: worth_plan must be true; build it") }
            return "- " + parts.joined(separator: " | ")
        }.joined(separator: "\n")

        let prompt = """
        A task app for students with ADHD is deciding which upcoming due-dated items deserve a PLAN: a few small, dated preparation sessions before the item is due. You judge each item below and, only when it is worth it, propose the sessions. The app shows your one-sentence reason in its message box with a Yes and a No button; the user's Yes adds the sessions. You write nothing yourself.

        ITEMS (offset 0 is today; a session's dayOffset must be less than "days available"):
        \(lines)

        WHAT IS WORTH A PLAN: something the user has to prepare for or build up to over days, where a few sessions beforehand change how it goes. Exams, midterms, finals, applications, presentations, interviews, trips, a move, a large assignment or project, a big purchase or paperwork with steps. Judge honestly; most everyday items are NOT worth a plan: a dentist appointment, a class, a shift, a birthday dinner, a single errand, a one-sitting homework due tomorrow. For those return worth_plan false with a short reason.

        SESSION RULES when worth_plan is true:
        - 2 to \(NudgeConfig.planProposalMaxSessions) sessions, each \(NudgeConfig.planSessionMinMinutes) to \(NudgeConfig.planSessionMaxMinutes) minutes.
        - dayOffset counts days from today; every session lands before the item's day (dayOffset < days available). Spread them; the last one the day before, not the same day.
        - Titles are short and specific, at most six words, condensed the way a person would ("Masters Application", not "Apply to a Masters program"; "Review chapters 5 and 6", not "Sit down and go through all of the material").
        - Concrete steps for THIS item. For an exam: what to review, in order. For a trip: confirm bookings, pack, print or download what is needed. For an application: gather documents, draft, revise, submit.
        - Never invent a date, a time, or a detail the item does not state.

        REASON RULES (the sentence the user sees):
        - One plain sentence, under 120 characters, stating what is coming and that a plan would help. Facts, not verdicts. No exclamation marks, no emoji.
        - Never use an em dash. Use commas or periods.
        - Never promise an outcome. "A few sessions would spread the work out" is fine; "you'll be ready" is not.

        Return ONLY a JSON array, one object per item, no prose, no markdown fences:
        [{"id": "...", "worth_plan": true, "reason": "...", "sessions": [{"title": "...", "dayOffset": 3, "minutes": 45}]},
         {"id": "...", "worth_plan": false, "reason": "...", "sessions": []}]
        """

        let body: [String: Any] = [
            "model": memoModel,
            "max_tokens": 4000,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": "You plan preparation for a task app built for people with ADHD. Return only valid JSON matching the requested schema. No prose, no commentary.",
            "messages": [["role": "user", "content": prompt]]
        ]

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        #if DEBUG
        if let usage = anthropicResponse.usage {
            print("[ClaudeService] USAGE: in=\(usage.inputTokens ?? 0) out=\(usage.outputTokens ?? 0) (out includes thinking) model=\(memoModel) site=planProposal candidates=\(candidates.count)")
        }
        #endif
        guard let text = anthropicResponse.content
                .first(where: { $0.type == nil || $0.type == "text" })?.text,
              !text.isEmpty
        else {
            throw ClaudeError.emptyResponse
        }

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```")     { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```")     { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              let arrayData = String(cleaned[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PlanProposalResult].self, from: arrayData)
        else {
            #if DEBUG
            print("[ClaudeService] proposePlans — unparseable response:\n\(text)")
            #endif
            throw ClaudeError.parseError
        }
        // Only ids we asked about; the model may not invent items.
        let asked = Set(candidates.map(\.id))
        return decoded.filter { asked.contains($0.id) }
    }

    // MARK: - Network Layer

    private func makeRequest(body: [String: Any]) async throws -> ClaudeResponse {
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Server-side refusal fallbacks are a beta; the header rides only on
        // requests whose body opts in (capture), never on the Haiku calls.
        if body["fallbacks"] != nil {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let resp = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        #if DEBUG
        if let usage = resp.usage {
            let inTok = usage.inputTokens ?? 0
            let outTok = usage.outputTokens ?? 0
            let cRead = usage.cacheReadInputTokens ?? 0
            let cWrite = usage.cacheCreationInputTokens ?? 0
            print("[ClaudeService] USAGE: in=\(inTok) cache_read=\(cRead) cache_creation=\(cWrite) out=\(outTok) (in is the uncached remainder; out includes thinking) model=\(body["model"] as? String ?? "?")")
        }
        #endif
        // First TEXT block, not first block: thinking-capable models
        // (capture runs Opus 5) lead with a thinking block whose text is
        // empty/absent, and reading content[0] blindly would hand the parser
        // an empty string.
        guard let text = resp.content.first(where: { $0.type == nil || $0.type == "text" })?.text,
              !text.isEmpty else {
            throw ClaudeError.emptyResponse
        }
        // Drop-trace (cycle 2026-08-05-02): only the first TEXT block is
        // read. Any further text blocks are discarded here and nowhere else
        // will ever see them — say so. Thinking blocks are not drops.
        #if DEBUG
        let textBlocks = resp.content.filter { $0.type == nil || $0.type == "text" }
        if textBlocks.count > 1 {
            print("[ClaudeService] DROP: response had \(textBlocks.count) text blocks; only the first was read (\(textBlocks.dropFirst().map { $0.text?.count ?? 0 }.reduce(0, +)) chars discarded)")
        }
        #endif
        var parsed = try parseResponse(text)
        parsed.usage = resp.usage
        return parsed
    }

    private func validateResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(AnthropicErrorResponse.self, from: data) {
                switch httpResponse.statusCode {
                case 401:
                    throw ClaudeError.authenticationFailed(errorResponse.error.message)
                case 429:
                    throw ClaudeError.rateLimitExceeded(errorResponse.error.message)
                default:
                    throw ClaudeError.apiError(errorResponse.error.message)
                }
            }

            throw ClaudeError.apiError("Anthropic request failed with status \(httpResponse.statusCode).")
        }
    }

    // MARK: - Response Parsing

    private func parseResponse(_ text: String) throws -> ClaudeResponse {
        let cleaned = normalizedJSONPayload(from: text)
        guard let d = cleaned.data(using: .utf8) else {
            throw ClaudeError.parseError
        }
        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: d)
        // Drop-trace (cycle 2026-08-05-02): a response with no "new_tasks"
        // key decodes cleanly and reads as a normal empty capture — which is
        // also what a dropped array looks like. Name the difference.
        #if DEBUG
        if decoded.newTasks == nil {
            print("[ClaudeService] DROP: response decoded with NO new_tasks key (message: \"\(decoded.message.prefix(80))…\") — treated as an empty capture")
        }
        #endif
        return decoded
    }

    private func stripCodeFences(_ text: String) -> String {
        var t = text
        if t.hasPrefix("```json") { t = String(t.dropFirst(7)) }
        if t.hasPrefix("```") { t = String(t.dropFirst(3)) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedJSONPayload(from text: String) -> String {
        let cleaned = stripCodeFences(text)
        if let extracted = extractJSONObject(from: cleaned) {
            // Drop-trace (cycle 2026-08-05-02): everything outside the first
            // balanced {…} is discarded. Usually that's fence residue or a
            // stray preamble; if the model ever emits TWO objects, the second
            // dies here — this line is the only witness.
            #if DEBUG
            if extracted.count != cleaned.count {
                print("[ClaudeService] DROP: \(cleaned.count - extracted.count) chars outside the first balanced JSON object were discarded")
            }
            #endif
            return extracted
        }
        return cleaned
    }

    static func todayISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text.indices[start...] {
            let character = text[index]

            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
        }

        return nil
    }
}

// MARK: - Raw Anthropic Response

struct AnthropicResponse: Codable {
    let content: [ContentBlock]
    /// Token accounting — decoded so DEBUG can print the input/output
    /// split per call. Output includes THINKING tokens, which is where an
    /// expensive slow capture hides (Sep 2026: a routine dump cost 24¢,
    /// ~70% of it thinking at default effort).
    let usage: Usage?

    // `type`/`text` optional: thinking-capable models (capture runs Opus 5)
    // return thinking blocks with no `text` field, and a required `text`
    // made ONE thinking block fail the decode of the whole response.
    struct ContentBlock: Codable {
        let type: String?
        let text: String?
    }

    struct Usage: Codable {
        /// The UNCACHED remainder only; the full prompt is
        /// `inputTokens + cacheCreationInputTokens + cacheReadInputTokens`.
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }
}

struct AnthropicErrorResponse: Codable {
    let error: APIError

    struct APIError: Codable {
        let type: String
        let message: String
    }
}

// MARK: - Feature 1 Response Types

/// Lightweight message for passing conversation history to the API
struct ChatMessage {
    let role: String   // "user" | "assistant"
    let content: String
}

/// Snapshot of an existing task passed as context so the API avoids duplicates
struct ExistingTaskContext {
    let id: String
    let title: String
    let priority: String
    let category: String?
    let estimatedMinutes: Int?
    let dueDate: String?
}

/// An active personal goal passed as capture context for goal matching.
/// `ref` is a short stable token for this one call ("G1", "G2" …) — the
/// model echoes it back in `goalRef` and the write site resolves it to
/// the goal's UUID; raw UUIDs in the prompt got mangled too easily.
struct ActiveGoalContext {
    let ref: String
    let id: UUID
    let title: String
}

struct ClaudeResponse: Codable {
    /// Token accounting from the API envelope, attached by `makeRequest`
    /// after the JSON body is parsed. Never part of the model's own JSON,
    /// so it is excluded from coding. DEBUG prints read it.
    var usage: AnthropicResponse.Usage? = nil
    let message: String
    let taskUpdates: [TaskUpdate]?
    let newTasks: [TaskData]?
    let settingsUpdates: [String: String]?
    /// The model asked "want a study plan for X?" this turn (cycle
    /// 2026-09-16-01). The app records the outstanding question so the
    /// user's one-word answer reaches capture, not the small-talk lane.
    let planQuestion: PlanQuestion?
    /// The user answered that question this turn.
    let planConsent: [PlanConsent]?

    struct PlanQuestion: Codable {
        let title: String
    }

    struct PlanConsent: Codable {
        let title: String
        let wants: Bool
    }

    enum CodingKeys: String, CodingKey {
        case message
        case taskUpdates = "task_updates"
        case newTasks = "new_tasks"
        case settingsUpdates = "settings_updates"
        case planQuestion = "plan_question"
        case planConsent = "plan_consent"
    }

    /// Safe accessor — never nil
    var tasks: [TaskData] { newTasks ?? [] }
}

// MARK: - Day plan DTOs

/// The JSON summary of today sent to `refineDayPlan`. All times are LOCAL
/// "YYYY-MM-DDTHH:MM:SS" strings.
struct DayPlanInput: Encodable {
    struct EventDTO: Encodable {
        let title: String
        let start: String
        let durationMinutes: Int
    }
    struct GapDTO: Encodable {
        let start: String
        let end: String
    }
    struct TaskDTO: Encodable {
        let taskID: String
        let title: String
        let category: String?
        let estimatedMinutes: Int
        let dueDate: String?
        let score: Double
        let sequenceIndex: Int?     // user's stated plan order; nil = not in a plan
    }
    let now: String
    let bedtime: String
    let events: [EventDTO]
    let freeGaps: [GapDTO]
    let tasks: [TaskDTO]
}

/// The model's response for `refineDayPlan`.
struct DayPlanResult: Decodable {
    struct Placement: Decodable {
        let taskID: String
        let startTime: String
        let durationMinutes: Int
    }
    let placements: [Placement]
    let rationale: String
}

/// Codable DTO for tasks returned by the Claude API
struct TaskData: Codable {
    let title: String
    let isEvent: Bool?              // true = informational event (class/work/appointment), false/nil = actionable task
    let dueDate: String?
    let dueTime: String?
    let dueKind: String?            // "deadline" (work is owed then) | "start" (user means to do it then); nil/unknown reads as "start" — the cheap wrong guess (cycle 2026-09-03-01)
    let priority: String?
    let category: String?
    let stakes: String?             // "high" | "medium" | "low" — consequence signal; unknown/missing → nil via TaskStakes.parse
    let estimatedMinutes: Int?
    let recurrence: String?
    let dependsOnTask: String?      // title of the task this depends on (resolved client-side)
    let sequenceIndex: Int?         // 1-based order when the user states a plan ("first X, then Y")
    let timeWindow: String?         // tasks only: "anytime" | "daytime" | "businessHours" appropriateness band; unknown/missing → nil via TaskTimeWindow.parse
    let commitmentShape: String?    // "splitWork" | "rate" | "quantity" on commitment tasks; unknown/missing → nil via CommitmentShape.parse
    let commitmentDailyCount: Int?  // quantity commitments only: units per day
    let commitmentSessionTitle: String? // commitment tasks only: short session name for the generated dailies ("Python course"); title stays the goal name
    let goalRef: String?            // ref of the matching ActiveGoalContext ("G1") when the task plainly serves a personal goal; conservative, usually nil

    enum CodingKeys: String, CodingKey {
        case title
        case isEvent = "isEvent"
        case dueDate = "dueDate"
        case dueTime = "dueTime"
        case dueKind = "dueKind"
        case priority
        case category
        case stakes
        case estimatedMinutes = "estimatedMinutes"
        case recurrence
        case dependsOnTask = "depends_on_task"
        case sequenceIndex = "sequenceIndex"
        case timeWindow = "timeWindow"
        case commitmentShape = "commitmentShape"
        case commitmentDailyCount = "commitmentDailyCount"
        case commitmentSessionTitle = "commitmentSessionTitle"
        case goalRef = "goalRef"
    }
}

/// Codable DTO for task updates returned by the Claude API
struct TaskUpdate: Codable {
    let id: String?
    let title: String?
    let isComplete: Bool?
    let dueDate: String?
    let estimatedMinutes: Int?
    let priority: String?
    let dueTime: String?
    let category: String?
    let commitmentStartDay: String?  // "today" | "tomorrow" — the user's answer to the app-asked start-day question
    let commitmentDailyCount: Int?   // the user's answer to a per-day count question ("how many a day?")
}

// MARK: - Screenshot Calendar DTO

private struct ScreenshotEventJSON: Codable {
    let title: String
    let startISO: String
    let durationMinutes: Int?
    let category: String?
    let stakes: String?             // consequence signal; unknown/missing → nil via TaskStakes.parse
}

// MARK: - Nudge-copy generation DTO

/// One row of the copy-generation response — index-matched to the request
/// batch under the same coverage contract as the stakes classifier.
private struct GeneratedCopyJSON: Codable {
    let index: Int
    let body: String
}

private extension DateFormatter {
    static let fullWeekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Errors

enum ClaudeError: Error {
    case missingAPIKey
    case invalidResponse
    case authenticationFailed(String)
    case apiError(String)
    case emptyResponse
    case parseError
    case rateLimitExceeded(String)
}
