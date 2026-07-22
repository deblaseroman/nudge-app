//
//  CountdownLabel.swift
//  Nudge
//
//  Contextual countdown display for tasks and events. Implements the 7
//  display rules from the product spec EXACTLY — never duplicate this
//  logic anywhere else. Replace any "due date label" usage with this view.
//
//  The display rules (do not change without updating CountdownState):
//    1. > 7 days        → "Due Thursday Jun 17th"
//    2. 2–7 days (≥48h) → "Due Thursday Jun 17th · 4 days away"
//    3. 24–48 hours     → "Due Thursday Jun 17th · 28 hours left"
//    4. 3–24 hours      → "Due Thursday Jun 17th · 6 hours left" + coral dot
//    5. < 3 hours       → "Due Thursday Jun 17th · 1hr 45min" + filled coral pip
//                          + optional one-tap suggestion (editor sheet only)
//    6. Overdue         → "Was due 3 hours ago" + strikethrough + reschedule chip
//    7. Nighttime (11pm-7am) → suppress countdown suffix, date stays visible
//
//  Hard threshold: hours-left appears below 48 hours, days-away above 48 hours.
//  The date (day name + month + day with ordinal) is ALWAYS shown for future
//  states — ADHD users benefit from seeing the concrete date alongside the
//  countdown so "28 hours left" anchors to "Thursday" not just an abstract count.
//
//  Tone rules (also enforced here):
//    - Never use "late", "missed", "failed", "only", "just", "warning"
//    - No exclamation marks, no caps
//    - The visual indicator carries urgency, not the language
//

import SwiftUI

struct CountdownLabel: View {
    let dueDate: Date?
    /// Leading word that prefixes the time phrasing — "Due", "Exam",
    /// "Starts", etc. Defaults to "Due".
    var prefix: String = "Due"
    /// When true, under-3-hour state renders a secondary action suggestion.
    /// Only enable in detail sheets, NOT in list rows.
    var showsActionSuggestion: Bool = false
    /// AI-generated concrete first action (e.g. "Open the doc and write
    /// one sentence."). Shown under the "Want to start on this now?" pill
    /// when present. Pure UI hint — calm tone enforced upstream by the
    /// NudgeIntelligence prompt.
    var suggestedFirstStep: String? = nil
    /// Invoked when the user taps the reschedule chip in the overdue state.
    var onReschedule: (() -> Void)? = nil
    /// Invoked when the user taps the "start now" suggestion under 3 hours.
    var onStartNow: (() -> Void)? = nil

    /// Observe the shared 60-second tick so all visible CountdownLabels
    /// update together once a minute while the app is open. Computed (not
    /// stored) so the auto-synthesized memberwise init stays internal —
    /// otherwise a `private` stored member makes the init private too.
    private var clock: CountdownClock { CountdownClock.shared }

    var body: some View {
        if let due = dueDate {
            let state = CountdownState.compute(dueDate: due, now: clock.now)
            content(for: state)
        } else {
            Text("No due date")
                .font(.custom(NudgeTheme.fontBody, size: 13))
                .foregroundColor(NudgeTheme.textMuted)
        }
    }

    // MARK: - State Rendering

