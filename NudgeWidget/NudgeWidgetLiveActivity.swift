//
//  NudgeWidgetLiveActivity.swift
//  NudgeWidget
//
//  Live Activity UI for focus sessions — lock screen, Dynamic Island,
//  and compact presentations. Shows current task in all presentations.
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Colors

private enum LAColors {
    static let accent = Color(red: 0.451, green: 0.576, blue: 0.702)
    static let accentSoft = accent.opacity(0.16)
    static let surface = Color(red: 0.965, green: 0.976, blue: 0.967)
    static let textPrimary = Color(red: 0.11, green: 0.13, blue: 0.12)
    static let textSecondary = Color(red: 0.11, green: 0.13, blue: 0.12).opacity(0.72)
    static let textMuted = Color(red: 0.11, green: 0.13, blue: 0.12).opacity(0.45)
    static let divider = Color(red: 0.49, green: 0.53, blue: 0.5).opacity(0.14)
    static let pauseOrange = Color(red: 0.95, green: 0.6, blue: 0.2)
    static let successGreen = Color(red: 0.329, green: 0.643, blue: 0.467)
}

// MARK: - Live Activity Widget

struct NudgeWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusSessionAttributes.self) { context in
            // MARK: Lock Screen / Banner
            lockScreenView(context: context)
                .activityBackgroundTint(LAColors.surface)
                .activitySystemActionForegroundColor(LAColors.textPrimary)
                .widgetURL(URL(string: "nudge://focus-session"))

        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: Expanded Dynamic Island
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image("mascot-default")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("nudge")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)

                            if context.state.isPaused {
                                Text("Paused")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LAColors.pauseOrange)
                            } else {
                                Text("Focusing")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        timerView(context: context)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(context.state.isPaused ? LAColors.pauseOrange : LAColors.accent)

                        Text("remaining")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        // Current task — prominent
                        HStack(spacing: 10) {
                            Image(systemName: "circle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(LAColors.accent)

                            Text(context.state.currentTaskTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)

                        // Progress bar + count
                        HStack(spacing: 10) {
                            // Progress bar
                            expandedProgressBar(context: context)

                            // Progress count pill
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                Text("\(context.state.completedTaskCount)/\(context.state.totalTaskCount)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(LAColors.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(LAColors.accentSoft)
                            .clipShape(Capsule())
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                // MARK: Compact — task title on leading side
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LAColors.accent)

                    Text(context.state.currentTaskTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            } compactTrailing: {
                // MARK: Compact — timer on trailing side
                timerView(context: context)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(context.state.isPaused ? LAColors.pauseOrange : LAColors.accent)
            } minimal: {
                // MARK: Minimal — bolt icon with accent color
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LAColors.accent)
            }
            .widgetURL(URL(string: "nudge://focus-session"))
            .keylineTint(LAColors.accent)
        }
    }

    // MARK: - Expanded Dynamic Island Progress Bar

    @ViewBuilder
    private func expandedProgressBar(context: ActivityViewContext<FocusSessionAttributes>) -> some View {
        let total = Double(context.attributes.totalDurationSeconds)
        let remaining: Double = {
            if context.state.isPaused, let paused = context.state.pausedTimeRemaining {
                return Double(paused)
            }
            return max(context.state.timerEndDate.timeIntervalSinceNow, 0)
        }()
        let progress = total > 0 ? min(max(1.0 - remaining / total, 0), 1) : 0
        let barColor = context.state.isPaused ? LAColors.pauseOrange : LAColors.accent

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(barColor.opacity(0.2))
                    .frame(height: 6)

                Capsule()
                    .fill(barColor)
                    .frame(width: max(geo.size.width * progress, 0), height: 6)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Lock Screen Layout

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<FocusSessionAttributes>) -> some View {
        VStack(spacing: 0) {
            // Header: mascot + branding + status + timer
            HStack(spacing: 12) {
                Image("mascot-default")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("nudge")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LAColors.textPrimary)
                        Text("·")
                            .foregroundStyle(LAColors.textMuted)
                        Text("focus")
                            .font(.system(size: 15))
                            .foregroundStyle(LAColors.textSecondary)
                    }

                    if context.state.isPaused {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LAColors.pauseOrange)
                                .frame(width: 6, height: 6)
                            Text("Session paused")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(LAColors.pauseOrange)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(LAColors.successGreen)
                                .frame(width: 6, height: 6)
                            Text("In progress")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(LAColors.successGreen)
                        }
                    }
                }

                Spacer()

                // Large countdown timer
                VStack(alignment: .trailing, spacing: 1) {
                    timerView(context: context)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(context.state.isPaused ? LAColors.pauseOrange : LAColors.accent)

                    Text("remaining")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LAColors.textMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Rectangle()
                .fill(LAColors.divider)
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Current task — displayed prominently
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(LAColors.accent, lineWidth: 2)
                        .frame(width: 24, height: 24)

                    Circle()
                        .fill(LAColors.accentSoft)
                        .frame(width: 24, height: 24)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Current task")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LAColors.textMuted)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Text(context.state.currentTaskTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LAColors.textPrimary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle()
                .fill(LAColors.divider)
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Bottom row: progress bar + task count
            HStack(spacing: 12) {
                // Progress bar
                lockScreenProgressBar(context: context)

                // Progress count pill
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("\(context.state.completedTaskCount) of \(context.state.totalTaskCount)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(LAColors.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LAColors.accentSoft)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Lock Screen Progress Bar

    @ViewBuilder
    private func lockScreenProgressBar(context: ActivityViewContext<FocusSessionAttributes>) -> some View {
        let total = Double(context.attributes.totalDurationSeconds)
        let remaining: Double = {
            if context.state.isPaused, let paused = context.state.pausedTimeRemaining {
                return Double(paused)
            }
            return max(context.state.timerEndDate.timeIntervalSinceNow, 0)
        }()
        let progress = total > 0 ? min(max(1.0 - remaining / total, 0), 1) : 0
        let barColor = context.state.isPaused ? LAColors.pauseOrange : LAColors.accent

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(barColor.opacity(0.15))
                    .frame(height: 6)

                Capsule()
                    .fill(barColor)
                    .frame(width: max(geo.size.width * progress, 0), height: 6)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Timer View

    @ViewBuilder
    private func timerView(context: ActivityViewContext<FocusSessionAttributes>) -> some View {
        if context.state.isPaused, let remaining = context.state.pausedTimeRemaining {
            let minutes = remaining / 60
            let seconds = remaining % 60
            Text(String(format: "%d:%02d", minutes, seconds))
                .monospacedDigit()
        } else {
            Text(timerInterval: Date()...context.state.timerEndDate, countsDown: true)
                .monospacedDigit()
        }
    }
}

// MARK: - Previews

extension FocusSessionAttributes {
    fileprivate static var preview: FocusSessionAttributes {
        FocusSessionAttributes(sessionID: UUID(), totalDurationSeconds: 3600)
    }
}

extension FocusSessionAttributes.ContentState {
    fileprivate static var running: FocusSessionAttributes.ContentState {
        FocusSessionAttributes.ContentState(
            currentTaskTitle: "Review biology quiz notes",
            currentTaskID: nil,
            timerEndDate: Date().addingTimeInterval(2400),
            isPaused: false,
            pausedTimeRemaining: nil,
            completedTaskCount: 1,
            totalTaskCount: 4
        )
    }

    fileprivate static var paused: FocusSessionAttributes.ContentState {
        FocusSessionAttributes.ContentState(
            currentTaskTitle: "Review biology quiz notes",
            currentTaskID: nil,
            timerEndDate: Date().addingTimeInterval(2400),
            isPaused: true,
            pausedTimeRemaining: 2400,
            completedTaskCount: 1,
            totalTaskCount: 4
        )
    }
}

#Preview("Notification", as: .content, using: FocusSessionAttributes.preview) {
    NudgeWidgetLiveActivity()
} contentStates: {
    FocusSessionAttributes.ContentState.running
    FocusSessionAttributes.ContentState.paused
}
