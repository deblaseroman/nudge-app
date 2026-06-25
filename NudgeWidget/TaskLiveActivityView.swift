//
//  TaskLiveActivityView.swift
//  NudgeWidget
//
//  Live Activity UI for the DayPlanner session flow.
//  Shows state-specific layouts for active, break, get ready, warning, and complete.
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Colors

private enum TaskLAColors {
    static let accent = Color(red: 0.451, green: 0.576, blue: 0.702)
    static let breakGreen = Color(red: 0.40, green: 0.68, blue: 0.52)
    static let amber = Color(red: 0.88, green: 0.70, blue: 0.25)
    static let orange = Color(red: 0.92, green: 0.52, blue: 0.18)
    static let successGreen = Color(red: 0.33, green: 0.64, blue: 0.47)
    static let alertRed = Color(red: 0.92, green: 0.26, blue: 0.26)

    static func tint(for state: SessionState) -> Color {
        switch state {
        case .active: return accent
        case .breakTime: return breakGreen
        case .getReady: return amber
        case .finalWarning: return orange
        case .complete: return successGreen
        case .stayFocusedAlert: return alertRed
        }
    }

    static func background(for state: SessionState) -> Color {
        switch state {
        case .active: return Color(red: 0.07, green: 0.09, blue: 0.13)
        case .breakTime: return Color(red: 0.07, green: 0.12, blue: 0.09)
        case .getReady: return Color(red: 0.13, green: 0.12, blue: 0.07)
        case .finalWarning: return Color(red: 0.15, green: 0.10, blue: 0.05)
        case .complete: return Color(red: 0.06, green: 0.12, blue: 0.08)
        case .stayFocusedAlert: return Color(red: 0.18, green: 0.06, blue: 0.06)
        }
    }

    static func icon(for state: SessionState) -> String {
        switch state {
        case .active: return "bolt.fill"
        case .breakTime: return "cup.and.saucer.fill"
        case .getReady: return "bell.fill"
        case .finalWarning: return "exclamationmark.triangle.fill"
        case .complete: return "checkmark.circle.fill"
        case .stayFocusedAlert: return "eye.fill"
        }
    }

    static func statusLabel(for state: SessionState) -> String {
        switch state {
        case .active: return "FOCUSING"
        case .breakTime: return "BREAK TIME"
        case .getReady: return "GET READY"
        case .finalWarning: return "STARTING SOON"
        case .complete: return "ALL DONE"
        case .stayFocusedAlert: return "STAY FOCUSED"
        }
    }
}

// MARK: - Widget

