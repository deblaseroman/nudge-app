//
//  DailySession.swift
//  Nudge
//
//  Records each day's session starter (brain dump) and timing.
//  Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class DailySession {
    var id: UUID
    var date: Date
    var sessionText: String
    var chatTranscript: String
    var startedAt: Date
    var taskCount: Int

    /// Actual bedtime the user reported or was detected
    var actualBedtime: Date?
    /// Actual wake time the user reported or was detected
    var actualWakeTime: Date?

    /// Target bedtime from profile at time of session
    var targetBedtime: Date?
    /// Target wake time from profile at time of session
    var targetWakeTime: Date?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        sessionText: String = "",
        chatTranscript: String = "",
        startedAt: Date = Date(),
        taskCount: Int = 0,
        actualBedtime: Date? = nil,
        actualWakeTime: Date? = nil,
        targetBedtime: Date? = nil,
        targetWakeTime: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.sessionText = sessionText
        self.chatTranscript = chatTranscript
        self.startedAt = startedAt
        self.taskCount = taskCount
        self.actualBedtime = actualBedtime
        self.actualWakeTime = actualWakeTime
        self.targetBedtime = targetBedtime
        self.targetWakeTime = targetWakeTime
    }

    /// How many minutes off bedtime was (positive = late, negative = early)
    var bedtimeDeviationMinutes: Int? {
        guard let actual = actualBedtime, let target = targetBedtime else { return nil }
        let actualMinutes = Calendar.current.component(.hour, from: actual) * 60 + Calendar.current.component(.minute, from: actual)
        let targetMinutes = Calendar.current.component(.hour, from: target) * 60 + Calendar.current.component(.minute, from: target)
        return actualMinutes - targetMinutes
    }

    /// How many minutes off wake time was (positive = late, negative = early)
    var wakeDeviationMinutes: Int? {
        guard let actual = actualWakeTime, let target = targetWakeTime else { return nil }
        let actualMinutes = Calendar.current.component(.hour, from: actual) * 60 + Calendar.current.component(.minute, from: actual)
        let targetMinutes = Calendar.current.component(.hour, from: target) * 60 + Calendar.current.component(.minute, from: target)
        return actualMinutes - targetMinutes
    }
}