    @ViewBuilder
    private func content(for state: CountdownState) -> some View {
        switch state {
        case .farFuture(let dateString):
            label("\(prefix) \(dateString)",
                  color: NudgeTheme.textMuted)

        case .daysAway(let dateString, let daysAway):
            label("\(prefix) \(dateString) · \(daysAway) days away",
                  color: NudgeTheme.textSecondary)

        case .withinTwoDays(let dateString, let hoursLeft):
            label("\(prefix) \(dateString) · \(hoursLeft) hours left",
                  color: NudgeTheme.textPrimary)

        case .underDay(let dateString, let hoursLeft):
            HStack(spacing: 6) {
                indicatorDot(filled: false)
                labelText("\(prefix) \(dateString) · \(hoursLeft) hours left",
                          color: NudgeTheme.primaryLight)
            }

        case .underThreeHours(let dateString, let hours, let minutes):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    indicatorDot(filled: true)
                    labelText("\(prefix) \(dateString) · \(formatHoursMinutes(hours: hours, minutes: minutes))",
                              color: NudgeTheme.primary)
                }
                if showsActionSuggestion {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            NudgeHaptics.light()
                            onStartNow?()
                        } label: {
                            Text("Want to start on this now?")
                                .font(.custom(NudgeTheme.fontMedium, size: 12))
                                .foregroundColor(NudgeTheme.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(NudgeTheme.primary.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        // Concrete first step from NudgeIntelligence — lowers
                        // activation energy without expanding the prompt UI.
                        if let step = suggestedFirstStep,
                           !step.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(NudgeTheme.textSecondary)
                                Text(step)
                                    .font(.custom(NudgeTheme.fontBody, size: 11))
                                    .foregroundColor(NudgeTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

        case .overdue(let agoString):
            HStack(spacing: 8) {
                Text("Was due \(agoString)")
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.textMuted)
                    .strikethrough(true, color: NudgeTheme.textMuted)

                if onReschedule != nil {
                    Button {
                        NudgeHaptics.light()
                        onReschedule?()
                    } label: {
                        Text("Reschedule")
                            .font(.custom(NudgeTheme.fontMedium, size: 11))
                            .foregroundColor(NudgeTheme.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(NudgeTheme.primary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

        case .nightSuppressed(let dateString):
            // Rule 7 — quiet time. Show the date, no hours-left countdown.
            label("\(prefix) \(dateString)",
                  color: NudgeTheme.textMuted)
        }
    }

    // MARK: - Pieces

    private func label(_ text: String, color: Color) -> some View {
        labelText(text, color: color)
    }

    private func labelText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.custom(NudgeTheme.fontMedium, size: 13))
            .foregroundColor(color)
    }

    private func indicatorDot(filled: Bool) -> some View {
        Circle()
            .strokeBorder(NudgeTheme.coral, lineWidth: filled ? 0 : 1.5)
            .background(filled ? Circle().fill(NudgeTheme.coral) : nil)
            .frame(width: 7, height: 7)
    }

    /// Compact "1hr 45min" style suffix. The leading prefix + date are
    /// handled by the caller — this just renders the time-remaining piece.
    private func formatHoursMinutes(hours: Int, minutes: Int) -> String {
        if hours == 0 { return "\(minutes)min" }
        if minutes == 0 { return "\(hours)hr" }
        return "\(hours)hr \(minutes)min"
    }
}

// MARK: - State Computation (pure — easy to unit test)

enum CountdownState: Equatable {
    case farFuture(dateString: String)                                  // > 7 days
    case daysAway(dateString: String, daysAway: Int)                    // 2–7 days (≥48h)
    case withinTwoDays(dateString: String, hoursLeft: Int)              // 24–48 hours
    case underDay(dateString: String, hoursLeft: Int)                   // 3–24 hours, + dot
    case underThreeHours(dateString: String, hours: Int, minutes: Int)  // < 3 hours, + pip
    case overdue(ago: String)                                           // due in the past
    case nightSuppressed(dateString: String)                            // 11pm–7am override

    /// Pure computation — no UI, no clock dependency. Used by the view and
    /// by unit tests.
    static func compute(dueDate: Date, now: Date) -> CountdownState {
        let calendar = Calendar.current
        let interval = dueDate.timeIntervalSince(now)

        // Overdue — Rule 6. Always wins, even at night, so the user always
        // knows the task is past due. The reschedule chip is the action.
        if interval < 0 {
            return .overdue(ago: formatTimeAgo(seconds: -interval))
        }

        let dateString = formatFullDate(dueDate)

        // Night suppression — Rule 7 — drops the countdown suffix for
        // FUTURE deadlines so the user doesn't get pinged at 2 AM with
        // "12 hours left." Date still shows so context isn't lost.
        let hour = calendar.component(.hour, from: now)
        let inQuietHours = (hour >= 23 || hour < 7)
        if inQuietHours {
            return .nightSuppressed(dateString: dateString)
        }

        let hoursOut = interval / 3600
        let daysOut = hoursOut / 24

        // Rule 1 — > 7 days
        if daysOut > 7 {
            return .farFuture(dateString: dateString)
        }
        // Rule 2 — 2–7 days (boundary at 48h, not 72h, so "2 days away"
        // shows for the full 48–72 hour window instead of switching to
        // raw hours — the user asked for hours-left only when < 48h)
        if hoursOut >= 48 {
            return .daysAway(dateString: dateString, daysAway: Int(daysOut.rounded()))
        }
        // Rule 3 — 24–48 hours
        if hoursOut >= 24 {
            return .withinTwoDays(dateString: dateString, hoursLeft: Int(hoursOut.rounded()))
        }
        // Rule 4 — 3–24 hours
        if hoursOut >= 3 {
            return .underDay(dateString: dateString, hoursLeft: Int(hoursOut.rounded()))
        }
        // Rule 5 — < 3 hours
        let totalMinutes = Int((interval / 60).rounded())
        return .underThreeHours(
            dateString: dateString,
            hours: totalMinutes / 60,
            minutes: totalMinutes % 60
        )
    }

    // MARK: - Formatters

    /// "Thursday Jun 17th" — full day name + abbreviated month + day with
    /// ordinal suffix. The canonical date format shown in EVERY future
    /// state so users see the concrete date alongside any countdown.
    private static func formatFullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE MMM d"
        let base = f.string(from: date)
        let day = Calendar.current.component(.day, from: date)
        return base + ordinalSuffix(for: day)
    }

    /// English ordinal suffix for a day number (1st, 2nd, 3rd, 4th, …).
    /// The 11/12/13 case is special-cased because "11st"/"12nd"/"13rd"
    /// would otherwise come out of the % 10 logic.
    private static func ordinalSuffix(for day: Int) -> String {
        if (11...13).contains(day) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    // MARK: - Split-row helpers
    //
    // List rows render the countdown info as TWO separate pieces — date
    // on the right, remaining time as a subtitle under the title. These
    // helpers return the two pure strings so the row view can position
    // them independently. The legacy joined `CountdownLabel` rendering
    // above is still used in detail / editor surfaces.

    /// Right-side date line for a task row. Returns `"Jun 12th, 9pm"` when
    /// a specific clock time exists, `"Jun 12th"` when only a date is
    /// known, `nil` for floaters. The row decides how to style it.
    static func dueDateLine(
        dueDate: Date?,
        specificTime: Date?
    ) -> String? {
        guard let anchor = specificTime ?? dueDate else { return nil }
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "MMM d"
        let day = Calendar.current.component(.day, from: anchor)
        let datePart = dayFmt.string(from: anchor) + ordinalSuffix(for: day)

        if specificTime != nil {
            return "\(datePart), \(formatClockTime(anchor))"
        }
        return datePart
    }

    /// "12 hours left" / "5 days away" / "1hr 45min" / "3 hours ago" — the
    /// subtitle that sits below the task title in a row. Returns `nil` for
    /// far-future tasks (> 7 days) and at night, so the row stays calm
    /// when there's no time pressure to communicate.
    static func remainingLine(dueDate: Date, now: Date) -> String? {
        switch compute(dueDate: dueDate, now: now) {
        case .farFuture, .nightSuppressed:
            return nil
        case .daysAway(_, let days):
            return days == 1 ? "1 day away" : "\(days) days away"
        case .withinTwoDays(_, let hours), .underDay(_, let hours):
            return hours == 1 ? "1 hour left" : "\(hours) hours left"
        case .underThreeHours(_, let hours, let minutes):
            if hours == 0 { return "\(minutes)min" }
            if minutes == 0 { return "\(hours)hr" }
            return "\(hours)hr \(minutes)min"
        case .overdue(let ago):
            return ago
        }
    }

    // MARK: - Event timing line
    //
    // Events don't "count down" like tasks — they aren't completed, the user
    // just shows up. So instead of "6 hours left / 2 days away", an event
    // states WHEN it is, measured in whole CALENDAR DAYS (not 24h intervals):
    //   • same day   → "Today at 3pm"
    //   • 1 day      → "Tomorrow"
    //   • 2–3 days   → "In 3 days, July 5 at 3pm"
    //   • > 3 days   → "July 5 at 3pm"
    //   • no clock time set → the " at 3pm" suffix is dropped
    //
    // NOTE: repeating-event phrasing ("Wed at 3pm" / "Wed and Thu at 3pm")
    // is intentionally NOT handled here yet — the NudgeTask model stores one
    // row per occurrence and has no recurrence flag, so detecting "this
    // repeats" needs a separate design decision (add a recurrence field, or
    // group same-title events). Single-occurrence phrasing ships first.
    static func eventLine(specificTime: Date?, dueDate: Date?, now: Date) -> String? {
        guard let anchor = specificTime ?? dueDate else { return nil }
        let cal = Calendar.current
        let dayDelta = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: anchor)
        ).day ?? 0

        let timeSuffix = specificTime != nil ? " at \(formatClockTime(anchor))" : ""

        let monthDay = DateFormatter()
        monthDay.dateFormat = "MMMM d"
        let datePart = monthDay.string(from: anchor)

        if dayDelta <= 0 {
            return "Today\(timeSuffix)"
        }
        if dayDelta == 1 {
            return "Tomorrow"
        }
        if dayDelta <= 3 {
            return "In \(dayDelta) days, \(datePart)\(timeSuffix)"
        }
        return "\(datePart)\(timeSuffix)"
    }

    /// `9pm` when the minutes are :00, `9:30pm` otherwise. Always lowercase.
    private static func formatClockTime(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        let fmt = DateFormatter()
        fmt.dateFormat = minute == 0 ? "ha" : "h:mma"
        return fmt.string(from: date).lowercased()
    }

    /// "3 hours ago", "2 days ago" — calm, neutral phrasing.
    private static func formatTimeAgo(seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return minutes <= 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}
