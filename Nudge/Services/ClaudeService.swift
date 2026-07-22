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
//  4. generatePrepPlan()    — multi-day prep for upcoming events (Feature 4)
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
    private let baseURL = "https://api.anthropic.com/v1/messages"

    // MARK: - System Prompts

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
    - If the user volunteers a duration (e.g. "an hour", "30 mins"), set estimatedMinutes. Otherwise leave estimatedMinutes null.
    - If the user volunteers a specific time (e.g. "at 3 PM", "tomorrow at 9"), set dueTime to that time string ("3:00 PM") AND set dueDate. Otherwise leave dueTime null and only set dueDate if a date was mentioned.
    - Assign priority: "urgent", "high", "medium", or "low" (default "medium")
    - Categorize: "exam", "school", "work", "health", "personal", "errand", or "other". Use "exam" for tests/midterms/finals/quizzes; "school" for any other coursework (assignments, readings, papers); "work" for jobs/shifts/meetings; "health" for doctor/gym/therapy/medication; "personal" for friends/family/hobbies; "errand" for quick utilitarian tasks (pick up, return, pay).

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

    new_tasks format:
    {"title": "...", "isEvent": false, "priority": "...", "category": "...", "estimatedMinutes": 45, "dueDate": "YYYY-MM-DD", "dueTime": "3:00 PM", "sequenceIndex": null}
    The "isEvent" boolean is REQUIRED on every new item.

    ORDERED PLANS (sequenceIndex):
    - If the user states an ORDER — "first X, then Y, after that Z", "X then Y then Z", a numbered list, "do A before B" — assign sequenceIndex 1, 2, 3, … to those items in the STATED order (isEvent: false; these are plan tasks, not events).
    - Items NOT part of a stated order get sequenceIndex null.
    - CAPTURE-FIRST: every item in the plan MUST be saved in new_tasks. Never drop or merely ask about an item — even if a duration or detail is fuzzy, save it now (you may still ask a follow-up in "message"). A previous bug dropped an item that was only asked about; do not repeat that.
    - Stated durations ("for an hour", "30 min") still go in estimatedMinutes. Do NOT set dueDate/dueTime from a plan's order — a plan is an ordered list, not a timed schedule.
    - When you capture a plan, your "message" MUST render it back as a numbered list so the user sees the order, e.g. "Got it — here's your plan: 1. Gym  2. CVS  3. Shower + breakfast  4. Python (1h)". Plain text is fine.

    task_updates format (for updating existing tasks by id):
    {"id": "uuid-string", "estimatedMinutes": 60, "priority": "high", "dueDate": "YYYY-MM-DD"}
    Only include fields that changed. The "id" field is required.

    Example — floater tasks (no date / no time → priority "low", no dueDate):
    {
      "message": "Added study spanish and do laundry to your floaters — get to them when you can.",
      "new_tasks": [
        {"title": "Study Spanish", "isEvent": false, "priority": "low", "category": "school"},
        {"title": "Do laundry", "isEvent": false, "priority": "low", "category": "personal"}
      ],
      "task_updates": []
    }

    Example — user mentions a work shift (EVENT):
    {
      "message": "Got your work shift in — see you tomorrow at 4 PM.",
      "new_tasks": [
        {"title": "Work", "isEvent": true, "priority": "medium", "category": "work", "dueDate": "2026-05-25", "dueTime": "4:00 PM"}
      ],
      "task_updates": []
    }

    Example — user mentions class (EVENT) AND an assignment (TASK):
    {
      "message": "Locked in class at 9 AM tomorrow and added the essay to your tasks.",
      "new_tasks": [
        {"title": "Bio 101 lecture", "isEvent": true, "priority": "medium", "category": "school", "dueDate": "2026-05-25", "dueTime": "9:00 AM"},
        {"title": "Finish essay", "isEvent": false, "priority": "high", "category": "school"}
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

    private let prepPlanSystemPrompt = """
    You are Nudge's prep planner. Given an upcoming important event (exam, deadline,
    presentation, etc.), generate a multi-day preparation plan.

    Rules:
    - Spread prep work across the days leading up to the event
    - Earlier days: lighter review. Later days: intensive practice
    - Each prep block should be 30-90 minutes
    - Include variety (reading, practice problems, review notes, etc.)
    - Return ONLY valid JSON

    Return format:
    {
      "message": "I've created a 5-day study plan for your exam!",
      "prep_blocks": [
        {
          "dayOffset": -5,
          "title": "Review Chapter 1-3 notes",
          "estimatedMinutes": 60,
          "category": "school",
          "notes": "Light review to refresh memory"
        }
      ]
    }
    """

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
        existingTasks: [ExistingTaskContext] = []
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

        var fullSystemPrompt = chatSystemPrompt + """


        ===== DATE & TIME CONTEXT =====
        Today's date is \(todayString) (\(todayISO)).
        The CURRENT LOCAL CLOCK TIME is \(nowClock12) (24h: \(nowClock24)).
        Tomorrow's date is \(tomorrowISO).

        Mapping rules:
        - "today" → dueDate = \(todayISO)
        - "tomorrow" → dueDate = \(tomorrowISO)
        - "tonight" → dueDate = \(todayISO), dueTime in the evening (after 6 PM)
        - "in N hours" / "in N hrs" → dueDate = \(todayISO), dueTime = (\(nowClock12) + N hours). Compute carefully — if the result crosses midnight, roll dueDate to \(tomorrowISO).
        - "in N minutes" / "in N min" → dueDate = \(todayISO), dueTime = (\(nowClock12) + N minutes). Same midnight-rollover rule.
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

            fullSystemPrompt += """

            
            ===== THE USER'S CURRENT TASK LIST =====
            These tasks are ALREADY in the app. Do NOT put any of these in new_tasks.
            If the user mentions any of these, use task_updates with the matching id.
            If a task below has estimatedMinutes set, DO NOT ask about duration.
            [\n\(taskEntries)\n]
            =========================================
            """
        }

        var messages: [[String: String]] = conversationHistory.map { msg in
            ["role": msg.role, "content": msg.content]
        }
        messages.append(["role": "user", "content": userMessage])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "system": fullSystemPrompt,
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

    // MARK: - Feature 4: Multi-Day Prep Plan Generation

    /// Generate a multi-day preparation plan for an upcoming important event.
    ///
    // ── CLAUDE API INTEGRATION ──────────────────────────────────────
    // Endpoint: POST https://api.anthropic.com/v1/messages
    // Model: claude-haiku-4-5-20251001
    // Pass: event { title, date }, existingTasks[], userSchedulePreferences
    // System prompt: prepPlanSystemPrompt (defined above)
    // Expected return: PrepPlanResponse { message, prep_blocks[] }
    // ────────────────────────────────────────────────────────────────
    func generatePrepPlan(
        eventTitle: String,
        eventDate: Date,
        existingTaskTitles: [String],
        wakeTime: Date,
        bedtime: Date
    ) async throws -> PrepPlanResponse {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"

        let daysUntil = Calendar.current.dateComponents([.day], from: Date(), to: eventDate).day ?? 0

        let prompt = """
        Generate a multi-day prep plan for this upcoming event:
        Event: "\(eventTitle)"
        Date: \(eventDate.formatted(date: .abbreviated, time: .omitted)) (\(daysUntil) days away)
        User wake time: \(timeFormatter.string(from: wakeTime))
        User bedtime: \(timeFormatter.string(from: bedtime))
        Existing tasks (avoid conflicts): \(existingTaskTitles)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": prepPlanSystemPrompt,
            "messages": [["role": "user", "content": prompt]]
        ]

        // ── STUB: Replace with real API call ──
        #if DEBUG
        print("[ClaudeService] generatePrepPlan stub called for '\(eventTitle)' in \(daysUntil) days")
        #endif

        return try await makePrepPlanRequest(body: body)
    }

    // MARK: - Feature 5: Screenshot Calendar Parsing

    /// Reads raw OCR text from a calendar screenshot and asks the model to
    /// emit structured events as JSON. Strict schema; expects ISO 8601
    /// datetimes anchored against today's date.
    func parseScheduleScreenshot(
        ocrText: String,
        defaultCategory: String
    ) async throws -> [ParsedScreenshotEvent] {
        let todayISO = Self.todayISO()
        let humanDate = DateFormatter.fullWeekday.string(from: Date())

        let prompt = """
        I extracted this raw text from a screenshot of someone's schedule using OCR. Convert it into structured events. Be GENEROUS — if a line could plausibly be an event, include it. The user is trying to import a real schedule and missing events is worse than including a bad one.

        Return ONLY a JSON array. No prose, no markdown fences. Schema:
        [
          {
            "title": "<short event name>",
            "startISO": "<datetime, format YYYY-MM-DDTHH:MM:SS, LOCAL TIME, no timezone suffix>",
            "durationMinutes": <int or null>,
            "category": "exam" | "school" | "work" | "health" | "personal" | "errand" | "other" | null
          }
        ]

        Rules:
        - Today is \(humanDate) (\(todayISO)). Anchor dates relative to today.
        - DATE FORMAT: Use "YYYY-MM-DDTHH:MM:SS" (e.g. "2026-06-03T09:00:00"). NO timezone, NO "Z", NO offset. We treat them as the user's local time.
        - For dates shown like "Mon 6/3" or "Mon, Jun 3", figure out the correct full date based on today. Prefer dates in the future or current week.
        - For shift ranges like "9:00 AM - 5:00 PM" or "9a-5p", set startISO to the start time and durationMinutes to total minutes (e.g. 480 for 8 hours).
        - For class schedules like "MATH 220 MWF 10:00 AM", emit one event per implied day across the next 7 days at that time.
        - When in doubt about whether something is an event vs. UI text, INCLUDE IT. The user can delete bad ones.
        - Default category to "\(defaultCategory)" when unsure.
        - Only return [] if there is genuinely zero date/time information anywhere in the text.

        OCR TEXT:
        \"\"\"
        \(ocrText)
        \"\"\"
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "system": "You are a precise data extractor. Return only valid JSON matching the requested schema. No prose, no commentary.",
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
                category: json.category
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
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let resp = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = resp.content.first?.text else {
            throw ClaudeError.emptyResponse
        }
        return try parseResponse(text)
    }

    private func makePrepPlanRequest(body: [String: Any]) async throws -> PrepPlanResponse {
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validateResponse(data: data, response: response)
        let resp = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = resp.content.first?.text else {
            throw ClaudeError.emptyResponse
        }
        return try parsePrepPlanResponse(text)
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
        return try JSONDecoder().decode(ClaudeResponse.self, from: d)
    }

    private func parsePrepPlanResponse(_ text: String) throws -> PrepPlanResponse {
        let cleaned = normalizedJSONPayload(from: text)
        guard let d = cleaned.data(using: .utf8) else {
            throw ClaudeError.parseError
        }
        return try JSONDecoder().decode(PrepPlanResponse.self, from: d)
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

    struct ContentBlock: Codable {
        let text: String
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

struct ClaudeResponse: Codable {
    let message: String
    let taskUpdates: [TaskUpdate]?
    let newTasks: [TaskData]?
    let settingsUpdates: [String: String]?

    enum CodingKeys: String, CodingKey {
        case message
        case taskUpdates = "task_updates"
        case newTasks = "new_tasks"
        case settingsUpdates = "settings_updates"
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
    let priority: String?
    let category: String?
    let estimatedMinutes: Int?
    let recurrence: String?
    let dependsOnTask: String?      // title of the task this depends on (resolved client-side)
    let sequenceIndex: Int?         // 1-based order when the user states a plan ("first X, then Y")

    enum CodingKeys: String, CodingKey {
        case title
        case isEvent = "isEvent"
        case dueDate = "dueDate"
        case dueTime = "dueTime"
        case priority
        case category
        case estimatedMinutes = "estimatedMinutes"
        case recurrence
        case dependsOnTask = "depends_on_task"
        case sequenceIndex = "sequenceIndex"
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
}

// MARK: - Feature 4 Response Types (Prep Plan)

struct PrepPlanResponse: Codable {
    let message: String
    let prepBlocks: [PrepBlockData]

    enum CodingKeys: String, CodingKey {
        case message
        case prepBlocks = "prep_blocks"
    }
}

struct PrepBlockData: Codable {
    let dayOffset: Int              // negative = days before event (e.g. -5 = 5 days before)
    let title: String
    let estimatedMinutes: Int
    let category: String
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case dayOffset = "dayOffset"
        case title
        case estimatedMinutes = "estimatedMinutes"
        case category
        case notes
    }
}

// MARK: - Screenshot Calendar DTO

private struct ScreenshotEventJSON: Codable {
    let title: String
    let startISO: String
    let durationMinutes: Int?
    let category: String?
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
