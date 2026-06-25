//
//  FocusSessionIntents.swift
//  NudgeWidget
//
//  Widget AppIntents. Session start is handled in the main app via deep link
//  (nudge://start-session). Pause is no longer supported. End ends any active
//  Live Activity directly.
//

import ActivityKit
import AppIntents
import WidgetKit

private let appGroupID = "group.com.deblaser.nudge"

/// Posts a Darwin notification so the main app can sync state.
private func notifyApp() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    CFNotificationCenterPostNotification(center, CFNotificationName("com.nudge.sessionStateChanged" as CFString), nil, nil, true)
}

struct PauseFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Pause Focus Session"

    func perform() async throws -> some IntentResult {
        // Pause is no longer supported — no-op.
        notifyApp()
        return .result()
    }
}

struct EndFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End Focus Session"

    func perform() async throws -> some IntentResult {
        // End any current task Live Activity.
        for activity in Activity<TaskActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: "activeSessionState")

        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        notifyApp()
        return .result()
    }
}
