//
//  CalendarService.swift
//  Nudge
//
//  Imports Apple Calendar events and Canvas iCal feeds, maps them to
//  NudgeTasks, and stores them in SwiftData. No Claude API usage.
//

import EventKit
import Foundation
import Observation
import SwiftData
import WidgetKit

// MARK: - Import Result

struct CalendarImportResult {
    let importedCount: Int
    let skippedDuplicates: Int
    let errors: [String]

    var summary: String {
        if importedCount == 0 && skippedDuplicates == 0 && errors.isEmpty {
            return "No upcoming events found."
        }
        var parts: [String] = []
        if importedCount > 0 {
            parts.append("\(importedCount) task\(importedCount == 1 ? "" : "s") imported")
        }
        if skippedDuplicates > 0 {
            parts.append("\(skippedDuplicates) duplicate\(skippedDuplicates == 1 ? "" : "s") skipped")
        }
        return parts.joined(separator: ", ") + "."
    }
}

struct AppleCalendarOption: Identifiable, Hashable {
    let id: String
    let title: String
    let sourceTitle: String?
}

// MARK: - Calendar Service

@MainActor @Observable
final class CalendarService {
    static let shared = CalendarService()

    // MARK: - Published State

    private(set) var isImporting = false
    private(set) var lastImportDate: Date?
    private(set) var lastImportError: String?

    // MARK: - Private

    private let eventStore = EKEventStore()

    private init() {}

    // MARK: - Public API

