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

// MARK: - Composer (pure)

/// Deterministic message selection. Priority order — first state that
/// applies wins:
///   1. a nudge was just tapped (explain it beyond the 60-char banner)
///   2. something is overdue (name it and by how long)
///   3. something high-stakes is approaching (name it and days remaining)
///   4. resting — a plain line about the day. NEVER blank: an empty box at
///      the top of the most-used tab is dead space.
///
/// Tone is where DESIGN.md bites hardest: state facts. No verdict on the
/// user, no promised outcome, no implied failure for missed work.
enum TasksMessageComposer {
    static func compose(
        tasks: [NudgeTask],
        tappedNudge: TappedNudgeContext?,
        rationale: String? = nil,
        aiMessage: TasksMessage? = nil,
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

        // 4 — the AI Refine rationale (fifth state, Aug 2026 — folded in
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

        // 5 — resting. Never blank.
        return restingMessage(open: open, allTasks: tasks, now: now)
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
        case .getAhead:
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

/// The square on the box's left where a character lands — a messenger
/// pigeon, eventually one per surface. Sized like a task row's leading
/// checkbox (28×28) so the two align down the tab. Until an asset exists it
/// renders a plain grey placeholder from the theme.
///
/// One parameter on purpose: dropping the mascot in is ONE line at the call
/// site — `MessageBoxCharacterSlot(image: Image("pigeon-tasks"))` — and
/// touches nothing else.
struct MessageBoxCharacterSlot: View {
    var image: Image? = nil

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(NudgeTheme.textPlaceholder)
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - View

/// The app speaking as a row IN the list, not a banner above it — same
/// footprint as a task row (padding, corner radius, the shared horizontal
/// insets), with one difference carrying the distinction: a task row is a
/// FILLED card, this is an OUTLINED one (`NudgeTheme.border`, no fill).
///
/// Height: collapsed, the headline truncates at two lines — the footprint a
/// task row with a subtitle has. Expanding GROWS the row in place (same
/// width, same corners) to the full headline plus detail; tap again to
/// collapse back.
struct TasksMessageBox: View {
    let tasks: [NudgeTask]
    let tappedNudge: TappedNudgeContext?
    var rationale: String? = nil

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
            guard expandable else { return }
            NudgeHaptics.light()
            withAnimation(NudgeAnimation.standard) {
                isExpanded.toggle()
            }
        }
        .animation(NudgeAnimation.standard, value: message)
    }
}
