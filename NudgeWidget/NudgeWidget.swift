//
//  NudgeWidget.swift
//  NudgeWidget
//
//  Widget 1 — Main task widget. Shows today's tasks with interactive
//  checkboxes, active goals, and a 7-day streak bar.
//  Background: glassy light surface with green accents and grey outlines.
//  Refreshes every 15 minutes.
//

import WidgetKit
import SwiftUI
import SwiftData
import AppIntents

// MARK: - Snapshot Types

struct TaskSnapshot: Identifiable, Hashable {
    let id: UUID
    let title: String
    let priority: String
    let dueTime: String?
    let isComplete: Bool
    let isInteractive: Bool
    let isGoalFallback: Bool
    /// Pre-formatted countdown string for the most-urgent item only.
    /// `nil` for every other row — those just show day-name via `dueTime`.
    var countdown: String? = nil

    /// Right-side date + clock-time line shown on every task row
    /// ("Jun 17th, 9pm" or "Jun 17th"). Mirrors the in-app row layout.
    /// `nil` for floaters and goal-fallback rows.
    var dueDateLine: String? = nil

    /// Subtitle under the title ("12 hours left", "5 days away",
    /// "3 hours ago"). Hidden for far-future and at night to keep the
    /// row calm when there's no time pressure to surface.
    var remainingLine: String? = nil
}

struct GoalSnapshot: Identifiable, Hashable {
    let id: UUID
    let title: String
    let emoji: String
}

/// Lightweight read-model for an informational event (class, work shift,
/// appointment) shown in the widget alongside the task list.
struct EventSnapshot: Identifiable, Hashable {
    let id: UUID
    let title: String
    let startTime: Date
    let category: String?

    /// "9:00 AM" formatted.
    var timeLabel: String {
        WidgetFormatters.clockTime.string(from: startTime)
    }
}

// MARK: - Timeline Entry

struct NudgeTaskEntry: TimelineEntry {
    let date: Date
    let tasks: [TaskSnapshot]
    let events: [EventSnapshot]
    let goals: [GoalSnapshot]
    let currentStreak: Int
    let weekActivity: [Bool]   // last 7 days — index 0 = 6 days ago, 6 = today
    let urgentCount: Int
    let completedToday: Int
    let totalToday: Int

    // Session state (read from app group UserDefaults)
    let isSessionActive: Bool
    let isSessionPaused: Bool
    let sessionTimerEndDate: Date?
    let sessionPausedRemaining: Int?
    let activeTaskID: UUID?

    static var placeholder: NudgeTaskEntry {
        NudgeTaskEntry(
            date: Date(),
            tasks: mockTasks,
            events: mockEvents,
            goals: mockGoals,
            currentStreak: 3,
            weekActivity: [false, true, true, false, true, true, true],
            urgentCount: 1,
            completedToday: 0,
            totalToday: mockTasks.count,
            isSessionActive: false,
            isSessionPaused: false,
            sessionTimerEndDate: nil,
            sessionPausedRemaining: nil,
            activeTaskID: nil
        )
    }

    static var empty: NudgeTaskEntry {
        NudgeTaskEntry(
            date: Date(),
            tasks: [],
            events: [],
            goals: [],
            currentStreak: 0,
            weekActivity: Array(repeating: false, count: 7),
            urgentCount: 0,
            completedToday: 0,
            totalToday: 0,
            isSessionActive: false,
            isSessionPaused: false,
            sessionTimerEndDate: nil,
            sessionPausedRemaining: nil,
            activeTaskID: nil
        )
    }

    static var mock: NudgeTaskEntry {
        NudgeTaskEntry(
            date: Date(),
            tasks: mockTasks,
            events: mockEvents,
            goals: mockGoals,
            currentStreak: 3,
            weekActivity: [false, true, true, false, true, true, true],
            urgentCount: 1,
            completedToday: 0,
            totalToday: mockTasks.count,
            isSessionActive: false,
            isSessionPaused: false,
            sessionTimerEndDate: nil,
            sessionPausedRemaining: nil,
            activeTaskID: nil
        )
    }

    private static let mockEvents: [EventSnapshot] = [
        EventSnapshot(
            id: UUID(),
            title: "Bio 101 lecture",
            startTime: Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date(),
            category: "school"
        ),
        EventSnapshot(
            id: UUID(),
            title: "Work shift",
            startTime: Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date(),
            category: "work"
        )
    ]

    private static let mockTasks: [TaskSnapshot] = [
        TaskSnapshot(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Review biology quiz notes",
            priority: "high",
            dueTime: "4:00 PM",
            isComplete: false,
            isInteractive: true,
            isGoalFallback: false
        ),
        TaskSnapshot(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Email professor about office hours",
            priority: "medium",
            dueTime: "5:30 PM",
            isComplete: false,
            isInteractive: true,
            isGoalFallback: false
        ),
        TaskSnapshot(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "Laundry and groceries",
            priority: "medium",
            dueTime: "Tomorrow",
            isComplete: false,
            isInteractive: true,
            isGoalFallback: false
        ),
        TaskSnapshot(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            title: "Outline history paper",
            priority: "low",
            dueTime: "This week",
            isComplete: false,
            isInteractive: true,
            isGoalFallback: false
        ),
    ]

