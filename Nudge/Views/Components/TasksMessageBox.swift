//
//  TasksMessageBox.swift
//  Nudge
//
//  The read-only message surface at the top of the Tasks tab — the app's
//  only place to SPEAK. Every other surface either takes input or shows
//  data; this one explains. Deliberately display-only: no field, no send
//  button, no keyboard — Home owns capture, and a second capture path
//  doubles where a capture bug can live.
//
//  Content is DETERMINISTIC — composed from data the app already has, no
//  ClaudeService call — so the box works offline and with no API key
//  (DESIGN.md: AI at the edges, deterministic in the core).
//

import SwiftUI

// MARK: - Message model

/// What the box says: a headline that always fits collapsed, plus optional
/// detail revealed on tap.
struct TasksMessage: Equatable {
    let headline: String
    let detail: String?
}

/// "The user tapped a nudge and landed here" — read from the app-group keys
/// `NudgeNotificationService` writes on a notification body tap. The same
/// durable-intent pattern as the idle "Not yet" keys (a transient post dies
/// on cold launch because this view isn't mounted yet; App Group defaults
/// survive any launch path), with one deliberate difference: the idle keys
/// are consumed one-shot because they drive a modal sheet, where this
/// context is passive display and stays readable for its whole freshness
/// window (`NudgeConfig.messageBoxTapContextMinutes`), then expires by age.
struct TappedNudgeContext {
    let kind: NudgeOutcomeKind
    let taskID: UUID?
    let tappedAt: Date

    /// Reads the context from the app group; returns nil (and tidies the
    /// keys) once it has gone stale.
    static func read(now: Date = Date()) -> TappedNudgeContext? {
        let defaults = SharedModelContainer.appGroupDefaults
        guard
            let kindRaw = defaults.string(forKey: NudgeNotificationService.tappedNudgeKindKey),
            let kind = NudgeOutcomeKind(rawValue: kindRaw),
            let tappedAt = defaults.object(forKey: NudgeNotificationService.tappedNudgeDateKey) as? Date
        else { return nil }

        let ageMinutes = now.timeIntervalSince(tappedAt) / 60
        guard ageMinutes >= 0, ageMinutes <= Double(NudgeConfig.messageBoxTapContextMinutes) else {
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeKindKey)
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeTaskIDKey)
            defaults.removeObject(forKey: NudgeNotificationService.tappedNudgeDateKey)
            return nil
        }
        let taskID = defaults.string(forKey: NudgeNotificationService.tappedNudgeTaskIDKey)
            .flatMap(UUID.init(uuidString:))
        return TappedNudgeContext(kind: kind, taskID: taskID, tappedAt: tappedAt)
    }
}

/// The most recent Plan-my-day outcome from today — written by the planner
/// (button now, morning auto-run when it exists), read back on the same
/// App-Group-defaults pattern as `TappedNudgeContext`. Exists so no planner
/// run can end silently: a refusal ("nothing to plan", "no room") is
/// correct behavior, but correct-and-mute reads as a dead button (cycle
/// 2026-08-02-01's diagnosis). Valid for the day it was written; a manual
/// successful plan clears it (the placements ARE the feedback).
struct PlanOutcomeContext {
    enum Kind: String {
        /// Tasks were placed by an automatic run — announce what happened.
        case planned
        /// Nothing open and unplaced to work with — a correct refusal.
        case noCandidates
        /// Candidates exist but no free gap fits any of them.
        case noRoom
        /// The planning window was empty (late-night tap, or a profile
        /// whose sleep window is shorter than its quiet buffers). Backstop
        /// — the wake-anchored `DayWindow` makes the all-day version of
        /// this impossible on sane profiles.
        case windowCollapsed
    }

    let kind: Kind
    let placedCount: Int
    let placedTitles: [String]
    /// Auto placements evicted back to Unscheduled to fit a generated
    /// session (item 4) — the announcement must name them; a silent
    /// un-placement is the vanishing-task shape.
    let displacedTitles: [String]
    /// The generated session an eviction WOULD have fit, except every
    /// helpful candidate was equal-or-higher stakes — reported instead of
    /// evicted (the app proposes, the user decides). `noRoom` only.
    let contentionTitle: String?
    let isAuto: Bool
    let date: Date

