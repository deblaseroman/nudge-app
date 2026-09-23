//
//  CaptureWriter.swift
//  Nudge
//
//  The capture write site: model output (`ClaudeResponse.tasks`) → store
//  rows. Moved verbatim out of `HomeTabView.sendMessage` (Sep 23 2026) so
//  the eval harness (`eval/run.sh` → `EvalHarness`) exercises the exact
//  code the Home chat runs instead of a copy. No behavior changed in the
//  move; the Home chat calls `apply` where the loop used to be inline.
//

import Foundation
import SwiftData

/// What one capture turn wrote: the rows inserted, and every returned item
/// that did NOT become a row, with its reason (the drop trace).
struct CaptureWriteResult {
    let created: [NudgeTask]
    let dropped: [(title: String, reason: String)]
}

enum CaptureWriter {

    /// Applies the NEW tasks in `response` to `modelContext`: the one-plan
    /// rule, dedupe / replace against `allTasks`, DUE-vs-START, floater
    /// priority, placement, stakes, time window, commitment shape and goal
    /// link. Does not save, does not reevaluate, does not touch
    /// `taskUpdates` — the caller owns everything after the rows exist.
    @MainActor
    static func apply(
        response: ClaudeResponse,
        allTasks: [NudgeTask],
        goalContexts: [ActiveGoalContext],
        modelContext: ModelContext
    ) -> CaptureWriteResult {
        // One active plan at a time: if this response captures a NEW
        // ordered plan, clear sequenceIndex on any surviving tasks
        // from the previous plan first. Those tasks aren't deleted —
        // they just drop back into the normal Unscheduled/Scheduled
        // sections. The new plan then owns 1,2,3…
        let incomingIsPlan = response.tasks.contains { $0.sequenceIndex != nil }
        if incomingIsPlan {
            for task in allTasks where task.sequenceIndex != nil {
                task.sequenceIndex = nil
            }
        }

        // Persist only genuinely NEW tasks
        var newlyCreatedTasks: [NudgeTask] = []
        // Drop-trace (cycle 2026-08-05-02): every item the model
        // returned that does NOT become a row is recorded here with
        // its reason, and reconciled against the returned count after
        // the loop. The Sep 2 event vanished with zero evidence of
        // whether the model omitted it or the app dropped it; this
        // makes that distinction one console line.
        var droppedItems: [(title: String, reason: String)] = []
        for taskData in response.tasks {
            let newTitle = taskData.title.lowercased()
            let newDueDate = Self.parseDateString(taskData.dueDate)

            // Only skip if an INCOMPLETE task with the same title exists
            // for the SAME day. Completed tasks from previous days should
            // not block creating a fresh task for today.
            // `first(where:)` instead of `contains` so the suppressing
            // row can be NAMED in the drop log — same predicate.
            let duplicateOf = allTasks.first { existing in
                guard !existing.isComplete else { return false }
                let existingTitle = existing.title.lowercased()
                let titleMatch = existingTitle == newTitle
                    || existingTitle.contains(newTitle)
                    || newTitle.contains(existingTitle)
                guard titleMatch else { return false }

                if let existingDue = existing.dueDate, let newDue = newDueDate {
                    return Calendar.current.isDate(existingDue, inSameDayAs: newDue)
                }
                return true
            }
            // Roman's rule (Sep 16 2026): a new task identical to one
            // sitting in Overdue or Skipped REPLACES it — the old row
            // is deleted and the fresh one is created below. The
            // user restating the task is the decision.
            if let duplicateOf, duplicateOf.isOverdue || duplicateOf.isSkipped {
                #if DEBUG
                print("[CaptureWriter] REPLACE: \"\(duplicateOf.title)\" (\(duplicateOf.isOverdue ? "overdue" : "skipped")) replaced by the new \"\(taskData.title)\"")
                #endif
                modelContext.delete(duplicateOf)
            } else if let duplicateOf {
                // Which clause suppressed it: both dates present means
                // the same-day comparison matched; otherwise it was
                // the nil-date fallthrough (title match alone).
                let clause = (duplicateOf.dueDate != nil && newDueDate != nil)
                    ? "same-day" : "nil-date fallthrough"
                droppedItems.append((taskData.title,
                    "dedupe vs \"\(duplicateOf.title)\" (\(clause))"))
                #if DEBUG
                print("[CaptureWriter] DROP: \"\(taskData.title)\" suppressed by dedupe — matched existing \"\(duplicateOf.title)\" via \(clause)")
                #endif
                continue
            }

            // Parse dueTime ("3:00 PM") combined with dueDate into specificTime.
            let specificTime = Self.parseSpecificTime(timeString: taskData.dueTime, on: newDueDate)

            // Events keep their event classification even without a
            // time now — a timeless event lands in the Events list with
            // a "needs a time" chip, and the AI's reply asks for the
            // time in one follow-up question. (Previously we demoted
            // timeless events to tasks; that hid genuine plans.)
            let isEvent = taskData.isEvent ?? false

            // DUE vs START (cycle 2026-09-03-01): a task's date is a
            // deadline ONLY when the model said so. "start" (or a
            // missing/unknown dueKind — the cheap wrong guess) means
            // the date is an INTENTION: it goes to intendedDate, plus
            // a manual placement when a clock time was stated, and
            // the deadline fields stay nil so no countdown, overdue
            // state, or dueSoon nudge can ever fabricate from it.
            // Events are untouched: their time is their time.
            let isDeadline = isEvent || taskData.dueKind?.lowercased() == "deadline"
            let intentDay: Date? = (!isDeadline && newDueDate != nil)
                ? Calendar.current.startOfDay(for: newDueDate!) : nil
            let intentStart: Date? = isDeadline ? nil : specificTime

            // Floater detection: no date AND no time → low-priority,
            // "get to it whenever" task. Force low priority unless the
            // AI explicitly said high.
            let isFloater = !isEvent && newDueDate == nil && specificTime == nil
            // Canonical set is high|medium|low. "urgent" left the
            // prompt's allowed values (Jul 2026) but the model may
            // still emit it — fold it into "high" at the write site
            // so no fourth value ever reaches the store again.
            let rawPriority = Self.normalizedPriority(taskData.priority ?? "medium")
            let priority: String = {
                guard isFloater else { return rawPriority }
                return rawPriority == "high" ? rawPriority : "low"
            }()

            let task = NudgeTask(
                title: taskData.title,
                dueDate: isDeadline ? newDueDate : nil,
                dueTime: isDeadline ? taskData.dueTime : nil,
                specificTime: isDeadline ? specificTime : nil,
                priority: priority,
                category: taskData.category,
                source: "capture",
                estimatedMinutes: taskData.estimatedMinutes,
                recurrence: taskData.recurrence,
                isInformationalEvent: isEvent,
                // Ordered-plan position ("first X, then Y") — nil for
                // items the user didn't sequence. Never sets a timeline
                // placement; a plan is a numbered list, not a schedule.
                sequenceIndex: isEvent ? nil : taskData.sequenceIndex
            )
            task.intendedDate = intentDay
            // "Study at 7" is the user scheduling it themselves —
            // a MANUAL placement (plannedIsAuto stays false), which
            // the timeline, planners, and placement nudges already
            // understand. PlacementRollover clears it if the day
            // passes unstarted; intendedDate above survives as the
            // record of the slip.
            if let intentStart {
                task.plannedStartDate = intentStart
                // A stated start with no stated length is an hour
                // (Roman's rule, Sep 2026) — without this the block
                // draws at the 30-minute task fallback and the busy
                // math undercounts the session.
                if task.estimatedMinutes == nil {
                    task.estimatedMinutes = NudgeConfig.defaultTimedIntentMinutes
                }
            }
            // Stakes writes go through the one guarded automation
            // path (never the init) so every non-user writer
            // inherits the user-override protection. Unknown or
            // missing strings parse to nil and leave stakes unset.
            task.setStakesFromAutomation(TaskStakes.parse(taskData.stakes))
            // Study-lead band — meaningful only on exam events;
            // band-validated (3|7|14, else nil) so no invented
            // precision reaches the store.
            if isEvent {
            } else {
                // Appropriateness band — tasks only (events aren't
                // placed). Unknown strings parse to nil, which
                // falls to the deterministic inference at read.
                task.timeWindow = TaskTimeWindow.parse(taskData.timeWindow)
                // Commitment shape (cycle 2026-08-03-01) — marks the
                // task for expansion into daily tasks once its
                // numbers are known. Unknown strings parse to nil:
                // the task stays an ordinary task, the safe default.
                task.commitmentShape = CommitmentShape.parse(taskData.commitmentShape)
                if let count = taskData.commitmentDailyCount, count > 0 {
                    task.commitmentDailyCount = min(count, 99)
                }
                // Second name from capture: the short session name
                // the dailies will carry (the task's own title is
                // the goal name). Only meaningful alongside a
                // shape; blank or missing stays nil and expansion
                // falls back to the goal name.
                if task.commitmentShape != nil,
                   let session = taskData.commitmentSessionTitle?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !session.isEmpty {
                    task.commitmentSessionTitle = session
                }
                // Goal link (item 2, cycle 2026-08-04-03): resolve
                // the model's ref back to the goal's UUID. Tasks
                // only — an unknown ref (hallucinated, or a goal
                // deactivated mid-conversation) resolves to nil,
                // the safe default.
                if let ref = taskData.goalRef,
                   let matched = goalContexts.first(where: { $0.ref == ref }) {
                    task.goalID = matched.id
                    #if DEBUG
                    print("[GoalLink] \"\(task.title)\" → goal \"\(matched.title)\" (\(ref))")
                    #endif
                }
            }
            modelContext.insert(task)
            newlyCreatedTasks.append(task)
        }

        // Count reconciliation: returned = inserted + dropped, every
        // drop named. A mismatch against what the user said is now
        // readable in one line instead of counting parsed-date prints.
        #if DEBUG
        print("[CaptureWriter] CAPTURE: returned=\(response.tasks.count) inserted=\(newlyCreatedTasks.count) dropped=\(droppedItems.count)")
        for item in droppedItems {
            print("[CaptureWriter]   dropped \"\(item.title)\": \(item.reason)")
        }
        #endif
        return CaptureWriteResult(created: newlyCreatedTasks, dropped: droppedItems)
    }

