//
//  FocusSessionIntents.swift
//  Nudge
//
//  AppIntents for session controls. These run in the main app process.
//

import AppIntents
import SwiftData
import WidgetKit

struct StartFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Focus Session"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Sessions now require the user to pick a task. Just open the app so
        // they can choose from the in-app picker.
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        return .result()
    }
}

struct PauseFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Pause Focus Session"

    func perform() async throws -> some IntentResult {
        // SessionCoordinator does not support pause — this is now a no-op.
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        return .result()
    }
}

struct EndFocusSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "End Focus Session"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SessionCoordinator.shared.cancelSession()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        return .result()
    }
}