    /// Request EventKit full calendar access. Returns true if granted.
    func requestCalendarAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// Deletes every informational event whose date is before today's start.
    /// Run on app launch and on scene-becomes-active so that as soon as the
    /// clock crosses midnight the previous day's events disappear.
    @discardableResult
    func purgePastEvents(modelContext: ModelContext) -> Int {
        let todayStart = Calendar.current.startOfDay(for: Date())
        // Scope to events whose date sits BEFORE today via a predicate so
        // we don't pull every imported event into the shared model context
        // on a path that runs on every wake-time tick. fetchLimit caps the
        // worst case at 200 deletions per call — if there's a bigger
        // backlog, the next reevaluate sweeps the rest.
        let distantFutureSentinel = Date.distantFuture
        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                task.isInformationalEvent &&
                (task.specificTime ?? task.dueDate ?? distantFutureSentinel) < todayStart
            }
        )
        descriptor.fetchLimit = 200
        guard let pastEvents = try? modelContext.fetch(descriptor) else { return 0 }

        guard !pastEvents.isEmpty else { return 0 }

        for event in pastEvents {
            modelContext.delete(event)
        }
        try? modelContext.save()
        #if DEBUG
        print("[CalendarService] Purged \(pastEvents.count) past event(s)")
        #endif
        return pastEvents.count
    }

    func availableAppleCalendars() async -> [AppleCalendarOption] {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess {
            let granted = await requestCalendarAccess()
            guard granted else {
                lastImportError = "Calendar access denied"
                return []
            }
        }

        lastImportError = nil
        return eventStore.calendars(for: .event)
            .map {
                AppleCalendarOption(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                if $0.title == $1.title {
                    return ($0.sourceTitle ?? "") < ($1.sourceTitle ?? "")
                }
                return $0.title < $1.title
            }
    }

    /// Default window depth — keeps the app 3 weeks ahead in the calendar so
    /// upcoming exams/quizzes/deadlines are visible to the prep system.
    static let rollingWindowDays = 21

    /// App Group UserDefaults key tracking the latest date we've fetched
    /// calendar events through. Used by `refreshRollingWindow` to incrementally
    /// extend the window week by week.
    static let calendarSyncedThroughKey = "nudge.calendarSyncedThrough"
    private static let appGroupID = "group.com.deblaser.nudge"

    /// Re-runs Apple Calendar import to maintain a rolling 3-week future window.
    ///
    /// - On first call (`syncedThrough == nil`): imports today → today + 21 days.
    /// - On subsequent calls: only re-imports if at least 7 days have elapsed
    ///   since the last sync, then extends the window to today + 21 days.
    /// Skipping the import when no week has elapsed avoids redundant work.
    @discardableResult
    func refreshRollingWindow(
        modelContext: ModelContext,
        selectedCalendarIDs: [String]? = nil
    ) async -> CalendarImportResult? {
        let calendar = Calendar.current
        let now = Date()
        let target = calendar.date(byAdding: .day, value: Self.rollingWindowDays, to: now) ?? now

        let defaults = SharedModelContainer.appGroupDefaults
        let syncedThrough = defaults.object(forKey: Self.calendarSyncedThroughKey) as? Date

        let start: Date
        if let syncedThrough {
            // Only run if a full week has passed since the last sync.
            let daysSinceSync = calendar.dateComponents([.day], from: syncedThrough, to: target).day ?? 0
            guard daysSinceSync >= 7 else { return nil }
            // Begin from where we last left off (or today if that's in the past).
            start = max(now, syncedThrough)
        } else {
            // First-time connection.
            start = now
        }

        let result = await importAppleCalendar(
            modelContext: modelContext,
            selectedCalendarIDs: selectedCalendarIDs,
            from: start,
            through: target
        )

        if result.errors.isEmpty {
            defaults.set(target, forKey: Self.calendarSyncedThroughKey)
        }
        return result
    }

    /// Clears the rolling-window cursor. Call this when the user disconnects
    /// or switches calendars so the next sync starts fresh.
    func resetRollingWindowCursor() {
        SharedModelContainer.appGroupDefaults
            .removeObject(forKey: Self.calendarSyncedThroughKey)
    }

    /// Import events from Apple Calendar between `from` and `through`.
    /// Defaults to the rolling 3-week window from now.
    /// Creates NudgeTasks with source="calendar", deduplicating by title+dueDate.
    func importAppleCalendar(
        modelContext: ModelContext,
        selectedCalendarIDs: [String]? = nil,
        from startDateOverride: Date? = nil,
        through endDateOverride: Date? = nil
    ) async -> CalendarImportResult {
        isImporting = true
        defer {
            isImporting = false
            lastImportDate = Date()
        }

        // Check authorization — request if not yet granted
        let status = EKEventStore.authorizationStatus(for: .event)
        if status != .fullAccess {
            let granted = await requestCalendarAccess()
            if !granted {
                lastImportError = "Calendar access denied"
                return CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: ["Calendar access denied"])
            }
        }

        // Date range: caller-provided or default 3-week window
        let startDate = startDateOverride ?? Date()
        let endDate = endDateOverride
            ?? Calendar.current.date(byAdding: .day, value: Self.rollingWindowDays, to: startDate)!

        let calendars: [EKCalendar]?
        if let selectedCalendarIDs, !selectedCalendarIDs.isEmpty {
            let filtered = eventStore.calendars(for: .event).filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
            calendars = filtered.isEmpty ? nil : filtered
        } else {
            calendars = nil
        }

        // Fetch all events across all calendars
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        // Map and deduplicate
        var importedCount = 0
        var skippedDuplicates = 0

        for event in events {
            // Skip multi-day all-day events (holidays, vacations)
            if event.isAllDay {
                let daySpan = Calendar.current.dateComponents([.day], from: event.startDate, to: event.endDate).day ?? 0
                if daySpan > 1 { continue }
            }

            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }

            let dueDate = Calendar.current.startOfDay(for: event.startDate)
            let specificTime: Date? = event.isAllDay ? nil : event.startDate

            if isDuplicate(title: title, dueDate: dueDate, modelContext: modelContext) {
                skippedDuplicates += 1
                continue
            }

            let task = NudgeTask(
                title: title,
                dueDate: dueDate,
                dueTime: event.isAllDay ? nil : "specific",
                specificTime: specificTime,
                priority: "medium",
                category: inferCategory(from: event),
                source: "calendar",
                isInformationalEvent: shouldImportAsInformationalEvent(title: title, isAllDay: event.isAllDay)
            )
            modelContext.insert(task)
            importedCount += 1
        }

        try? modelContext.save()
        if importedCount > 0 {
            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        }

        lastImportError = nil
        return CalendarImportResult(importedCount: importedCount, skippedDuplicates: skippedDuplicates, errors: [])
    }

    /// Fetch and parse a Canvas iCal URL, creating NudgeTasks with
    /// source="calendar" and category="school".
    func importCanvasICal(urlString: String, modelContext: ModelContext) async -> CalendarImportResult {
        isImporting = true
        defer {
            isImporting = false
            lastImportDate = Date()
        }

        // Validate URL
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http" else {
            lastImportError = "Invalid URL"
            return CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: ["Invalid iCal URL"])
        }

        // Fetch .ics data
        let icsString: String
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                lastImportError = "Failed to fetch calendar"
                return CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: ["Server returned an error"])
            }
            guard let text = String(data: data, encoding: .utf8) else {
                lastImportError = "Could not decode response"
                return CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: ["Could not decode response"])
            }
            icsString = text
        } catch {
            lastImportError = error.localizedDescription
            return CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: [error.localizedDescription])
        }

        // Parse VEVENT blocks
        let parsedEvents = parseICalEvents(from: icsString)

        // Filter to next 30 days and map to tasks
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: 30, to: now)!

        var importedCount = 0
        var skippedDuplicates = 0

        for event in parsedEvents {
            guard let startDate = event.startDate,
                  startDate >= now,
                  startDate <= cutoff else { continue }

            let title = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let dueDate = Calendar.current.startOfDay(for: startDate)
            let specificTime: Date? = event.isAllDay ? nil : startDate

            if isDuplicate(title: title, dueDate: dueDate, modelContext: modelContext) {
                skippedDuplicates += 1
                continue
            }

            let task = NudgeTask(
                title: title,
                dueDate: dueDate,
                dueTime: event.isAllDay ? nil : "specific",
                specificTime: specificTime,
                priority: inferPriorityFromCanvas(title: title),
                category: "school",
                source: "calendar",
                isInformationalEvent: shouldImportAsInformationalEvent(title: title, isAllDay: event.isAllDay)
            )
            modelContext.insert(task)
            importedCount += 1
        }

        try? modelContext.save()
        if importedCount > 0 {
            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        }

        lastImportError = nil
        return CalendarImportResult(importedCount: importedCount, skippedDuplicates: skippedDuplicates, errors: [])
    }

    // MARK: - Deduplication

    private func isDuplicate(title: String, dueDate: Date, modelContext: ModelContext) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendarSource = "calendar"

        let descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { task in
                task.source == calendarSource
            }
        )

        guard let existingTasks = try? modelContext.fetch(descriptor) else { return false }

        return existingTasks.contains { existing in
            let existingTitle = existing.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard existingTitle == normalizedTitle else { return false }

            if let existingDueDate = existing.dueDate {
                return Calendar.current.isDate(existingDueDate, inSameDayAs: dueDate)
            }
            return false
        }
    }

    // MARK: - High-Priority Event Detection (Feature 4)

    /// Keywords that indicate an event is important enough to trigger a multi-day prep plan.
    private let highPriorityKeywords = [
        "exam", "final", "midterm", "test", "quiz", "presentation",
        "interview", "deadline", "due date", "defense", "surgery",
        "board meeting", "review", "audit", "demo", "showcase"
    ]

    /// Scans imported calendar tasks for upcoming high-priority events within
    /// the next 7 days that don't already have prep plans generated.
    ///
    // ── CLAUDE API INTEGRATION ──────────────────────────────────────
    // When a high-priority event is detected, call:
    //   ClaudeService.shared.generatePrepPlan(eventTitle:eventDate:...)
    // to create a multi-day prep sequence, then create NudgeTasks from the
    // returned PrepBlockData items with source = "prep".
    // ────────────────────────────────────────────────────────────────
    func detectHighPriorityEvents(modelContext: ModelContext) -> [NudgeTask] {
        let calendarSource = "calendar"
        let allCalendarTasks = (try? modelContext.fetch(
            FetchDescriptor<NudgeTask>(
                predicate: #Predicate<NudgeTask> { $0.source == calendarSource }
            )
        )) ?? []

        let now = Date()
        let sevenDaysOut = Calendar.current.date(byAdding: .day, value: 7, to: now)!

        return allCalendarTasks.filter { task in
            guard !task.isComplete else { return false }
            guard let dueDate = task.dueDate ?? task.specificTime else { return false }
            guard dueDate > now && dueDate <= sevenDaysOut else { return false }

            // Check if the event title matches high-priority keywords
            let lower = task.title.lowercased()
            return highPriorityKeywords.contains { lower.contains($0) }
        }
    }

    /// Returns true if the given event title contains keywords indicating importance.
    func isHighPriorityEvent(title: String) -> Bool {
        let lower = title.lowercased()
        return highPriorityKeywords.contains { lower.contains($0) }
    }

    // MARK: - Category & Priority Inference

    private func inferCategory(from event: EKEvent) -> String {
        let calendarTitle = (event.calendar.title).lowercased()
        let title = (event.title ?? "").lowercased()

        let schoolKeywords = ["school", "class", "university", "college", "canvas",
                              "coursework", "lecture", "seminar", "lab", "exam",
                              "quiz", "midterm", "final"]
        let workKeywords = ["work", "shift", "job", "office", "meeting", "standup",
                            "1:1", "sync", "sprint", "interview"]
        let healthKeywords = ["doctor", "dentist", "therapy", "gym", "workout",
                              "appointment", "checkup", "physical"]

        for keyword in schoolKeywords {
            if calendarTitle.contains(keyword) || title.contains(keyword) { return "school" }
        }
        for keyword in workKeywords {
            if calendarTitle.contains(keyword) || title.contains(keyword) { return "work" }
        }
        for keyword in healthKeywords {
            if title.contains(keyword) { return "health" }
        }
        return "personal"
    }

    private func inferPriorityFromCanvas(title: String) -> String {
        let lower = title.lowercased()
        let highKeywords = ["exam", "final", "midterm", "test", "quiz", "presentation"]
        for keyword in highKeywords {
            if lower.contains(keyword) { return "high" }
        }
        return "medium"
    }

    private func shouldImportAsInformationalEvent(title: String, isAllDay: Bool) -> Bool {
        let lower = title.lowercased()

        // Tasks: "to-do" verbs and items the user actively works on.
        // These take priority over event keywords (e.g. "study for exam" is a
        // task, even though "exam" sounds event-like).
        let taskKeywords = [
            "submit", "finish", "complete", "pay", "renew", "turn in",
            "study", "review", "prepare", "practice", "write", "email",
            "call", "buy", "pick up", "drop off", "deadline", "due",
            "assignment", "homework", "project"
        ]
        if taskKeywords.contains(where: { lower.contains($0) }) {
            return false
        }

        // Strong event signals — fixed-time commitments the user attends.
        let eventKeywords = [
            // school
            "class", "lecture", "seminar", "lab", "office hours", "discussion",
            // work
            "work", "shift", "meeting", "standup", "sync", "1:1", "interview",
            // appointments / social
            "appointment", "doctor", "dentist", "therapy",
            "holiday", "birthday", "anniversary", "vacation", "trip", "travel",
            "concert", "party", "wedding", "festival", "game", "match",
            "reservation", "flight", "visit", "meetup", "conference",
            "lunch", "dinner", "exam", "quiz", "test", "midterm", "final"
        ]
        if eventKeywords.contains(where: { lower.contains($0) }) {
            return true
        }

        // All-day events default to informational (calendar-only context).
        return isAllDay
    }

    // MARK: - iCal Parser

    private struct ParsedICalEvent {
        var summary: String = ""
        var startDate: Date?
        var endDate: Date?
        var isAllDay: Bool = false
    }

    private func parseICalEvents(from icsString: String) -> [ParsedICalEvent] {
        var events: [ParsedICalEvent] = []
        var currentEvent: ParsedICalEvent?
        var currentKey: String?
        var currentValue: String?

        let lines = icsString.components(separatedBy: .newlines)

        for line in lines {
            // Handle line folding (RFC 5545: continuation lines start with space or tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let key = currentKey {
                    currentValue = (currentValue ?? "") + String(line.dropFirst())
                    if var event = currentEvent {
                        applyProperty(key: key, value: currentValue ?? "", rawKey: key, to: &event)
                        currentEvent = event
                    }
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "BEGIN:VEVENT" {
                currentEvent = ParsedICalEvent()
                currentKey = nil
                currentValue = nil
                continue
            }

            if trimmed == "END:VEVENT" {
                if let event = currentEvent {
                    events.append(event)
                }
                currentEvent = nil
                currentKey = nil
                currentValue = nil
                continue
            }

            guard currentEvent != nil else { continue }

            // Parse "KEY:VALUE" or "KEY;PARAMS:VALUE"
            if let colonRange = trimmed.range(of: ":", options: .literal) {
                let rawKey = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
                let value = String(trimmed[colonRange.upperBound...])

                // Strip parameters: "DTSTART;VALUE=DATE" -> "DTSTART"
                let key = rawKey.components(separatedBy: ";").first ?? rawKey

                currentKey = key
                currentValue = value

                applyProperty(key: key, value: value, rawKey: rawKey, to: &currentEvent!)
            }
        }

        return events
    }

    private func applyProperty(key: String, value: String, rawKey: String, to event: inout ParsedICalEvent) {
        switch key.uppercased() {
        case "SUMMARY":
            event.summary = unescapeICalValue(value)
        case "DTSTART":
            event.startDate = parseICalDate(value)
            // Detect all-day from VALUE=DATE parameter
            if rawKey.uppercased().contains("VALUE=DATE") && !rawKey.uppercased().contains("VALUE=DATE-TIME") {
                event.isAllDay = true
            }
        case "DTEND":
            event.endDate = parseICalDate(value)
        default:
            break
        }
    }

    private func parseICalDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // Format 1: "20260415T143000Z" (UTC datetime)
        if trimmed.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: trimmed)
        }

        // Format 2: "20260415T143000" (local datetime)
        if trimmed.contains("T") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = .current
            return formatter.date(from: trimmed)
        }

        // Format 3: "20260415" (date only, all-day)
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = .current
        return formatter.date(from: trimmed)
    }

    private func unescapeICalValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