    private static var mockGoals: [GoalSnapshot] {
        [
            GoalSnapshot(id: UUID(), title: "Read more", emoji: "\u{1F4DA}"),
            GoalSnapshot(id: UUID(), title: "Work out", emoji: "\u{1F4AA}"),
            GoalSnapshot(id: UUID(), title: "Journal", emoji: "\u{270D}\u{FE0F}"),
        ]
    }
}

// MARK: - Widget Colors (light theme)

private enum WidgetColors {
    static let background = Color(red: 0.965, green: 0.976, blue: 0.967)
    static let surface = Color.white
    static let accent = Color(red: 0.451, green: 0.576, blue: 0.702)
    static let accentSoft = Color(red: 0.451, green: 0.576, blue: 0.702).opacity(0.16)
    static let goalAccent = Color(red: 0.329, green: 0.643, blue: 0.467)
    static let goalAccentSoft = goalAccent.opacity(0.12)
    static let neutral = Color(red: 0.55, green: 0.58, blue: 0.56)
    static let textPrimary = Color(red: 0.11, green: 0.13, blue: 0.12)
    static let textSecondary = Color(red: 0.11, green: 0.13, blue: 0.12).opacity(0.72)
    static let textMuted = Color(red: 0.11, green: 0.13, blue: 0.12).opacity(0.45)
    static let streakActive = accent
    static let streakInactive = Color(red: 0.11, green: 0.13, blue: 0.12).opacity(0.12)
    static let checkboxBorder = Color(red: 0.49, green: 0.53, blue: 0.5).opacity(0.28)
    static let divider = Color(red: 0.49, green: 0.53, blue: 0.5).opacity(0.14)
    static let pillBackground = accentSoft
    static let chipBackground = Color(red: 0.49, green: 0.53, blue: 0.5).opacity(0.08)
}

// MARK: - Shared Widget Schema & Container

/// MUST stay in lockstep with `SharedModelContainer.schema` in the main
/// app. Both targets open the same Nudge.store file in the App Group
/// container, and SwiftData logs a persistent-history truncation warning
/// for any entity present in the store but missing from the opening
/// schema. Omitting models the widget doesn't query is fine in isolation,
/// but here it pollutes the console and forces CoreData to drop change
/// history that the main app legitimately needs.
let widgetSchema = Schema([
    NudgeTask.self,
    NudgeGoal.self,
    NudgeHabit.self,
    UserProfile.self,
    DailyStats.self,
    DailySession.self,
    CheckIn.self,
    CompletedTaskRecord.self,
    TimeBlock.self,
    EngagementState.self,
    NotificationEvent.self,
    SentNotificationFlag.self,
    NudgeOutcome.self,
    TaskIntelligence.self,
    CategoryDurationStats.self,
    EventDurationStats.self,
])

private let widgetAppGroupID = "group.com.deblaser.nudge"

/// Creates a ModelConfiguration that points at the same Nudge.store the main app uses.
func makeWidgetModelConfiguration() -> ModelConfiguration {
    if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: widgetAppGroupID) {
        let storeURL = groupURL.appendingPathComponent("Nudge.store")
        return ModelConfiguration(schema: widgetSchema, url: storeURL)
    }
    // Fallback — should never happen if entitlements are correct
    return ModelConfiguration(schema: widgetSchema, isStoredInMemoryOnly: false)
}

let widgetModelContainer: ModelContainer = {
    do {
        return try ModelContainer(for: widgetSchema, configurations: [makeWidgetModelConfiguration()])
    } catch {
        fatalError("Could not create widget ModelContainer: \(error)")
    }
}()

// MARK: - Shared DateFormatters
//
// The widget renders 3–6 task rows per refresh, and the formatter calls
// below used to instantiate a fresh `DateFormatter()` on each call —
// expensive (locale + calendar lookup) and a steady drip of allocations
// in the 30 MB-capped extension. These cached statics get reused across
// every row in every refresh.

private enum WidgetFormatters {
    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()
    static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    static let clockTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    /// Used by `dueDateLine` for ":00" minute case → "9pm".
    static let clockTimeHourOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "ha"; return f
    }()
    /// Used by `dueDateLine` when minutes are non-zero → "9:30pm".
    static let clockTimeWithMinutes: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mma"; return f
    }()
}

// MARK: - Timeline Provider

struct NudgeTaskProvider: TimelineProvider {
    private let completionDisplayDuration: TimeInterval = 1.5

    private struct TimelineState {
        let entry: NudgeTaskEntry
        let nextUpdate: Date
    }