    static let kindKey = "nudge.planOutcome.kind"
    static let countKey = "nudge.planOutcome.count"
    static let titlesKey = "nudge.planOutcome.titles"
    static let displacedKey = "nudge.planOutcome.displaced"
    static let contentionKey = "nudge.planOutcome.contention"
    static let autoKey = "nudge.planOutcome.auto"
    static let dateKey = "nudge.planOutcome.date"

    static func write(
        kind: Kind,
        placedCount: Int = 0,
        placedTitles: [String] = [],
        displacedTitles: [String] = [],
        contentionTitle: String? = nil,
        isAuto: Bool
    ) {
        let defaults = SharedModelContainer.appGroupDefaults
        defaults.set(kind.rawValue, forKey: kindKey)
        defaults.set(placedCount, forKey: countKey)
        defaults.set(placedTitles, forKey: titlesKey)
        defaults.set(displacedTitles, forKey: displacedKey)
        if let contentionTitle {
            defaults.set(contentionTitle, forKey: contentionKey)
        } else {
            defaults.removeObject(forKey: contentionKey)
        }
        defaults.set(isAuto, forKey: autoKey)
        defaults.set(Date(), forKey: dateKey)
    }

    static func clear() {
        let defaults = SharedModelContainer.appGroupDefaults
        for key in [kindKey, countKey, titlesKey, displacedKey, contentionKey, autoKey, dateKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Today's outcome, or nil (tidying the keys) once it's from a past day.
    static func read(now: Date = Date()) -> PlanOutcomeContext? {
        let defaults = SharedModelContainer.appGroupDefaults
        guard
            let kindRaw = defaults.string(forKey: kindKey),
            let kind = Kind(rawValue: kindRaw),
            let date = defaults.object(forKey: dateKey) as? Date
        else { return nil }
        guard Calendar.current.isDate(date, inSameDayAs: now) else {
            clear()
            return nil
        }
        return PlanOutcomeContext(
            kind: kind,
            placedCount: defaults.integer(forKey: countKey),
            placedTitles: (defaults.array(forKey: titlesKey) as? [String]) ?? [],
            displacedTitles: (defaults.array(forKey: displacedKey) as? [String]) ?? [],
            contentionTitle: defaults.string(forKey: contentionKey),
            isAuto: defaults.bool(forKey: autoKey),
            date: date
        )
    }
}

// MARK: - Composer (pure)

/// Deterministic message selection. Priority order — first state that
/// applies wins:
///   1. a nudge was just tapped (explain it beyond the 60-char banner)
///   2. something is overdue (name it and by how long)
///   3. something high-stakes is approaching (name it and days remaining)
///   4. a study task was deleted — the one-time "still want study time
///      for that exam?" note (cycle 2026-08-01-03; per exam, never
///      repeats — see `PrepTombstone.noteShownAt`)
///   5. the exam-prep sweep just created study tasks — the announcement
///      (same cycle; silent creation is not acceptable per DESIGN.md)
///   6. the AI Refine rationale — stable all-day context
///   7. resting — a plain line about the day. NEVER blank: an empty box at
///      the top of the most-used tab is dead space.
///
/// The two prep states sit below the overdue/high-stakes facts (the day's
/// actionable facts outrank meta-news about the list) and above the
/// rationale (news beats stable context). A question the user should
/// settle (the note) outranks an announcement about work already visible
/// on the list below.
///
/// Tone is where DESIGN.md bites hardest: state facts. No verdict on the
/// user, no promised outcome, no implied failure for missed work.
enum TasksMessageComposer {
    static func compose(
        tasks: [NudgeTask],
        tappedNudge: TappedNudgeContext?,
        rationale: String? = nil,
        aiMessage: TasksMessage? = nil,
        prepNote: PrepNoteContext? = nil,
        prepAnnouncement: PrepAnnouncementContext? = nil,
        commitmentAnnouncement: CommitmentAnnouncementContext? = nil,
        planOutcome: PlanOutcomeContext? = nil,
        now: Date
    ) -> TasksMessage {
        // ── AI SEAM (unused as of Aug 2026) ─────────────────────────────
        // An AI-written message takes precedence over every deterministic
        // state below. Nothing produces one yet — no call, no flag. The
        // future cycle that plugs `ClaudeService` in only has to build a
        // `TasksMessage` and pass it here; the states below then serve as
        // the fallback whenever it's absent (offline, no key, error), which
        // is what keeps this surface safe to make non-deterministic.
        if let aiMessage {
            return aiMessage
        }

        let open = tasks.filter { !$0.isComplete && !$0.isInformationalEvent }

        // 1 — a nudge was just tapped.
        if let context = tappedNudge {
            return nudgeExplanation(context: context, tasks: tasks)
        }

        // 2 — something is overdue.
        let overdue = open.filter(\.isOverdue).sorted { $0.sortDeadline < $1.sortDeadline }
        if let first = overdue.first {
            let ago = CountdownState.remainingLine(dueDate: first.sortDeadline, now: now) ?? "earlier"
            let others = overdue.dropFirst()
            let detail: String? = others.isEmpty ? nil : {
                let lines = others.prefix(3).map { task -> String in
                    let when = CountdownState.remainingLine(dueDate: task.sortDeadline, now: now) ?? "earlier"
                    return "“\(task.title)” (\(when))"
                }
                let more = others.count > 3 ? " and \(others.count - 3) more" : ""
                return "Also past due: " + lines.joined(separator: ", ") + more + "."
            }()
            return TasksMessage(
                headline: "“\(first.title)” was due \(ago).",
                detail: detail
            )
        }

        // 3 — something high-stakes is approaching.
        let calendar = Calendar.current
        let approaching = open
            .filter { $0.stakes == .high && $0.sortDeadline > now }
            .filter { task in
                let days = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: now),
                    to: calendar.startOfDay(for: task.sortDeadline)
                ).day ?? .max
                return days <= NudgeConfig.messageBoxHighStakesHorizonDays
            }
            .sorted { $0.sortDeadline < $1.sortDeadline }
        if let task = approaching.first {
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: task.sortDeadline)
            ).day ?? 0
            let when = days == 0 ? "due today" : (days == 1 ? "1 day away" : "\(days) days away")
            let dueLine = CountdownState.dueDateLine(
                dueDate: task.dueDate, specificTime: task.specificTime
            )
            return TasksMessage(
                headline: "“\(task.title)” is \(when).",
                detail: dueLine.map { "It's marked high stakes — due \($0)." }
                    ?? "It's marked high stakes."
            )
        }

        // 4 — a study task was deleted: ask once whether they still want
        // study time for that exam. Factual, no guilt — deleting was a
        // decision and it stands (the sweep never recreates that day);
        // this just makes sure it was a decision, not an accident.
        if let prepNote {
            return prepNoteMessage(examTitle: prepNote.examTitle, isCommitment: prepNote.isCommitment)
        }

        // 5 — the sweep created study tasks: say so. The user should never
        // discover work on their list they can't account for.
        if let prepAnnouncement {
            return prepAnnouncementMessage(
                examTitle: prepAnnouncement.examTitle,
                daysUntil: prepAnnouncement.daysUntil
            )
        }

        // 5.2 — a commitment was expanded into daily tasks: same rule,
        // same slot (news about generated work, below the day's actionable
        // facts). The two announcements have separate storage so a same-
        // morning exam sweep can't overwrite this; whichever survives its
        // own freshness window renders on later recomposes.
        if let commitmentAnnouncement {
            return commitmentAnnouncementMessage(commitmentAnnouncement)
        }

        // 5.5 — today's Plan-my-day outcome (cycle 2026-08-02-02: a planner
        // run must never end mute). Below the day's actionable facts and
        // the one-time prep states, above the stable rationale and resting.
        // Facts only, per DESIGN.md — a refusal states what IS, never a
        // verdict on the user.
        if let planOutcome, let message = planOutcomeMessage(planOutcome) {
            return message
        }

        // 6 — the AI Refine rationale (Aug 2026 — folded in
        // from the banner that used to render separately, so the tab has
        // one voice in one place). Sits BELOW overdue and high-stakes on
        // purpose: those are the day's actionable facts, while the
        // rationale is stable all-day context whose visible result — the
        // placements — already shows on the timeline. In the common
        // just-refined case (day freshly planned, nothing overdue pressing)
        // it surfaces immediately anyway.
        if let rationale, !rationale.trimmingCharacters(in: .whitespaces).isEmpty {
            return TasksMessage(
                headline: "Here's the thinking behind today's plan.",
                detail: rationale
            )
        }

        // 7 — resting. Never blank.
        return restingMessage(open: open, allTasks: tasks, now: now)
    }

    // MARK: Exam-prep states

    /// Built as standalone statics (not inline in `compose`) so the view
    /// can compare the composed message against them by equality — that
    /// comparison is how it knows the state actually RENDERED, which is
    /// what starts the note's never-repeat clock and the announcement's
    /// freshness window.

    static func prepNoteMessage(examTitle: String, isCommitment: Bool = false) -> TasksMessage {
        if isCommitment {
            return TasksMessage(
                headline: "Do you still want daily time for “\(examTitle)”?",
                detail: "A day's task for it was removed — that day won't be re-added. "
                    + "The other days are still on your list; delete them too "
                    + "if you'd rather drop it."
            )
        }
        return TasksMessage(
            headline: "Do you still want study time for “\(examTitle)”?",
            detail: "A study task for it was removed — that day won't be re-added. "
                + "Any other study days are still on your list; delete them too "
                + "if you'd rather plan it yourself."
        )
    }

    static func prepAnnouncementMessage(examTitle: String, daysUntil: Int) -> TasksMessage {
        let when = daysUntil == 1 ? "tomorrow" : "in \(daysUntil) days"
        let span = daysUntil == 1 ? "for today" : "each day until then"
        return TasksMessage(
            headline: "Your “\(examTitle)” is \(when) — I've added study time \(span).",
            detail: "One study task per day, through the day before. "
                + "Delete any you don't want — removed days stay removed."
        )
    }

    static func commitmentAnnouncementMessage(_ context: CommitmentAnnouncementContext) -> TasksMessage {
        // "daysUntilEnd" counts from today to the LAST generated day —
        // 0 = today only. When the series starts tomorrow (the user's
        // answer, or a captured-too-late-today default), say so.
        let span: String
        if context.startsTomorrow {
            span = context.daysUntilEnd <= 1
                ? "for tomorrow"
                : "from tomorrow through the next \(context.daysUntilEnd) days"
        } else {
            switch context.daysUntilEnd {
            case 0:  span = "for today"
            case 1:  span = "for today and tomorrow"
            default: span = "for the next \(context.daysUntilEnd + 1) days"
            }
        }
        let perDay: String
        if let minutes = context.dailyMinutes {
            perDay = "\(durationPhrase(minutes: minutes)) a day"
        } else if let count = context.dailyCount {
            perDay = "\(count) a day"
        } else {
            perDay = "one task a day"
        }
        return TasksMessage(
            headline: "“\(context.title)” is set up \(span) — \(perDay).",
            detail: "One task per day, on your list and ready to place. "
                + "Delete any day you don't want — removed days stay removed."
        )
    }

    /// "60" → "an hour", "90" → "1.5 hours", "30" → "30 minutes".
    private static func durationPhrase(minutes: Int) -> String {
        if minutes == 60 { return "an hour" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        if minutes > 60 {
            let hours = Double(minutes) / 60
            return String(format: "%g hours", hours)
        }
        return "\(minutes) minutes"
    }

    // MARK: Plan-outcome state

    /// The message for today's planner outcome, or nil when this outcome
    /// kind has nothing to say (a manual success — the placements on the
    /// timeline are the feedback; narrating them would be noise).
    private static func planOutcomeMessage(_ outcome: PlanOutcomeContext) -> TasksMessage? {
        switch outcome.kind {
        case .planned:
            // Only an automatic run announces itself — the user didn't ask,
            // so the plan explains where it came from. (Manual successes
            // clear the context before this can render; the guard is a
            // backstop.)
            guard outcome.isAuto, outcome.placedCount > 0 else { return nil }
            let titles = outcome.placedTitles.prefix(4)
                .map { "“\($0)”" }.joined(separator: ", ")
            let displaced = outcome.displacedTitles.isEmpty
                ? ""
                : " To make room, "
                    + outcome.displacedTitles.map { "“\($0)”" }.joined(separator: " and ")
                    + " went back to Unscheduled — re-place it wherever suits you."
            return TasksMessage(
                headline: "I set up today — \(outcome.placedCount) task\(outcome.placedCount == 1 ? "" : "s") placed into free time.",
                detail: "Placed: \(titles). Tap any timeline block to move or remove it — "
                    + "placements you made yourself weren't touched." + displaced
            )
        case .noCandidates:
            return TasksMessage(
                headline: "Nothing to plan right now.",
                detail: "Everything open is either finished or already on today's timeline."
            )
        case .noRoom:
            // Equal-stakes contention (item 4): a session would fit if
            // something placed moved, but nothing placed matters less than
            // it does. The app proposes, the user decides — name the
            // contention, evict nothing.
            if let contention = outcome.contentionTitle {
                return TasksMessage(
                    headline: "Today is full — “\(contention)” didn't fit.",
                    detail: "Everything placed today matters as much as it does, so nothing was moved. "
                        + "If you want it today, move or remove a timeline block and it can take that spot."
                )
            }
            return TasksMessage(
                headline: "No room left today — your calendar is full.",
                detail: "Events, the buffers around them, and existing placements take the rest of today. "
                    + "Unplaced tasks stay in the Unscheduled tab."
            )
        case .windowCollapsed:
            return TasksMessage(
                headline: "No planning window left today.",
                detail: "Planning runs between wake (+30 min) and bedtime (−1 hour). "
                    + "If this shows during the day, check your wake time and bedtime in Settings."
            )
        }
    }

    // MARK: Tapped-nudge explanations

    /// Per-kind explanation of the nudge the user just tapped — more room
    /// than a banner, still just facts about why it fired.
    private static func nudgeExplanation(
        context: TappedNudgeContext,
        tasks: [NudgeTask]
    ) -> TasksMessage {
        let task = context.taskID.flatMap { id in tasks.first(where: { $0.id == id }) }

        switch context.kind {
        case .eventBlock:
            return TasksMessage(
                headline: "That was a heads-up before your next block of events.",
                detail: "Event reminders go out about an hour before a stretch of calendar events begins, so the first one doesn't start without you."
            )
        case .idle:
            return TasksMessage(
                headline: "That check-in asks whether today has gotten started.",
                detail: "It goes out a few hours after wake when no session has been started and nothing has been checked off yet."
            )
        // `.getAhead` survives for rows written before the Aug 2026 split;
        // `.prep` is its direct descendant and shares the explanation.
        case .getAhead, .prep:
            if let task {
                let dueLine = CountdownState.dueDateLine(
                    dueDate: task.dueDate, specificTime: task.specificTime
                )
                return TasksMessage(
                    headline: "That nudge was about “\(task.title).”",
                    detail: "It fires when starting now still leaves room before the deadline"
                        + (dueLine.map { " — “\(task.title)” is due \($0)." } ?? ".")
                )
            }
            return TasksMessage(
                headline: "That nudge was about getting ahead of a deadline.",
                detail: "It fires when starting now still leaves room before a task's due date."
            )
        case .dueSoon:
            if let task {
                let dueLine = CountdownState.dueDateLine(
                    dueDate: task.dueDate, specificTime: task.specificTime
                )
                return TasksMessage(
                    headline: "That was a heads-up that a deadline is close.",
                    detail: "Due-soon reminders go out about two hours before something is due"
                        + (dueLine.map { " — “\(task.title)” is due \($0)." } ?? ".")
                )
            }
            return TasksMessage(
                headline: "That was a heads-up that a deadline is close.",
                detail: "Due-soon reminders go out about two hours before something is due. Things due within the same hour share one reminder."
            )
        case .floater:
            if let task {
                return TasksMessage(
                    headline: "That check-in was about “\(task.title),” which has no deadline.",
                    detail: "Undated tasks never turn urgent on their own, so the check-in points one out when the day has room."
                )
            }
            return TasksMessage(
                headline: "That check-in was about an open task with no deadline.",
                detail: "Undated tasks never turn urgent on their own, so the check-in points one out when the day has room."
            )
        case .morningPrompt:
            // Morning-prompt taps land in Home chat, not here — but the kind
            // is handled so a routing change can't leave the box speechless.
            return TasksMessage(
                headline: "That was the morning check-in.",
                detail: "It names the biggest thing on your list as the day starts."
            )
        case .comeBack:
            // Forward-looking here too: explain what the nudge points at,
            // never the quiet days that preceded it (DESIGN.md never-shame).
            return TasksMessage(
                headline: "That was a look at what's coming up.",
                detail: "It points out the next thing on your calendar or list. Everything here is where you left it."
            )
        }
    }

    // MARK: Resting state

    private static func restingMessage(
        open: [NudgeTask],
        allTasks: [NudgeTask],
        now: Date
    ) -> TasksMessage {
        let calendar = Calendar.current
        let eventsToday = allTasks.filter { task in
            guard task.isInformationalEvent, !task.isComplete,
                  let start = task.specificTime else { return false }
            return calendar.isDate(start, inSameDayAs: now)
        }

        guard !open.isEmpty else {
            let detail = eventsToday.isEmpty
                ? nil
                : "\(eventsToday.count) event\(eventsToday.count == 1 ? "" : "s") on the calendar today."
            return TasksMessage(headline: "Your list is clear right now.", detail: detail)
        }

        let comparator = TaskSortComparator()
        let next = open.min { comparator.compare($0, $1) }
        let dueToday = open.filter { task in
            task.sortDeadline != .distantFuture
                && calendar.isDate(task.sortDeadline, inSameDayAs: now)
        }

        var parts: [String] = []
        if !dueToday.isEmpty {
            parts.append("Due today: \(dueToday.count).")
        } else {
            parts.append("Nothing due today.")
        }
        if !eventsToday.isEmpty {
            parts.append("\(eventsToday.count) event\(eventsToday.count == 1 ? "" : "s") on the calendar.")
        }

        let headline: String
        if let next {
            headline = "\(open.count) task\(open.count == 1 ? "" : "s") open. Next up: “\(next.title).”"
        } else {
            headline = "\(open.count) task\(open.count == 1 ? "" : "s") open."
        }
        return TasksMessage(headline: headline, detail: parts.joined(separator: " "))
    }
}

