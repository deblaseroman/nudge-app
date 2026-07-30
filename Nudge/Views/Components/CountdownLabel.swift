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

// CountdownState — the pure state machine this view renders — moved to
// `Nudge/Models/CountdownState.swift` (Jul 2026) so the widget target
// compiles it too and can't drift from it. This view remains the
// app-side renderer of that state.