    func placeholder(in context: Context) -> NudgeTaskEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (NudgeTaskEntry) -> ()) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(fetchTimelineState().entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NudgeTaskEntry>) -> ()) {
        let state = fetchTimelineState()
        let timeline = Timeline(entries: [state.entry], policy: .after(state.nextUpdate))
        completion(timeline)
    }

    // MARK: - Data Fetching

    private func fetchTimelineState() -> TimelineState {
        do {
            let context = ModelContext(widgetModelContainer)

            let calendar = Calendar.current
            let now = Date()
            let startOfToday = calendar.startOfDay(for: now)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
            let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
            let defaultNextUpdate = calendar.date(byAdding: .minute, value: 15, to: now)!

            // SCOPED FETCHES — the widget extension has a strict ~30 MB
            // memory ceiling, so we never pull the full NudgeTask history.
            // Three narrow queries with fetchLimit caps cover everything
            // the widget actually renders.
            //
            // 1) Open actionable tasks  — the visible list (cap 50)
            // 2) Recently completed     — for the 1.5s post-tap animation
            //                             AND the 7-day streak (cap 100)
            // 3) Today's events         — informational entries (cap 20)
            //
            // A previous version did one `FetchDescriptor<NudgeTask>()` with
            // no predicate and filtered in memory; users with months of
            // history would blow the ceiling and the extension would be
            // killed with "Terminated due to memory issue" after ~10 min.

            var openDescriptor = FetchDescriptor<NudgeTask>(
                predicate: #Predicate { !$0.isComplete && !$0.isInformationalEvent }
            )
            openDescriptor.fetchLimit = 50
            let openActionable = try context.fetch(openDescriptor)

            // Use `Date.distantPast` explicitly — the SwiftData `#Predicate`
            // macro can't resolve the `.distantPast` shorthand.
            let distantPastSentinel = Date.distantPast
            var recentDoneDescriptor = FetchDescriptor<NudgeTask>(
                predicate: #Predicate<NudgeTask> { task in
                    task.isComplete &&
                    !task.isInformationalEvent &&
                    (task.completedAt ?? distantPastSentinel) >= sevenDaysAgo
                }
            )
            recentDoneDescriptor.fetchLimit = 100
            let recentDone = try context.fetch(recentDoneDescriptor)

            var eventDescriptor = FetchDescriptor<NudgeTask>(
                predicate: #Predicate { $0.isInformationalEvent }
            )
            eventDescriptor.fetchLimit = 20
            let allFetchedEvents = try context.fetch(eventDescriptor)

            // Today's events: informational items with a specificTime falling
            // anywhere today. Take only the next 2 that haven't started yet.
            let todaysEvents = allFetchedEvents
                .filter { task in
                    guard let t = task.specificTime else { return false }
                    return t >= startOfToday && t < endOfToday && t >= now
                }
                .sorted { ($0.specificTime ?? .distantFuture) < ($1.specificTime ?? .distantFuture) }
            let eventSnapshots = todaysEvents.prefix(2).map { event in
                EventSnapshot(
                    id: event.id,
                    title: event.title,
                    startTime: event.specificTime ?? Date(),
                    category: event.category
                )
            }

            // Visible tasks: incomplete + recently completed (stays in-place for animation)
            let recentlyAnimatedDone = recentDone.filter { task in
                guard let completedAt = task.completedAt else { return false }
                return now.timeIntervalSince(completedAt) < completionDisplayDuration
            }
            let visibleTasks = openActionable + recentlyAnimatedDone
            let recentlyCompletedTasks = recentlyAnimatedDone

            let todayCompletedCount = recentDone.filter { task in
                guard let completedAt = task.completedAt else { return false }
                return completedAt >= startOfToday && completedAt < endOfToday
            }.count

            let incompleteTasks = openActionable
            let totalToday = incompleteTasks.count + todayCompletedCount

            let urgentCount = incompleteTasks.filter { task in
                task.isOverdue || task.priority == "high"
            }.count

            // Sort visible tasks (incomplete + recently completed) together
            // so completed tasks stay in their original position for smooth animation
            let sortedVisible = visibleTasks.sorted { lhs, rhs in
                // Completed tasks sink below incomplete ones
                if lhs.isComplete != rhs.isComplete {
                    return !lhs.isComplete
                }
                let leftBucket = sortBucket(for: lhs)
                let rightBucket = sortBucket(for: rhs)
                if leftBucket != rightBucket {
                    return leftBucket < rightBucket
                }
                return lhs.sortDeadline < rhs.sortDeadline
            }

            var goalDescriptor = FetchDescriptor<NudgeGoal>(
                predicate: #Predicate { $0.isActive }
            )
            goalDescriptor.fetchLimit = 10
            let activeGoals = try context.fetch(goalDescriptor)
            let goalSnapshots = activeGoals.prefix(3).map { goal in
                GoalSnapshot(id: goal.id, title: goal.title, emoji: goal.emoji)
            }

            // Identify the single most-urgent task — gets a countdown label.
            // Everything else shows the day name only (Rule 9).
            let incompleteSorted = sortedVisible.filter { !$0.isComplete }
            let mostUrgentID = incompleteSorted.first?.id

            let taskSnapshots = sortedVisible.prefix(6).map { task -> TaskSnapshot in
                let isUrgent = task.id == mostUrgentID && !task.isComplete
                return TaskSnapshot(
                    id: task.id,
                    title: task.title,
                    priority: task.priority,
                    dueTime: WidgetCountdownFormatter.dayName(for: task, now: now),
                    isComplete: task.isComplete,
                    isInteractive: !task.isComplete,
                    isGoalFallback: false,
                    countdown: isUrgent
                        ? WidgetCountdownFormatter.countdown(for: task, now: now)
                        : nil,
                    dueDateLine: WidgetCountdownFormatter.dueDateLine(for: task),
                    remainingLine: WidgetCountdownFormatter.remainingLine(for: task, now: now)
                )
            }

            let displayTasks: [TaskSnapshot]
            if !taskSnapshots.isEmpty {
                displayTasks = Array(taskSnapshots)
            } else if let featuredGoal = activeGoals.first {
                displayTasks = [
                    TaskSnapshot(
                        id: featuredGoal.id,
                        title: featuredGoal.title,
                        priority: "medium",
                        dueTime: "Goal in motion",
                        isComplete: false,
                        isInteractive: false,
                        isGoalFallback: true
                    )
                ]
            } else {
                displayTasks = []
            }

            // Week activity: for each of the last 7 days, did the user
            // complete a task? Uses the already-scoped `recentDone` fetch.
            var weekActivity: [Bool] = []
            for dayOffset in 0..<7 {
                let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: sevenDaysAgo)!
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let hasCompletion = recentDone.contains { task in
                    guard let c = task.completedAt else { return false }
                    return c >= dayStart && c < dayEnd
                }
                weekActivity.append(hasCompletion)
            }

            // Streak: consecutive active days going backward from today
            var streak = 0
            for i in stride(from: 6, through: 0, by: -1) {
                if weekActivity[i] { streak += 1 } else { break }
            }

            // Read session state from app group UserDefaults
            let sessionDefaults = UserDefaults(suiteName: "group.com.deblaser.nudge")
            let sessionDict = sessionDefaults?.dictionary(forKey: "activeSessionState")
            let sessionActive = (sessionDict?["isActive"] as? Bool) ?? false
            let sessionPaused = (sessionDict?["isPaused"] as? Bool) ?? false
            let sessionPausedRemaining = sessionDict?["pausedTimeRemaining"] as? Int
            let sessionEndDate: Date? = {
                guard let interval = sessionDict?["timerEndDate"] as? TimeInterval else { return nil }
                return Date(timeIntervalSince1970: interval)
            }()
            let activeTaskID: UUID? = {
                guard let idString = sessionDict?["currentTaskID"] as? String, !idString.isEmpty else { return nil }
                return UUID(uuidString: idString)
            }()

            let liveEntry = NudgeTaskEntry(
                date: Date(),
                tasks: displayTasks,
                events: Array(eventSnapshots),
                goals: Array(goalSnapshots),
                currentStreak: streak,
                weekActivity: weekActivity,
                urgentCount: urgentCount,
                completedToday: todayCompletedCount,
                totalToday: totalToday,
                isSessionActive: sessionActive,
                isSessionPaused: sessionPaused,
                sessionTimerEndDate: sessionEndDate,
                sessionPausedRemaining: sessionPaused ? sessionPausedRemaining : nil,
                activeTaskID: activeTaskID
            )
            let recentCompletionExpiry = recentlyCompletedTasks
                .compactMap { $0.completedAt?.addingTimeInterval(completionDisplayDuration) }
                .min()

            return TimelineState(
                entry: liveEntry,
                nextUpdate: recentCompletionExpiry ?? defaultNextUpdate
            )
        } catch {
            let fallbackNextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            return TimelineState(entry: .empty, nextUpdate: fallbackNextUpdate)
        }
    }

    private func formatDueTime(_ task: NudgeTask) -> String? {
        if let specificTime = task.specificTime {
            return WidgetFormatters.clockTime.string(from: specificTime)
        }
        return task.dueTime
    }

    private func sortBucket(for task: NudgeTask) -> Int {
        if task.isOverdue {
            return 0
        }

        if task.sortDeadline != .distantFuture {
            return 1
        }

        return 2
    }
}

