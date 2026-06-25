//
//  StatsTabView.swift
//  Nudge
//
//  Stats tab — live task completion counts, session timing, sleep/wake accuracy.
//

import SwiftUI
import SwiftData

struct StatsTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [NudgeTask]
    @Query(sort: \CompletedTaskRecord.completedAt, order: .reverse) private var allRecords: [CompletedTaskRecord]
    @Query(sort: \DailyStats.date, order: .reverse) private var allStats: [DailyStats]
    @Query(sort: \DailySession.date, order: .reverse) private var allSessions: [DailySession]

    @State private var showingCompletedSheet: CompletedSheetType?
    @Binding var selectedTab: AppTab

    private enum CompletedSheetType: Identifiable {
        case today
        case week

        var id: String {
            switch self {
            case .today: return "today"
            case .week: return "week"
            }
        }
    }

    // MARK: - Task Count Computations

    private var calendar: Calendar { Calendar.current }

    private var startOfToday: Date {
        calendar.startOfDay(for: Date())
    }

    private var startOfWeek: Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return calendar.date(from: components) ?? startOfToday
    }

    // Today — from persistent records
    private var todayCompletedRecords: [CompletedTaskRecord] {
        allRecords.filter { calendar.isDateInToday($0.completedAt) }
    }

    private var todayCompleted: Int {
        todayCompletedRecords.count
    }

    private var todayTotal: Int {
        let incomplete = allTasks.filter { !$0.isComplete }.count
        return incomplete + todayCompleted
    }

    // This week — from persistent records
    private var weekCompletedRecords: [CompletedTaskRecord] {
        allRecords.filter { $0.completedAt >= startOfWeek }
    }

    private var weekCompleted: Int {
        weekCompletedRecords.count
    }

    private var weekTotal: Int {
        let createdThisWeek = allTasks.filter { $0.createdAt >= startOfWeek }.count
        return max(createdThisWeek, weekCompleted)
    }

    // Recent data
    private var recentStats: [DailyStats] {
        Array(allStats.prefix(7))
    }

    private var recentSessions: [DailySession] {
        Array(allSessions.prefix(7))
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    AccountShortcutButton(selectedTab: $selectedTab)
                    ScreenHeader(title: "Stats", subtitle: "Task completion, session timing, and sleep accuracy.")
                    Spacer(minLength: 0)
                }

                // Today section
                sectionLabel("Today")
                HStack(spacing: 12) {
                    countCard(
                        title: "Completed",
                        count: todayCompleted,
                        total: todayTotal,
                        icon: "checkmark.circle.fill",
                        accent: NudgeTheme.primary
                    )
                    countCard(
                        title: "Remaining",
                        count: max(0, todayTotal - todayCompleted),
                        total: nil,
                        icon: "circle",
                        accent: NudgeTheme.textMuted
                    )
                }

                if !todayCompletedRecords.isEmpty {
                    completedRecordPreview(
                        title: "Completed Today",
                        records: todayCompletedRecords,
                        showTime: true
                    ) {
                        showingCompletedSheet = .today
                    }
                }

                // This week section
                sectionLabel("This Week")
                HStack(spacing: 12) {
                    countCard(
                        title: "Completed",
                        count: weekCompleted,
                        total: weekTotal,
                        icon: "checkmark.circle.fill",
                        accent: NudgeTheme.primary
                    )
                    countCard(
                        title: "Completion rate",
                        count: weekTotal > 0 ? (weekCompleted * 100 / weekTotal) : 0,
                        total: nil,
                        icon: "chart.bar.fill",
                        accent: NudgeTheme.primary.opacity(0.6),
                        suffix: "%"
                    )
                }

                // Show week list excluding today's records (already shown above)
                let weekOnlyRecords = weekCompletedRecords.filter { !calendar.isDateInToday($0.completedAt) }
                if !weekOnlyRecords.isEmpty {
                    completedRecordPreview(
                        title: "Completed This Week",
                        records: weekOnlyRecords,
                        showTime: false
                    ) {
                        showingCompletedSheet = .week
                    }
                }

                // Daily breakdown for the week
                weeklyBreakdown

                // Session start times
                sectionLabel("Session Start Times")
                if recentSessions.isEmpty {
                    emptyCard(message: "No sessions recorded yet. Use the Home tab to start your first session.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(recentSessions.prefix(5), id: \.id) { session in
                            sessionRow(session: session)
                        }
                    }
                    .background(NudgeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                    .overlay(
                        RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                            .stroke(NudgeTheme.border, lineWidth: 1)
                    )
                }

                // Sleep / Wake accuracy
                sectionLabel("Sleep & Wake Accuracy")
                if recentStats.filter({ $0.bedtimeDeviationMinutes != nil || $0.wakeDeviationMinutes != nil }).isEmpty {
                    emptyCard(message: "Sleep and wake accuracy will appear after you log a few days.")
                } else {
                    HStack(spacing: 12) {
                        accuracyCard(
                            title: "Bedtime",
                            icon: "moon.fill",
                            accuracy: averageBedtimeAccuracy,
                            deviation: averageBedtimeDeviation
                        )
                        accuracyCard(
                            title: "Wake",
                            icon: "sunrise.fill",
                            accuracy: averageWakeAccuracy,
                            deviation: averageWakeDeviation
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        .sheet(item: $showingCompletedSheet) { sheetType in
            switch sheetType {
            case .today:
                CompletedTasksSheet(
                    title: "Completed Today",
                    records: todayCompletedRecords,
                    showTime: true
                )
            case .week:
                let weekOnly = weekCompletedRecords.filter { !calendar.isDateInToday($0.completedAt) }
                CompletedTasksSheet(
                    title: "Completed This Week",
                    records: weekOnly,
                    showTime: true
                )
            }
        }
    }

    // MARK: - Computed Averages

    private var averageBedtimeAccuracy: Int? {
        let values = recentStats.compactMap { $0.bedtimeAccuracy }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    private var averageWakeAccuracy: Int? {
        let values = recentStats.compactMap { $0.wakeAccuracy }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    private var averageBedtimeDeviation: Int? {
        let values = recentStats.compactMap { $0.bedtimeDeviationMinutes }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    private var averageWakeDeviation: Int? {
        let values = recentStats.compactMap { $0.wakeDeviationMinutes }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    // MARK: - Count Card

    private func countCard(
        title: String,
        count: Int,
        total: Int?,
        icon: String,
        accent: Color,
        suffix: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)

                Text(title)
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(count)\(suffix)")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 32))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3), value: count)

                if let total {
                    Text("/ \(total)")
                        .font(.custom(NudgeTheme.fontMedium, size: 16))
                        .foregroundColor(NudgeTheme.textMuted)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3), value: total)
                }
            }

            // Progress bar
            if let total, total > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent.opacity(0.15))
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent)
                            .frame(width: geo.size.width * min(CGFloat(count) / CGFloat(total), 1.0), height: 6)
                            .animation(.spring(response: 0.4), value: count)
                    }
                }
                .frame(height: 6)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent)
                    .frame(width: 36, height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Weekly Breakdown

    private var weeklyBreakdown: some View {
        let days = buildWeekDays()

        return VStack(alignment: .leading, spacing: 12) {
            Text("Daily breakdown")
                .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                .foregroundColor(NudgeTheme.textPrimary)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(days, id: \.date) { day in
                    VStack(spacing: 6) {
                        // Count label
                        Text("\(day.completed)")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 11))
                            .foregroundColor(day.completed > 0 ? NudgeTheme.primary : NudgeTheme.textPlaceholder)

                        // Bar
                        let maxHeight: CGFloat = 80
                        let barHeight: CGFloat = day.total > 0
                            ? max(8, maxHeight * CGFloat(day.completed) / CGFloat(max(day.total, 1)))
                            : 4

                        RoundedRectangle(cornerRadius: 6)
                            .fill(day.completed > 0 ? NudgeTheme.primary : NudgeTheme.primary.opacity(0.12))
                            .frame(maxWidth: .infinity)
                            .frame(height: barHeight)
                            .animation(.spring(response: 0.4), value: day.completed)

                        // Day label
                        Text(day.label)
                            .font(.custom(NudgeTheme.fontMedium, size: 10))
                            .foregroundColor(day.isToday ? NudgeTheme.primary : NudgeTheme.textMuted)
                    }
                }
            }
            .frame(height: 120)
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private struct WeekDay: Hashable {
        let date: Date
        let label: String
        let completed: Int
        let total: Int
        let isToday: Bool
    }

    private func buildWeekDays() -> [WeekDay] {
        var days: [WeekDay] = []
        for offset in 0..<7 {
            let dayDate = calendar.date(byAdding: .day, value: offset, to: startOfWeek)!
            let dayStart = calendar.startOfDay(for: dayDate)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

            // Use persistent records so counts survive task deletion
            let completed = allRecords.filter { record in
                record.completedAt >= dayStart && record.completedAt < dayEnd
            }.count

            let created = allTasks.filter { $0.createdAt >= dayStart && $0.createdAt < dayEnd }.count
            let total = max(created, completed)

            days.append(WeekDay(
                date: dayDate,
                label: dayDate.formatted(.dateTime.weekday(.narrow)),
                completed: completed,
                total: total,
                isToday: calendar.isDateInToday(dayDate)
            ))
        }
        return days
    }

    // MARK: - Subviews

    private func accuracyCard(title: String, icon: String, accuracy: Int?, deviation: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NudgeTheme.primary)

                Text(title)
                    .font(.custom(NudgeTheme.fontMedium, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            if let accuracy {
                Text("\(accuracy)%")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 28))
                    .foregroundColor(NudgeTheme.textPrimary)
            } else {
                Text("--")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 28))
                    .foregroundColor(NudgeTheme.textPlaceholder)
            }

            if let deviation {
                Text(deviationLabel(deviation))
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(abs(deviation) <= 15 ? NudgeTheme.success : NudgeTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func sessionRow(session: DailySession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.custom(NudgeTheme.fontMedium, size: 14))
                    .foregroundColor(NudgeTheme.textPrimary)

                Text("\(session.taskCount) task\(session.taskCount == 1 ? "" : "s") captured")
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            Spacer()

            Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                .foregroundColor(NudgeTheme.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func emptyCard(message: String) -> some View {
        Text(message)
            .font(.custom(NudgeTheme.fontBody, size: 14))
            .foregroundColor(NudgeTheme.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
    }

    /// Shows up to 3 records with a "See All" footer when there are more.
    private func completedRecordPreview(title: String, records: [CompletedTaskRecord], showTime: Bool, onSeeAll: @escaping () -> Void) -> some View {
        let preview = Array(records.prefix(3))
        let hasMore = records.count > 3

        return Button(action: onSeeAll) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                        .foregroundColor(NudgeTheme.textPrimary)

                    Spacer()

                    HStack(spacing: 4) {
                        Text(hasMore ? "See All" : "\(records.count)")
                            .font(.custom(NudgeTheme.fontMedium, size: 12))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(NudgeTheme.primary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                ForEach(preview, id: \.id) { record in
                    completedRecordRow(record: record, showTime: showTime)

                    if record.id != preview.last?.id {
                        Rectangle()
                            .fill(NudgeTheme.border)
                            .frame(height: 1)
                            .padding(.leading, 44)
                    }
                }
            }
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func completedRecordRow(record: CompletedTaskRecord, showTime: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(NudgeTheme.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.custom(NudgeTheme.fontMedium, size: 14))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .lineLimit(1)

                Text(showTime
                    ? record.completedAt.formatted(date: .omitted, time: .shortened)
                    : record.completedAt.formatted(date: .abbreviated, time: .omitted)
                )
                .font(.custom(NudgeTheme.fontBody, size: 12))
                .foregroundColor(NudgeTheme.textMuted)
            }

            Spacer()

            Text(record.priority.capitalized)
                .font(.custom(NudgeTheme.fontMedium, size: 11))
                .foregroundColor(NudgeTheme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(NudgeTheme.surfaceAlt)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(NudgeTheme.fontSemiBold, size: 18))
            .foregroundColor(NudgeTheme.textPrimary)
            .padding(.top, 4)
    }

    private func deviationLabel(_ minutes: Int) -> String {
        if minutes == 0 {
            return "On time"
        } else if minutes > 0 {
            return "+\(minutes)m late"
        } else {
            return "\(minutes)m early"
        }
    }
}

// MARK: - Completed Tasks Sheet

struct CompletedTasksSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let title: String
    let records: [CompletedTaskRecord]
    let showTime: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if records.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Text("No completed tasks")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 18))
                                .foregroundColor(NudgeTheme.textPrimary)
                            Text("Tasks you complete will show up here.")
                                .font(.custom(NudgeTheme.fontBody, size: 14))
                                .foregroundColor(NudgeTheme.textMuted)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                    } else {
                        ForEach(records, id: \.id) { record in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(NudgeTheme.primary)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title)
                                        .font(.custom(NudgeTheme.fontMedium, size: 15))
                                        .foregroundColor(NudgeTheme.textPrimary)

                                    Text(showTime
                                        ? record.completedAt.formatted(date: .omitted, time: .shortened)
                                        : record.completedAt.formatted(date: .abbreviated, time: .shortened)
                                    )
                                    .font(.custom(NudgeTheme.fontBody, size: 12))
                                    .foregroundColor(NudgeTheme.textMuted)
                                }

                                Spacer()

                                Text(record.priority.capitalized)
                                    .font(.custom(NudgeTheme.fontMedium, size: 11))
                                    .foregroundColor(NudgeTheme.textMuted)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(NudgeTheme.surfaceAlt)
                                    .clipShape(Capsule())

                                Button {
                                    withAnimation(NudgeAnimation.standard) {
                                        modelContext.delete(record)
                                        try? modelContext.save()
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(NudgeTheme.textMuted)
                                        .frame(width: 28, height: 28)
                                        .background(NudgeTheme.surfaceAlt)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)

                            if record.id != records.last?.id {
                                Rectangle()
                                    .fill(NudgeTheme.border)
                                    .frame(height: 1)
                                    .padding(.leading, 50)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .background(NudgeTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                }
            }
        }
    }
}
