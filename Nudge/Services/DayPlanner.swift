//
//  DayPlanner.swift
//  Nudge
//
//  Standalone scheduling engine. Takes a list of NudgeTasks and produces
//  a linear schedule of time blocks starting at 9:00 AM with 30-min breaks.
//

import Foundation

struct ScheduledBlock {
    let task: NudgeTask
    let startTime: Date
    let endTime: Date
    let breakDuration: TimeInterval
}

@MainActor
final class DayPlanner {

    static let shared = DayPlanner()

    private let defaultDurationMinutes = 60
    private let breakSeconds: TimeInterval = 1800

    func scheduleTasks(_ tasks: [NudgeTask]) -> [ScheduledBlock] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? .distantFuture

        // Rule 1: Skip completed and informational events
        let incomplete = tasks.filter { !$0.isComplete && !$0.isInformationalEvent }

        // Rule 2: Tasks with a deadline of today, sorted by earliest deadline
        let todayTasks = incomplete
            .filter { task in
                guard let due = task.dueDate else { return false }
                return due >= today && due < tomorrow
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

        // Rule 3: Tasks with a future deadline, sorted by earliest deadline
        let futureTasks = incomplete
            .filter { task in
                guard let due = task.dueDate else { return false }
                return due >= tomorrow
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

        // Rule 4: Tasks with no deadline, sorted by shortest duration (quick wins)
        let noDueDateTasks = incomplete
            .filter { $0.dueDate == nil }
            .sorted { ($0.estimatedMinutes ?? defaultDurationMinutes) < ($1.estimatedMinutes ?? defaultDurationMinutes) }

        let ordered = todayTasks + futureTasks + noDueDateTasks

        // Pinned tasks (have specificTime) anchor their own slot. Flexible
        // tasks flow around them starting at 9 AM.
        var pinnedQueue: [ScheduledBlock] = ordered
            .compactMap { task -> ScheduledBlock? in
                guard let start = task.specificTime else { return nil }
                let minutes = task.estimatedMinutes ?? defaultDurationMinutes
                let duration = TimeInterval(minutes * 60)
                return ScheduledBlock(
                    task: task,
                    startTime: start,
                    endTime: start.addingTimeInterval(duration),
                    breakDuration: breakSeconds
                )
            }
            .sorted { $0.startTime < $1.startTime }

        let flexibleTasks = ordered.filter { $0.specificTime == nil }

        var cursor = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        var blocks: [ScheduledBlock] = []

        for task in flexibleTasks {
            let minutes = task.estimatedMinutes ?? defaultDurationMinutes
            let duration = TimeInterval(minutes * 60)

            // Drain any pinned blocks that this flexible would overlap.
            while let nextPinned = pinnedQueue.first,
                  cursor.addingTimeInterval(duration) > nextPinned.startTime {
                blocks.append(nextPinned)
                cursor = max(cursor, nextPinned.endTime).addingTimeInterval(breakSeconds)
                pinnedQueue.removeFirst()
            }

            let startTime = cursor
            let endTime = startTime.addingTimeInterval(duration)
            blocks.append(ScheduledBlock(
                task: task,
                startTime: startTime,
                endTime: endTime,
                breakDuration: breakSeconds
            ))
            cursor = endTime.addingTimeInterval(breakSeconds)
        }

        // Append any pinned blocks that come after the last flexible.
        blocks.append(contentsOf: pinnedQueue)
        blocks.sort { $0.startTime < $1.startTime }

        // Recompute breakDuration: no break after the last block.
        return blocks.enumerated().map { (index, block) in
            let isLast = index == blocks.count - 1
            return ScheduledBlock(
                task: block.task,
                startTime: block.startTime,
                endTime: block.endTime,
                breakDuration: isLast ? 0 : breakSeconds
            )
        }
    }

    func previewSchedule(_ blocks: [ScheduledBlock]) {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"

        for block in blocks {
            let start = fmt.string(from: block.startTime)
            let end = fmt.string(from: block.endTime)
            let minutes = block.task.estimatedMinutes ?? defaultDurationMinutes

            var line = "[\(start) - \(end)] \(block.task.title) (\(minutes) min)"

            if block.breakDuration > 0 {
                let breakMin = Int(block.breakDuration / 60)
                line += " → break \(breakMin) min"
            }

            print(line)
        }
    }
}