/// Widget-side mirror of CountdownLabel's text logic. Returns the same
/// phrasing the in-app label uses so the widget reads consistently. The
/// widget only refreshes every 15 min, so this is computed at timeline-
/// snapshot time — not live.
enum WidgetCountdownFormatter {
    /// Day-name (or date) string for the non-urgent rows. Per Rule 9.
    static func dayName(for task: NudgeTask, now: Date) -> String? {
        guard let deadline = task.specificTime ?? task.dueDate else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(deadline) {
            // Within today — show time if we have one, else "Today".
            if let specific = task.specificTime {
                return WidgetFormatters.clockTime.string(from: specific)
            }
            return "Today"
        }
        if calendar.isDateInTomorrow(deadline) { return "Tomorrow" }
        let days = calendar.dateComponents([.day], from: now, to: deadline).day ?? 0
        if days > 0 && days <= 7 {
            return WidgetFormatters.weekday.string(from: deadline)
        }
        return WidgetFormatters.monthDay.string(from: deadline)
    }

    /// Countdown label for the most-urgent row only. Implements rules 1–7
    /// from the CountdownLabel spec.
    static func countdown(for task: NudgeTask, now: Date) -> String? {
        guard let deadline = task.specificTime ?? task.dueDate else { return nil }
        let interval = deadline.timeIntervalSince(now)

        // Rule 6 — overdue
        if interval < 0 {
            return "Was due \(timeAgo(-interval))"
        }

        // Rule 7 — night suppression
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 23 || hour < 7 { return nil }

        let hours = interval / 3600
        let days  = hours / 24
        let prefix = pickPrefix(task: task)

        if days > 7 {
            return "\(prefix) \(WidgetFormatters.monthDay.string(from: deadline))"
        }
        if days >= 3 {
            return "\(prefix) \(WidgetFormatters.weekday.string(from: deadline)) · \(Int(days.rounded())) days away"
        }
        if hours >= 24 {
            return "\(prefix) in \(Int(hours.rounded())) hours"
        }
        if hours >= 3 {
            return "\(prefix) in \(Int(hours.rounded())) hours"
        }
        // Rule 5 — under 3 hours: hr+min
        let totalMinutes = Int((interval / 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(prefix) in \(m)min" }
        if m == 0 { return "\(prefix) in \(h)hr" }
        return "\(prefix) in \(h)hr \(m)min"
    }

    private static func pickPrefix(task: NudgeTask) -> String {
        let t = task.title.lowercased()
        if t.contains("exam") || t.contains("midterm") || t.contains("final") { return "Exam" }
        if t.contains("quiz") { return "Quiz" }
        if t.contains("presentation") { return "Presentation" }
        if task.isInformationalEvent {
            switch task.category {
            case "school": return "Class"
            case "work":   return "Work"
            default:       return "Starts"
            }
        }
        return "Due"
    }

    private static func timeAgo(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes <= 1 ? "1 minute ago" : "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    // MARK: - Split-row helpers
    //
    // Mirror the in-app `CountdownState.dueDateLine` and `.remainingLine`
    // helpers so the widget row reads the same as the task list. Kept
    // in lockstep with the in-app version — any tweak to format there
    // should be applied here too.

    /// "Jun 17th, 9pm" for timed tasks, "Jun 17th" when only date is set,
    /// nil for floaters.
    static func dueDateLine(for task: NudgeTask) -> String? {
        let anchor = task.specificTime ?? task.dueDate
        guard let anchor else { return nil }
        let day = Calendar.current.component(.day, from: anchor)
        let datePart = WidgetFormatters.monthDay.string(from: anchor) + ordinalSuffix(for: day)
        if task.specificTime != nil {
            return "\(datePart), \(formatClockTime(anchor))"
        }
        return datePart
    }

    /// "12 hours left" / "5 days away" / "3 hours ago", hidden for
    /// far-future and at night. Threshold: hours-left below 48h,
    /// days-away above 48h (matches in-app).
    static func remainingLine(for task: NudgeTask, now: Date) -> String? {
        guard let deadline = task.specificTime ?? task.dueDate else { return nil }
        let interval = deadline.timeIntervalSince(now)
        if interval < 0 { return timeAgo(-interval) }

        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 23 || hour < 7 { return nil }

        let hoursOut = interval / 3600
        let daysOut  = hoursOut / 24
        if daysOut > 7 { return nil }
        if hoursOut >= 48 {
            let n = Int(daysOut.rounded())
            return n == 1 ? "1 day away" : "\(n) days away"
        }
        if hoursOut >= 3 {
            let n = Int(hoursOut.rounded())
            return n == 1 ? "1 hour left" : "\(n) hours left"
        }
        let totalMinutes = Int((interval / 60).rounded())
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(m)min" }
        if m == 0 { return "\(h)hr" }
        return "\(h)hr \(m)min"
    }

    private static func ordinalSuffix(for day: Int) -> String {
        if (11...13).contains(day) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func formatClockTime(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        let formatter = minute == 0
            ? WidgetFormatters.clockTimeHourOnly
            : WidgetFormatters.clockTimeWithMinutes
        return formatter.string(from: date).lowercased()
    }
}

private extension NudgeTask {
    var sortDeadline: Date {
        if let specificTime {
            return specificTime
        }

        if let dueDate {
            let startOfDay = Calendar.current.startOfDay(for: dueDate)
            return Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? dueDate
        }

        return .distantFuture
    }

    var isOverdue: Bool {
        !isComplete && sortDeadline < Date()
    }
}

// MARK: - Widget View

struct NudgeTaskWidgetView: View {
    var entry: NudgeTaskEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                largeLayout
            default:
                mediumLayout
            }
        }
        .background(WidgetColors.surface)
        .overlay {
            ContainerRelativeShape()
                .strokeBorder(WidgetColors.neutral.opacity(0.28), lineWidth: 1)
        }
        .contentTransition(.interpolate)
    }

    // MARK: - Medium Layout

    private var mediumLayout: some View {
        VStack(spacing: 0) {
            compactHeader

            Rectangle()
                .fill(WidgetColors.divider)
                .frame(height: 1)

            if entry.tasks.isEmpty {
                emptyStateView
            } else {
                mediumTaskList
            }

            if !entry.events.isEmpty {
                Rectangle()
                    .fill(WidgetColors.divider)
                    .frame(height: 1)
                eventsRow
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(WidgetColors.divider)
                .frame(height: 1)

            mediumFooter
        }
    }

    // MARK: - Large Layout

    private var largeLayout: some View {
        VStack(spacing: 0) {
            spaciousHeader

            Rectangle()
                .fill(WidgetColors.divider)
                .frame(height: 1)

            if entry.tasks.isEmpty {
                emptyStateView
            } else {
                largeTaskList
            }

            if !entry.events.isEmpty {
                Rectangle()
                    .fill(WidgetColors.divider)
                    .frame(height: 1)
                eventsRow
            }

            Spacer(minLength: 0)

            if !entry.goals.isEmpty {
                Rectangle()
                    .fill(WidgetColors.divider)
                    .frame(height: 1)
                largeGoalSection
            }

            Rectangle()
                .fill(WidgetColors.divider)
                .frame(height: 1)

            sessionStartFooter
        }
    }

    // MARK: - Headers

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Image("mascot-default")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("nudge")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetColors.textPrimary)
                    Text("tasks")
                        .font(.system(size: 11))
                        .foregroundStyle(WidgetColors.textSecondary)
                }