// MARK: - Character slot

/// What face the character wears (cycle 2026-08-03-05). Three cases on
/// purpose — every case is art someone has to draw:
///   • `neutral` — the resting face; the collapsed box and idle shell.
///   • `asking`  — a question is on the table (the shell's whole reason
///     to exist; the one state that must read differently at a glance).
///   • `pleased` — an answer just landed; the acknowledgment beat.
/// Deliberately NO worried/disappointed case: a character that looks
/// concerned about the user's list is `DESIGN.md`'s never-shame rule
/// violated in art instead of copy.
enum MessageBoxExpression: String, CaseIterable {
    case neutral
    case asking
    case pleased

    /// THE mapping — the one place real art lands later. All nil for now
    /// (grey placeholder); when assets exist this becomes
    /// `Image("pigeon-\(rawValue)")` and no call site changes.
    var image: Image? {
        switch self {
        case .neutral: return nil
        case .asking:  return nil
        case .pleased: return nil
        }
    }
}

/// The square on the box's left where a character lands — a messenger
/// pigeon, eventually one per surface. 56×56: exactly twice the task row's
/// 28pt leading checkbox, big enough for an illustration to read as a
/// character rather than an icon. The box's minimum height follows from
/// this (slot + vertical padding) — the deliberate break from task-row
/// height; the box is the app's voice, not a list item. Until an asset
/// exists it renders a plain grey placeholder from the theme.
///
/// Takes an EXPRESSION, not an image (cycle 2026-08-03-05): call sites
/// say what the character feels; `MessageBoxExpression.image` is the one
/// mapping from feeling to art.
struct MessageBoxCharacterSlot: View {
    var expression: MessageBoxExpression = .neutral

