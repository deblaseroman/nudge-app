//
//  CompleteTaskIntent.swift
//  NudgeWidget
//
//  AppIntent that marks a task complete from the widget checkbox.
//  Fires a haptic on completion — works when the intent runs in the app process.
//

import ActivityKit
import AppIntents
import SwiftData
import WidgetKit
import UIKit

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Task"
    private let completionDisplayDuration: Duration = .milliseconds(1500)

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: taskID) else {
            return .result()
        }

        let context = ModelContext(widgetModelContainer)
        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                task.id == uuid
            }
        )

        if let task = try context.fetch(descriptor).first {
            guard !task.isComplete else {
                WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                return .result()
            }

            let completionDate = Date()
            task.isComplete = true
            task.completedAt = completionDate

            // Create a persistent record so stats survive task deletion
            let sourceID = task.id
            let existingRecordDescriptor = FetchDescriptor<CompletedTaskRecord>(
                predicate: #Predicate<CompletedTaskRecord> { $0.sourceTaskID == sourceID }
            )
            if (try? context.fetch(existingRecordDescriptor).first) == nil {
                let record = CompletedTaskRecord(
                    title: task.title,
                    priority: task.priority,
                    completedAt: completionDate,
                    sourceTaskID: task.id
                )
                context.insert(record)
            }

            try context.save()

            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")

            // Notify the main app so SessionCoordinator can advance if a
            // session is active.
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(
                center,
                CFNotificationName("com.nudge.sessionStateChanged" as CFString),
                nil,
                nil,
                true
            )

            // Fire haptic — two-stage thud matching the main app's task complete feel
            await fireCompletionHaptic()

            try? await Task.sleep(for: completionDisplayDuration)
        }

        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")

        return .result()
    }

    @MainActor
    private func fireCompletionHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: 0.65)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            generator.impactOccurred(intensity: 1.0)
        }
    }
}