                Text(compactStatusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(entry.urgentCount > 0 ? WidgetColors.accent : WidgetColors.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(entry.completedToday)/\(max(entry.totalToday, 1))")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetColors.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(WidgetColors.pillBackground)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var spaciousHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image("mascot-default")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("nudge")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetColors.textPrimary)
                    Text("\u{00B7}")
                        .foregroundStyle(WidgetColors.textMuted)
                    Text("today")
                        .font(.system(size: 13))
                        .foregroundStyle(WidgetColors.textSecondary)
                }

                Text(largeStatusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.urgentCount > 0 ? WidgetColors.accent : WidgetColors.textMuted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 3) {
                    Text("\u{1F525}")
                        .font(.system(size: 11))
                    Text("\(entry.currentStreak)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetColors.textPrimary)
                }

                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { index in
                        Circle()
                            .fill(entry.weekActivity[index] ? WidgetColors.streakActive : WidgetColors.streakInactive)
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Task Lists

    private var mediumTaskList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.tasks.prefix(3).enumerated()), id: \.element.id) { index, task in
                WidgetTaskRow(
                    task: task,
                    family: .systemMedium,
                    isActiveSessionTask: entry.isSessionActive && entry.activeTaskID == task.id,
                    isSessionPaused: entry.isSessionPaused,
                    sessionTimerEndDate: entry.sessionTimerEndDate,
                    sessionPausedRemaining: entry.sessionPausedRemaining
                )

                if index < min(entry.tasks.count, 3) - 1 {
                    Rectangle()
                        .fill(WidgetColors.divider)
                        .frame(height: 1)
                        .padding(.leading, 30)
                }
            }
        }
    }

    private var largeTaskList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.tasks.prefix(3).enumerated()), id: \.element.id) { index, task in
                WidgetTaskRow(
                    task: task,
                    family: .systemLarge,
                    isActiveSessionTask: entry.isSessionActive && entry.activeTaskID == task.id,
                    isSessionPaused: entry.isSessionPaused,
                    sessionTimerEndDate: entry.sessionTimerEndDate,
                    sessionPausedRemaining: entry.sessionPausedRemaining
                )

                if index < min(entry.tasks.count, 3) - 1 {
                    Rectangle()
                        .fill(WidgetColors.divider)
                        .frame(height: 1)
                        .padding(.leading, 36)
                }
            }
        }
    }

    // MARK: - Events Row (shared between layouts)

    /// Compact horizontal strip showing up to 2 upcoming events for today.
    /// Hidden when there are no events so the layout stays balanced.
    @ViewBuilder
    private var eventsRow: some View {
        if !entry.events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WidgetColors.textMuted)
                    Text("Today")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(WidgetColors.textMuted)
                        .tracking(0.5)
                }

                HStack(spacing: 8) {
                    ForEach(entry.events) { event in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.timeLabel)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetColors.accent)
                                .monospacedDigit()
                            Text(event.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(WidgetColors.textPrimary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(WidgetColors.accent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Footers

    private var mediumFooter: some View {
        HStack(spacing: 0) {
            if entry.isSessionActive {
                // Session controls — icon-only buttons to fit medium width
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WidgetColors.accent)

                    sessionTimerText
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.isSessionPaused ? Color(red: 0.95, green: 0.6, blue: 0.2) : WidgetColors.accent)
                        .monospacedDigit()

                    if entry.isSessionPaused {
                        Text("Paused")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color(red: 0.95, green: 0.6, blue: 0.2))
                    }

                    Spacer()

                    // Pause / Resume — tapping opens the app to the
                    // tasks tab where the user controls the session.
                    Link(destination: URL(string: "nudge://focus-session")!) {
                        Image(systemName: entry.isSessionPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 22)
                            .background(Color(red: 0.95, green: 0.6, blue: 0.2))
                            .clipShape(Capsule())
                    }

                    // End — also opens the app rather than acting in-widget.
                    Link(destination: URL(string: "nudge://focus-session")!) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 22)
                            .background(Color(red: 0.85, green: 0.25, blue: 0.25))
                            .clipShape(Capsule())
                    }
                }
            } else {
                // Goals summary on the left
                HStack(spacing: 4) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(WidgetColors.accent)

                    Text(entry.goals.prefix(2).map(\.title).joined(separator: " \u{2022} ").isEmpty ? "No goals yet" : entry.goals.prefix(2).map(\.title).joined(separator: " \u{2022} "))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(WidgetColors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                // Session start — opens the app to the tasks tab where
                // the user picks a task and starts the session manually.
                // No auto-start; the widget is just a launcher.
                Link(destination: URL(string: "nudge://focus-session")!) {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text("Start")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(WidgetColors.accent)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var sessionStartFooter: some View {
        Group {
            if entry.isSessionActive {
                HStack(spacing: 8) {
                    // Timer + status
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)

                    sessionTimerText
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()

                    if entry.isSessionPaused {
                        Text("Paused")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    // Pause / Resume — opens the app to the tasks tab.
                    Link(destination: URL(string: "nudge://focus-session")!) {
                        Image(systemName: entry.isSessionPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(WidgetColors.accent)
                            .frame(width: 30, height: 26)
                            .background(.white)
                            .clipShape(Capsule())
                    }

                    // End — also opens the app rather than acting in-widget.
                    Link(destination: URL(string: "nudge://focus-session")!) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 26)
                            .background(Color(red: 0.85, green: 0.25, blue: 0.25))
                            .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(WidgetColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // Start — opens the app to the tasks tab where the user
                // picks a task and starts manually. No auto-start.
                Link(destination: URL(string: "nudge://focus-session")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Start Session")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(WidgetColors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Session Timer Helper

    @ViewBuilder
    private var sessionTimerText: some View {
        if entry.isSessionPaused, let remaining = entry.sessionPausedRemaining {
            let minutes = remaining / 60
            let seconds = remaining % 60
            Text(String(format: "%d:%02d", minutes, seconds))
        } else if let endDate = entry.sessionTimerEndDate {
            Text(timerInterval: Date()...endDate, countsDown: true)
        } else {
            Text("--:--")
        }
    }

    // MARK: - Goals & Empty State

    private var largeGoalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Goals in motion")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(WidgetColors.textMuted)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ForEach(entry.goals.prefix(3)) { goal in
                    HStack(spacing: 4) {
                        Text(goal.emoji)
                            .font(.system(size: 11))
                        Text(goal.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WidgetColors.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(WidgetColors.chipBackground)
                    .clipShape(Capsule())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("All clear!")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WidgetColors.textPrimary)
            Text("No tasks for today")
                .font(.system(size: 12))
                .foregroundStyle(WidgetColors.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status Text

    private var compactStatusText: String {
        if entry.urgentCount > 0 {
            return "\(entry.urgentCount) urgent"
        }

        if entry.totalToday > 0 {
            return "\(entry.totalToday) tasks in list"
        }

        return "light day"
    }

    private var largeStatusText: String {
        if entry.urgentCount > 0 {
            return "\(entry.urgentCount) urgent, sort the top ones first"
        }

        if entry.totalToday > 0 {
            return "\(entry.totalToday) tasks in your list"
        }

        return "Nothing pressing yet"
    }
}

// MARK: - Task Row

struct WidgetTaskRow: View {
    let task: TaskSnapshot
    let family: WidgetFamily
    var isActiveSessionTask: Bool = false
    var isSessionPaused: Bool = false
    var sessionTimerEndDate: Date? = nil
    var sessionPausedRemaining: Int? = nil

    private var isLarge: Bool {
        family == .systemLarge
    }

    private let checkboxSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            // Priority pip — fades to accent blue when complete
            RoundedRectangle(cornerRadius: 1.5)
                .fill(task.isComplete ? rowAccentColor : pipColor)
                .frame(width: 3, height: isLarge ? 24 : 20)

            // Checkbox with blue checkmark
            Group {
                if task.isInteractive {
                    Button(intent: CompleteTaskIntent(taskID: task.id.uuidString)) {
                        checkbox
                    }
                    .buttonStyle(WidgetCheckboxButtonStyle(accentColor: rowAccentColor, isLarge: isLarge))
                    .padding(.horizontal, isLarge ? 10 : 8)
                    .padding(.vertical, isLarge ? 8 : 6)
                    .contentShape(Rectangle())
                } else {
                    checkbox
                        .padding(.horizontal, isLarge ? 10 : 8)
                        .padding(.vertical, isLarge ? 8 : 6)
                }
            }

            // Title + optional "12 hours left" subtitle (only when the
            // remainingLine field is populated — i.e., the task is not
            // far-future, not at night, and not the goal-fallback row).
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: isLarge ? 13 : 11.5, weight: task.isComplete ? .regular : .medium))
                    .foregroundStyle(task.isGoalFallback ? rowAccentColor : (task.isComplete ? WidgetColors.textMuted : WidgetColors.textPrimary))
                    .lineLimit(1)
                    .strikethrough(task.isComplete, color: WidgetColors.textMuted)

                if !task.isComplete, let remaining = task.remainingLine {
                    Text(remaining)
                        .font(.system(size: isLarge ? 10 : 9))
                        .foregroundStyle(WidgetColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Due time — replaced with checkmark badge when complete, or timer when session active
            if task.isComplete {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: isLarge ? 10 : 9))
                    Text("Done")
                        .font(.system(size: isLarge ? 10 : 9, weight: .semibold))
                }
                .foregroundStyle(rowAccentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(rowAccentColor.opacity(0.12))
                .clipShape(Capsule())
            } else if isActiveSessionTask {
                HStack(spacing: 3) {
                    Image(systemName: isSessionPaused ? "pause.fill" : "bolt.fill")
                        .font(.system(size: isLarge ? 9 : 8))
                    if isSessionPaused, let remaining = sessionPausedRemaining {
                        let minutes = remaining / 60
                        let seconds = remaining % 60
                        Text(String(format: "%d:%02d", minutes, seconds))
                            .font(.system(size: isLarge ? 10 : 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    } else if let endDate = sessionTimerEndDate {
                        Text(timerInterval: Date()...endDate, countsDown: true)
                            .font(.system(size: isLarge ? 10 : 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(isSessionPaused ? Color(red: 0.95, green: 0.6, blue: 0.2) : rowAccentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((isSessionPaused ? Color(red: 0.95, green: 0.6, blue: 0.2) : rowAccentColor).opacity(0.15))
                .clipShape(Capsule())
            } else if let dueLine = task.dueDateLine {
                // Right-side date + clock-time ("Jun 17th, 9pm").
                // Matches the in-app row layout.
                Text(dueLine)
                    .font(.system(size: isLarge ? 10 : 9))
                    .foregroundStyle(WidgetColors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if let dueTime = task.dueTime {
                // Fallback for goal-fallback rows + placeholder data that
                // populate dueTime but not dueDateLine.
                Text(dueTime)
                    .font(.system(size: isLarge ? 10 : 9))
                    .foregroundStyle(task.isGoalFallback ? rowAccentColor : WidgetColors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .opacity(task.isComplete ? 0.85 : 1.0)
        .padding(.horizontal, isLarge ? 10 : 8)
        .background(rowBackgroundColor)
        .contentTransition(.interpolate)
    }

    private var pipColor: Color {
        if task.isGoalFallback {
            return WidgetColors.goalAccent
        }

        switch task.priority {
        case "high": return WidgetColors.accent
        case "medium": return WidgetColors.neutral.opacity(0.75)
        case "low": return WidgetColors.textMuted
        default: return WidgetColors.neutral.opacity(0.75)
        }
    }

    private var rowAccentColor: Color {
        task.isGoalFallback ? WidgetColors.goalAccent : WidgetColors.accent
    }

    private var rowBackgroundColor: Color {
        if task.isGoalFallback {
            return WidgetColors.goalAccentSoft
        }

        if task.isComplete {
            return WidgetColors.accent.opacity(0.06)
        }

        if isActiveSessionTask {
            return WidgetColors.accent.opacity(0.08)
        }

        return .clear
    }

    private var checkbox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isLarge ? 5 : 4)
                .fill(task.isComplete ? rowAccentColor : Color.clear)
                .frame(width: isLarge ? checkboxSize : 15, height: isLarge ? checkboxSize : 15)

            RoundedRectangle(cornerRadius: isLarge ? 5 : 4)
                .strokeBorder(
                    task.isComplete ? rowAccentColor : (task.isGoalFallback ? WidgetColors.goalAccent.opacity(0.45) : WidgetColors.checkboxBorder),
                    lineWidth: 1.5
                )
                .frame(width: isLarge ? checkboxSize : 15, height: isLarge ? checkboxSize : 15)

            if task.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: isLarge ? 10 : 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
        }
        .contentTransition(.interpolate)
    }
}

private struct WidgetCheckboxButtonStyle: ButtonStyle {
    let accentColor: Color
    let isLarge: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: isLarge ? 5 : 4)
                        .fill(accentColor.opacity(0.24))
                        .frame(width: isLarge ? 18 : 15, height: isLarge ? 18 : 15)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Widget Configuration

struct NudgeTaskWidget: Widget {
    let kind: String = "NudgeTaskWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NudgeTaskProvider()) { entry in
            NudgeTaskWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetColors.background
                }
        }
        .configurationDisplayName("Nudge Tasks")
        .description("Your tasks, goals, and streak at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    NudgeTaskWidget()
} timeline: {
    NudgeTaskEntry.placeholder
}

#Preview(as: .systemLarge) {
    NudgeTaskWidget()
} timeline: {
    NudgeTaskEntry.placeholder
}