    var body: some View {
        Group {
            if let image = expression.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(NudgeTheme.textPlaceholder)
            }
        }
        .frame(width: 56, height: 56)
    }
}

// MARK: - View

/// The app speaking as a row IN the list, not a banner above it — same
/// footprint as a task row (padding, corner radius, the shared horizontal
/// insets), with one difference carrying the distinction: a task row is a
/// FILLED card, this is an OUTLINED one (`NudgeTheme.border`, no fill).
///
/// Height: the 56pt character slot sets the floor (~88pt with padding —
/// about 1.3× a task row; the box stopped matching row height when the
/// character moved in). Collapsed, the headline still truncates at two
/// lines. Expanding GROWS the row in place (same width, same corners) to
/// the full headline plus detail; tap again to collapse back.
struct TasksMessageBox: View {
    let tasks: [NudgeTask]
    let tappedNudge: TappedNudgeContext?
    /// Opens the interactive shell (cycle 2026-08-03-04; one surface, TWO
    /// ways in since -05: the character AND the row/chevron both land
    /// here). The composed message rides along so the shell can seed its
    /// dialogue with what the box was actually saying — the in-place
    /// detail expansion is superseded by the shell when this is set, so
    /// the detail must stay reachable through it. Nil (the default) keeps
    /// the legacy in-place expand/collapse — callers that never opted in
    /// behave exactly as before.
    var onOpenShell: ((TasksMessage) -> Void)? = nil
    var rationale: String? = nil
    /// One-time "still want study time for X?" note (tombstone-backed).
    var prepNote: PrepNoteContext? = nil
    /// "I've added study time" announcement from the exam-prep sweep.
    var prepAnnouncement: PrepAnnouncementContext? = nil
    /// "This commitment is set up" announcement from the commitment
    /// expansion (same sweep, own storage slot).
    var commitmentAnnouncement: CommitmentAnnouncementContext? = nil
    /// Today's planner outcome (refusals + the auto-plan announcement).
    var planOutcome: PlanOutcomeContext? = nil
    /// Fired when the note state actually RENDERS (not merely exists) —
    /// the owner stamps `PrepTombstone.noteShownAt`, which is what makes
    /// the note one-time. A passive display can't know it was read;
    /// rendering is the honest proxy.
    var onPrepNoteShown: (() -> Void)? = nil
    /// Same, for the announcement — starts its freshness window.
    var onPrepAnnouncementShown: (() -> Void)? = nil
    /// Same, for the commitment announcement.
    var onCommitmentAnnouncementShown: (() -> Void)? = nil