    // MARK: - Date / priority helpers (shared with the task_updates path)

    static func parseDateString(_ dateString: String?) -> Date? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        let parsedDay = parser.date(from: dateString) ?? Date()

        // A bare date (no clock time) means "due by the END of that day."
        // Default to 23:59, NOT midnight — otherwise a task "due today"
        // is instantly overdue against 12:00 AM. When the user gave an
        // explicit time it's applied separately via `specificTime`, which
        // takes precedence in every deadline calculation.
        let calendar = Calendar.current
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: parsedDay) ?? parsedDay

        #if DEBUG
        print("[CaptureWriter] Parsed date: input=\"\(dateString)\" → result=\(endOfDay)")
        #endif

        return endOfDay
    }

    /// Combines a date with a clock-time string ("3:00 PM", "15:00") into a
    /// concrete Date. Returns nil for fuzzy values ("morning", "afternoon",
    /// "evening", "night") or when no time/date is given.
    /// Canonical priority vocabulary is high|medium|low. Older prompts
    /// offered "urgent" as a fourth value that every render surface had to
    /// special-case (or silently fell through on); it was dropped from the
    /// prompt Jul 2026 and folds into "high" here so it can never reach the
    /// store again even if the model still emits it. Existing rows were
    /// normalized by `LegacyPriorityNormalizer`.
    static func normalizedPriority(_ raw: String) -> String {
        raw == "urgent" ? "high" : raw
    }

    static func parseSpecificTime(timeString: String?, on date: Date?) -> Date? {
        guard let timeString, !timeString.isEmpty, let date else { return nil }

        let fuzzy: Set<String> = ["morning", "afternoon", "evening", "night"]
        if fuzzy.contains(timeString.lowercased()) { return nil }

        let formats = ["h:mm a", "h a", "HH:mm", "H:mm"]
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        for format in formats {
            let parser = DateFormatter()
            parser.dateFormat = format
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone.current
            if let parsed = parser.date(from: timeString) {
                let hour = calendar.component(.hour, from: parsed)
                let minute = calendar.component(.minute, from: parsed)
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            }
        }
        return nil
    }

}
