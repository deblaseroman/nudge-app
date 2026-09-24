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
import UserNotifications
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

            // Completing a goal-linked task counts as working on the goal —
            // same rule as the in-app checkbox; NudgeGoal is in the widget
            // schema so the shared helper works against this context too.
            NudgeGoal.recordActivity(
                goalID: task.goalID, at: completionDate, in: context
            )

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

            let defaults = UserDefaults(suiteName: "group.com.deblaser.nudge")

            // Completing the task a session is running for ends the session
            // (the app does the same on its own checkbox). The coordinator
            // notices the missing key on the next foreground and tears its
            // state down. Without this the row kept its timer and, once the
            // end instant passed, the extension could not render at all.
            if let state = defaults?.dictionary(forKey: "activeSessionState"),
               (state["currentTaskID"] as? String) == task.id.uuidString {
                defaults?.removeObject(forKey: "activeSessionState")
            }

            // The arbiter lives in the app and cannot run here, so the
            // completion would leave every pending nudge about this task in
            // place until the app's next foreground (and that reevaluate is
            // debounced). Roman, Sep 23 2026: "still open" arrived ten
            // minutes after the checkbox. Every per-task candidate id
            // carries the task's UUID, so drop those requests now, keep the
            // arbiter's ownership list honest, and ask the app for an
            // undebounced reevaluate on its next foreground for the kinds
            // that only NAME the task (the morning prompt).
            await Self.cancelPendingNudges(for: task.id, defaults: defaults)

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
    /// Removes every pending arbiter request whose identifier carries
    /// `taskID` (prep, floater, placementLead, placementMissed), trims them
    /// from the arbiter's ownership list in the App Group, and sets the
    /// flag `ContentView` reads to run an undebounced reevaluate on the
    /// next foreground.
    static func cancelPendingNudges(for taskID: UUID, defaults: UserDefaults?) async {
        let needle = taskID.uuidString
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let mine = pending.map(\.identifier).filter { $0.hasPrefix("nudge.arb.") && $0.contains(needle) }
        if !mine.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: mine)
            let key = "nudge.arb.scheduledIDs"
            let tracked = defaults?.stringArray(forKey: key) ?? []
            defaults?.set(tracked.filter { !mine.contains($0) }, forKey: key)
        }
        defaults?.set(true, forKey: "nudge.arb.widgetMutated")
    }

    private func fireCompletionHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: 0.65)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            generator.impactOccurred(intensity: 1.0)
        }
    }
}