    @State private var isExpanded = false

    /// Shared 60s tick — freshness of the tapped-nudge context and the
    /// overdue/approaching arithmetic follow the same clock every countdown
    /// label uses. Computed, not stored, so the memberwise init stays
    /// internal.
    private var clock: CountdownClock { CountdownClock.shared }

    var body: some View {
        let message = TasksMessageComposer.compose(
            tasks: tasks,
            tappedNudge: tappedNudge,
            rationale: rationale,
            prepNote: prepNote,
            prepAnnouncement: prepAnnouncement,
            commitmentAnnouncement: commitmentAnnouncement,
            planOutcome: planOutcome,
            now: clock.now
        )
        let expandable = message.detail != nil

        HStack(alignment: .center, spacing: 14) {
            MessageBoxCharacterSlot()

            VStack(alignment: .leading, spacing: 5) {
                Text(message.headline)
                    .font(.custom(NudgeTheme.fontMedium, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                if isExpanded, let detail = message.detail {
                    Text(detail)
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)

            // Visibility rule unchanged from today (collapsed state must
            // show what it shows today) — the chevron appears only when
            // there's detail; what changed is where it LEADS.
            if expandable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(16)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .onTapGesture {
            // One surface, two ways in (cycle 2026-08-03-05): with a shell
            // wired, character, chevron, and row all open it — the shell
            // carries the detail the in-place expansion used to show.
            // Without one, the legacy in-place expansion stands.
            if let onOpenShell {
                NudgeHaptics.light()
                onOpenShell(message)
                return
            }
            guard expandable else { return }
            NudgeHaptics.light()
            withAnimation(NudgeAnimation.standard) {
                isExpanded.toggle()
            }
        }
        .animation(NudgeAnimation.standard, value: message)
        // Render-detection for the two exam-prep states: the callbacks
        // must fire only when the state actually WON the composer's
        // priority contest, not merely because a pending note exists —
        // an overdue task can preempt the note for days, and it must
        // still show later. Equality against the states' own builders is
        // what makes "did it render" checkable.
        .onAppear { reportPrepDisplays(message) }
        .onChange(of: message) { _, newMessage in
            reportPrepDisplays(newMessage)
        }
    }

    private func reportPrepDisplays(_ message: TasksMessage) {
        if let prepNote,
           message == TasksMessageComposer.prepNoteMessage(
               examTitle: prepNote.examTitle,
               isCommitment: prepNote.isCommitment
           ) {
            onPrepNoteShown?()
        }
        if let prepAnnouncement,
           message == TasksMessageComposer.prepAnnouncementMessage(
               examTitle: prepAnnouncement.examTitle,
               daysUntil: prepAnnouncement.daysUntil
           ) {
            onPrepAnnouncementShown?()
        }
        if let commitmentAnnouncement,
           message == TasksMessageComposer.commitmentAnnouncementMessage(commitmentAnnouncement) {
            onCommitmentAnnouncementShown?()
        }
    }
}

// MARK: - Interactive shell (cycles 2026-08-03-04/-05 — VISUAL PROTOTYPE)

/// One line of the shell's stub conversation.
private struct MessageBoxChatLine: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

/// The expanded surface behind the box's tap targets — roughly iOS's
/// swipe-down-reply shape: a dimmed backdrop (tap to collapse) with a card
/// holding the conversation, tappable options, and a free-text field.
/// (The -05 framed-dialogue styling was reverted in cycle 2026-08-03-06
/// after a device look — this is the -04 plain card again. What survived
/// -05: the expression enum driving the header portrait, and the seeding
/// below.)
///
/// ── EVERYTHING BEHIND IT IS A STUB ──────────────────────────────────────
/// The dialogue seeds from the box's real composed message (so the detail
/// the old in-place expansion showed stays reachable — the shell replaced
/// it as where the row's tap leads), then a fake question with two
/// options and canned replies. No persistence, no `ClaudeService`,
/// nothing written anywhere. Home chat untouched.
struct MessageBoxChatShell: View {
    /// What the collapsed box was saying when opened — seeds the dialogue.
    var seed: TasksMessage? = nil
    let onDismiss: () -> Void

    @State private var lines: [MessageBoxChatLine] = []
    /// The fake question's options; nil once answered (or after free text).
    @State private var options: [String]? = ["Start today", "Start tomorrow"]
    @State private var answered = false
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    /// The portrait tracks the conversation state — the whole point of
    /// the expression enum: asking while the question is open, pleased
    /// right after an answer, neutral otherwise.
    private var expression: MessageBoxExpression {
        if options != nil { return .asking }
        return answered ? .pleased : .neutral
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Backdrop — tapping outside collapses.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    inputFocused = false
                    onDismiss()
                }

            // The surface. Anchored near the top (where the collapsed box
            // lives) so the keyboard never covers it. The portrait keeps
            // its expression (kept from -05) — asking while the question
            // is open, pleased after an answer.
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    MessageBoxCharacterSlot(expression: expression)
                    Text("Nudge")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                        .foregroundColor(NudgeTheme.textPrimary)
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines) { line in
                            chatBubble(line)
                        }
                    }
                }
                .frame(maxHeight: 300)

                if let options {
                    HStack(spacing: 8) {
                        ForEach(options, id: \.self) { option in
                            Button {
                                answer(option)
                            } label: {
                                Text(option)
                                    .font(.custom(NudgeTheme.fontMedium, size: 14))
                                    .foregroundColor(NudgeTheme.primary)
                                    .padding(.horizontal, 14)
                                    .frame(height: 34)
                                    .overlay(
                                        Capsule().stroke(NudgeTheme.primary, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 10) {
                    TextField("Or say it your way…", text: $draft, axis: .vertical)
                        .font(.custom(NudgeTheme.fontBody, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .lineLimit(1...3)
                        .focused($inputFocused)
                        .onSubmit(sendDraft)
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(
                                draft.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? NudgeTheme.textPlaceholder
                                    : NudgeTheme.primary
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
            }
            .padding(16)
            .background(NudgeTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusSheet))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusSheet)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .onAppear { seedLines() }
    }

    private func chatBubble(_ line: MessageBoxChatLine) -> some View {
        HStack {
            if line.isUser { Spacer(minLength: 40) }
            Text(line.text)
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(line.isUser ? .white : NudgeTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(line.isUser ? NudgeTheme.primary : NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            if !line.isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: line.isUser ? .trailing : .leading)
    }

    /// Text appears immediately — deliberately NO typewriter reveal.
    private func seedLines() {
        guard lines.isEmpty else { return }
        var seeded: [MessageBoxChatLine] = []
        if let seed {
            seeded.append(MessageBoxChatLine(text: seed.headline, isUser: false))
            if let detail = seed.detail {
                seeded.append(MessageBoxChatLine(text: detail, isUser: false))
            }
        } else {
            seeded.append(MessageBoxChatLine(
                text: "“Problem set 4” is due Friday — it's the biggest thing on your list.",
                isUser: false
            ))
        }
        seeded.append(MessageBoxChatLine(
            text: "Should the first session go today or tomorrow?",
            isUser: false
        ))
        lines = seeded
    }

    /// Option tap: the answer becomes a user line, the options retire, and
    /// a canned acknowledgment lands. Stub — nothing is saved.
    private func answer(_ option: String) {
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            lines.append(MessageBoxChatLine(text: option, isUser: true))
            options = nil
            answered = true
            lines.append(MessageBoxChatLine(
                text: "Noted. (Prototype — nothing is saved yet.)",
                isUser: false
            ))
        }
    }

    /// Free text: same shape as an option answer. Stub — nothing is saved.
    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NudgeHaptics.light()
        withAnimation(NudgeAnimation.standard) {
            lines.append(MessageBoxChatLine(text: text, isUser: true))
            options = nil
            answered = true
            lines.append(MessageBoxChatLine(
                text: "Noted. (Prototype — nothing is saved yet.)",
                isUser: false
            ))
            draft = ""
        }
    }
}
