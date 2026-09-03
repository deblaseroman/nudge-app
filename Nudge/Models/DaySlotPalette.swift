//
//  DaySlotPalette.swift
//  Nudge
//
//  Assigns each of today's tasks a "slot" — its position in the day — so the
//  Today list and the timeline can tint the same task the same color.
//
//  The timeline is the anchor: slot 0 is the earliest block of the day, slot
//  1 the next, and so on. Tasks in Today's ordered plan that haven't been
//  placed on the timeline yet continue the rotation after the placed ones, in
//  sequenceIndex order, so every row under Today still gets its own tint.
//
//  Pure ordering. No colors here (those live in NudgeTheme), no fetching, no
//  mutation — the caller passes the tasks it already has.
//
//  LIVES IN Models/, NOT Views/, because the widget compiles Models only and
//  its day chart has to tint the same task the same color as the app. Same
//  reason TaskSortComparator and CountdownState moved here — a second copy in
//  the widget is a copy that drifts.
//
//  ONE CALLER OWNS THE ASSIGNMENT. TasksTabView computes it from its
//  unbounded @Query and hands the result down to TodayTimelineView, which has
//  a capped fetch of its own. Letting both compute independently would let a
//  task present in one set and missing from the other shift every slot after
//  it, and the row would stop matching its block — the one thing this exists
//  to guarantee.
//

import Foundation

enum DaySlotPalette {
    /// Slot index (0-based) per task id.
    ///
    /// Order: tasks placed on today's timeline by `plannedStartDate`, then
    /// unplaced ordered-plan tasks by `sequenceIndex`. Ties break on the id so
    /// the assignment is stable across re-renders — two blocks at the same
    /// minute must not swap tints on a 60s clock tick.
    ///
    /// Completed tasks keep their slot: a finished block still sits in the
    /// day, and renumbering the rest around it would recolor rows the user
    /// hadn't touched.
    static func assignments(
        among tasks: [NudgeTask],
        calendar: Calendar = .current
    ) -> [UUID: Int] {
        let placed = tasks
            .filter { task in
                guard !task.isInformationalEvent,
                      let start = task.plannedStartDate else { return false }
                return calendar.isDateInToday(start)
            }
            .sorted { lhs, rhs in
                let l = lhs.plannedStartDate ?? .distantFuture
                let r = rhs.plannedStartDate ?? .distantFuture
                if l != r { return l < r }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        let placedIDs = Set(placed.map(\.id))

        let unplacedPlan = tasks
            .filter { task in
                !task.isInformationalEvent
                    && task.sequenceIndex != nil
                    && !placedIDs.contains(task.id)
            }
            .sorted { lhs, rhs in
                let l = lhs.sequenceIndex ?? .max
                let r = rhs.sequenceIndex ?? .max
                if l != r { return l < r }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        var slots: [UUID: Int] = [:]
        for (index, task) in (placed + unplacedPlan).enumerated() {
            slots[task.id] = index
        }
        return slots
    }
}