struct TaskLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(TaskLAColors.background(for: context.state.sessionState))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "nudge://focus-session"))

        } dynamicIsland: { context in
            let tint = TaskLAColors.tint(for: context.state.sessionState)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: TaskLAColors.icon(for: context.state.sessionState))
                            .font(.system(size: 12, weight: .bold))
                        Text(TaskLAColors.statusLabel(for: context.state.sessionState))
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                    }
                    .foregroundStyle(tint)
                    .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.sessionState != .complete {
                        Text(timerInterval: Date()...context.state.timerEnd, countsDown: true)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                            .padding(.trailing, 2)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context: context, tint: tint)
                        .padding(.top, 4)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 5) {
                    Image(systemName: TaskLAColors.icon(for: context.state.sessionState))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)

                    Text(context.state.taskName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            } compactTrailing: {
                if context.state.sessionState != .complete {
                    Text(timerInterval: Date()...context.state.timerEnd, countsDown: true)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(TaskLAColors.successGreen)
                }
            } minimal: {
                if context.state.sessionState != .complete {
                    Text(timerInterval: Date()...context.state.timerEnd, countsDown: true)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TaskLAColors.successGreen)
                }
            }
            .widgetURL(URL(string: "nudge://focus-session"))
            .keylineTint(tint)
        }
    }

    // MARK: - Lock Screen / Banner (Expanded)

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<TaskActivityAttributes>) -> some View {
        let state = context.state
        let tint = TaskLAColors.tint(for: state.sessionState)

        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: TaskLAColors.icon(for: state.sessionState))
                        .font(.system(size: 13, weight: .bold))
                    Text(TaskLAColors.statusLabel(for: state.sessionState))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(tint)

                Spacer()

                if state.sessionState != .complete {
                    Text(timerInterval: Date()...state.timerEnd, countsDown: true)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 6) {
                switch state.sessionState {
                case .active:
                    Text(state.taskName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("Session \(context.attributes.currentTaskIndex) of \(context.attributes.totalTasksToday)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                case .breakTime:
                    Text("Time to recharge")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Up next: \(state.nextTaskName ?? "Done for today")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                case .getReady:
                    Text("\(state.nextTaskName ?? "Next task") starts soon")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("10 minutes left of break")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                case .finalWarning:
                    Text("\(state.nextTaskName ?? "Next task") — 1 min left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Wrap up your break!")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                case .complete:
                    Text("All done, \(context.attributes.userName)!")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Great work today")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                case .stayFocusedAlert:
                    Text("Stay focused")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("You've been at it for 20 minutes — keep going.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Expanded Dynamic Island Bottom

    @ViewBuilder
    private func expandedBottom(
        context: ActivityViewContext<TaskActivityAttributes>,
        tint: Color
    ) -> some View {
        let state = context.state

        VStack(alignment: .leading, spacing: 4) {
            switch state.sessionState {
            case .active:
                Text(state.taskName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Session \(context.attributes.currentTaskIndex) of \(context.attributes.totalTasksToday)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

            case .breakTime:
                Text("Up next: \(state.nextTaskName ?? "Done for today")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

            case .getReady:
                Text("\(state.nextTaskName ?? "Next task") starts soon")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

            case .finalWarning:
                Text("\(state.nextTaskName ?? "Next task") — 1 min left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

            case .complete:
                Text("All done, \(context.attributes.userName)!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

            case .stayFocusedAlert:
                Text("Stay focused")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Keep going on \(state.taskName)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Previews

extension TaskActivityAttributes {
    fileprivate static var preview: TaskActivityAttributes {
        TaskActivityAttributes(userName: "Roman", totalTasksToday: 4, currentTaskIndex: 1)
    }
}

extension TaskActivityAttributes.ContentState {
    fileprivate static var activePreview: TaskActivityAttributes.ContentState {
        .init(taskName: "Study Math", sessionState: .active, timerEnd: Date().addingTimeInterval(3600), nextTaskName: "Prepare for exam")
    }

    fileprivate static var breakPreview: TaskActivityAttributes.ContentState {
        .init(taskName: "Break", sessionState: .breakTime, timerEnd: Date().addingTimeInterval(1800), nextTaskName: "Prepare for exam")
    }

    fileprivate static var getReadyPreview: TaskActivityAttributes.ContentState {
        .init(taskName: "Get ready", sessionState: .getReady, timerEnd: Date().addingTimeInterval(600), nextTaskName: "Prepare for exam")
    }

    fileprivate static var warningPreview: TaskActivityAttributes.ContentState {
        .init(taskName: "Starting soon", sessionState: .finalWarning, timerEnd: Date().addingTimeInterval(60), nextTaskName: "Prepare for exam")
    }

    fileprivate static var completePreview: TaskActivityAttributes.ContentState {
        .init(taskName: "", sessionState: .complete, timerEnd: Date(), nextTaskName: nil)
    }
}

#Preview("Active", as: .content, using: TaskActivityAttributes.preview) {
    TaskLiveActivityView()
} contentStates: {
    TaskActivityAttributes.ContentState.activePreview
}

#Preview("Break", as: .content, using: TaskActivityAttributes.preview) {
    TaskLiveActivityView()
} contentStates: {
    TaskActivityAttributes.ContentState.breakPreview
}

#Preview("Complete", as: .content, using: TaskActivityAttributes.preview) {
    TaskLiveActivityView()
} contentStates: {
    TaskActivityAttributes.ContentState.completePreview
}
