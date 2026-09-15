//
//  CalendarTabView.swift
//  Nudge
//
//  Manage calendar imports and switch connected calendar sources.
//

import SwiftUI
import SwiftData
import EventKit
import PhotosUI
import WidgetKit

struct CalendarTabView: View {
    @Bindable var profile: UserProfile
    @Binding var selectedTab: AppTab

    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [NudgeTask]

    // ── Nudge calendar (cycle 2026-09-13-02) ────────────────────────────
    // A read-only month glance over everything in the store that carries a
    // day — pure display, downstream of the store, never an input to the
    // AI or the arbiter (Roman's constraint). Tap an item → the shared
    // TaskEditorSheet, whose intent-aware `apply` moves the right field.
    @State private var displayedMonth: Date = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var editingTarget: CalendarEditTarget?
    /// Feedback line under the day header after a Plan-this-day run;
    /// cleared when the selection moves.
    @State private var planDayNote: String?

    private struct CalendarEditTarget: Identifiable {
        let id: UUID
    }

    @State private var selectedSource = ""
    @State private var canvasURL = ""
    @State private var isCheckingLink = false
    @State private var availableAppleCalendars: [AppleCalendarOption] = []
    @State private var selectedAppleCalendarID: String?
    @State private var statusMessage: String?

    // Screenshot import state (sits alongside Apple Calendar — doesn't replace it).
    @State private var screenshotItem: PhotosPickerItem?
    @State private var isProcessingScreenshot = false
    @State private var screenshotStatus: String?
    @State private var screenshotCategory: String = "work"
    private let screenshotCategoryOptions = ["work", "school", "personal", "health"]

    /// "Calendar Link (iCal)" covers every service that publishes an .ics
    /// feed — Canvas, Google, Outlook — through the one deterministic
    /// import path (zero AI cost, Sep 2026). Legacy stores hold
    /// "Canvas iCal" in `profile.calendarSource`; `normalizedSource` maps
    /// it forward so old installs land on the merged option.
    private let sourceOptions = ["Apple Calendar", "Calendar Link (iCal)", "I’ll do this later"]

    private func normalizedSource(_ raw: String) -> String {
        raw == "Canvas iCal" ? "Calendar Link (iCal)" : raw
    }

    private var calendarTasks: [NudgeTask] {
        allTasks.filter { $0.source == "calendar" }
    }

    private var upcomingCalendarTasks: [NudgeTask] {
        calendarTasks
            .filter { !$0.isComplete }
            .sorted { lhs, rhs in
                let leftDate = lhs.specificTime ?? lhs.dueDate ?? .distantFuture
                let rightDate = rhs.specificTime ?? rhs.dueDate ?? .distantFuture
                return leftDate < rightDate
            }
    }

    private var currentConnectionLabel: String {
        switch normalizedSource(profile.calendarSource) {
        case "Apple Calendar":
            return profile.connectedAppleCalendarTitle ?? "All calendars"
        case "Calendar Link (iCal)":
            return profile.calendarImportURL?.isEmpty == false ? "Calendar link connected" : "Calendar link not added"
        default:
            return "Not connected"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                nudgeCalendarSection
                connectionOverview
                sourcePickerSection
                sourceConfigurationSection
                screenshotImportSection
                importedTasksSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        .sheet(item: $editingTarget) { target in
            if let task = allTasks.first(where: { $0.id == target.id }) {
                TaskEditorSheet(
                    mode: .edit(task: task),
                    onSave: { draft in
                        TaskEditorSheet.apply(draft, to: task, modelContext: modelContext)
                        try? modelContext.save()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                        NudgeIntelligence.shared.refreshSoon(for: task)
                        NudgeArbiter.shared.reevaluate(
                            reason: .taskCreatedOrEdited,
                            profile: profile,
                            modelContext: modelContext
                        )
                    },
                    onDelete: {
                        ExamPrepSweep.recordDeletionIfGenerated(task, modelContext: modelContext)
                        modelContext.delete(task)
                        try? modelContext.save()
                        WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
                        NudgeArbiter.shared.reevaluate(
                            reason: .taskCreatedOrEdited,
                            profile: profile,
                            modelContext: modelContext
                        )
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            syncDraftState()
            await refreshAppleCalendarsIfNeeded()
        }
        .onChange(of: selectedSource) { _, newValue in
            if newValue == "Apple Calendar" {
                Task {
                    await refreshAppleCalendarsIfNeeded()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AccountShortcutButton(selectedTab: $selectedTab)
            ScreenHeader(title: "Calendar", subtitle: "Review imports, reconnect a source, or switch which calendar Nudge uses.")
            Spacer(minLength: 0)
        }
    }

    // MARK: - Nudge calendar (cycle 2026-09-13-02)

    /// One row per item on a given day, classified for its dot/chip.
    /// A task carrying both an intent day and a deadline classifies as
    /// scheduled (the else-if order), so it renders once.
    private struct CalendarDayItem: Identifiable {
        enum Kind { case event, scheduled, deadline }
        let task: NudgeTask
        let kind: Kind
        let time: Date?
        var id: UUID { task.id }
    }

    private func dayItems(on day: Date) -> [CalendarDayItem] {
        let cal = Calendar.current
        var items: [CalendarDayItem] = []
        for t in allTasks where !t.isComplete {
            if t.isInformationalEvent {
                guard let anchor = t.specificTime ?? t.dueDate,
                      cal.isDate(anchor, inSameDayAs: day) else { continue }
                items.append(.init(task: t, kind: .event, time: t.specificTime))
            } else if let d = t.scheduledDay {
                guard cal.isDate(d, inSameDayAs: day) else { continue }
                items.append(.init(task: t, kind: .scheduled, time: t.plannedStartDate))
            } else if t.hasDeadline {
                guard let due = t.specificTime ?? t.dueDate,
                      cal.isDate(due, inSameDayAs: day) else { continue }
                items.append(.init(task: t, kind: .deadline, time: t.specificTime))
            }
        }
        return items.sorted { lhs, rhs in
            let l = lhs.time ?? .distantFuture
            let r = rhs.time ?? .distantFuture
            if l != r { return l < r }
            return lhs.task.title < rhs.task.title
        }
    }

    /// Month grid cells: leading nils pad to the calendar's first weekday.
    private var monthCells: [Date?] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: displayedMonth),
              let dayCount = cal.range(of: .day, in: .month, for: displayedMonth)?.count
        else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(cal.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    private var weekdaySymbols: [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private func kindColor(_ kind: CalendarDayItem.Kind) -> Color {
        switch kind {
        case .event:     return NudgeTheme.eventSlotAccent
        case .scheduled: return NudgeTheme.primary
        case .deadline:  return NudgeTheme.amber
        }
    }

    private func kindLabel(_ kind: CalendarDayItem.Kind) -> String {
        switch kind {
        case .event:     return "Event"
        case .scheduled: return "Planned"
        case .deadline:  return "Due"
        }
    }

    private var nudgeCalendarSection: some View {
        let cal = Calendar.current
        let cells = monthCells
        let selectedItems = dayItems(on: selectedDay)
        return VStack(alignment: .leading, spacing: 14) {
            // Month header with navigation + a jump back to today.
            HStack(spacing: 12) {
                Button {
                    NudgeHaptics.light()
                    displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.custom(NudgeTheme.fontSemiBold, size: 17))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .frame(maxWidth: .infinity)

                if !cal.isDate(displayedMonth, equalTo: Date(), toGranularity: .month) {
                    Button {
                        NudgeHaptics.light()
                        displayedMonth = cal.startOfDay(for: Date())
                        selectedDay = cal.startOfDay(for: Date())
                    } label: {
                        Text("Today")
                            .font(.custom(NudgeTheme.fontMedium, size: 12))
                            .foregroundColor(NudgeTheme.primary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    NudgeHaptics.light()
                    displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Weekday header + grid.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.custom(NudgeTheme.fontMedium, size: 10))
                        .foregroundColor(NudgeTheme.textMuted)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 42)
                    }
                }
            }

            // Legend — the three dot meanings.
            HStack(spacing: 14) {
                ForEach([CalendarDayItem.Kind.event, .scheduled, .deadline], id: \.self) { kind in
                    HStack(spacing: 5) {
                        Circle().fill(kindColor(kind)).frame(width: 6, height: 6)
                        Text(kindLabel(kind))
                            .font(.custom(NudgeTheme.fontBody, size: 11))
                            .foregroundColor(NudgeTheme.textMuted)
                    }
                }
                Spacer()
            }

            // Selected day's items.
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(selectedDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                    Spacer()
                    // Plan-ahead (cycle 2026-09-13-03): future days only —
                    // today's planning lives on the Tasks tab.
                    if selectedDay > cal.startOfDay(for: Date()) {
                        Button {
                            planSelectedDay()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Plan this day")
                                    .font(.custom(NudgeTheme.fontMedium, size: 12))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(NudgeTheme.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let planDayNote {
                    Text(planDayNote)
                        .font(.custom(NudgeTheme.fontBody, size: 12))
                        .foregroundColor(NudgeTheme.textMuted)
                }
                if selectedItems.isEmpty {
                    Text("Nothing on this day.")
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                } else {
                    ForEach(selectedItems) { item in
                        calendarItemRow(item)
                    }
                }
            }
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let kinds = Array(Set(dayItems(on: day).map(\.kind)))
            .sorted { a, b in
                func rank(_ k: CalendarDayItem.Kind) -> Int {
                    switch k { case .event: return 0; case .scheduled: return 1; case .deadline: return 2 }
                }
                return rank(a) < rank(b)
            }
        return Button {
            NudgeHaptics.light()
            selectedDay = day
            planDayNote = nil
        } label: {
            VStack(spacing: 4) {
                Text("\(cal.component(.day, from: day))")
                    .font(.custom(NudgeTheme.fontMedium, size: 13))
                    .foregroundColor(isSelected ? .white : NudgeTheme.textPrimary)
                HStack(spacing: 3) {
                    ForEach(Array(kinds.prefix(3).enumerated()), id: \.offset) { _, kind in
                        Circle()
                            .fill(isSelected ? Color.white : kindColor(kind))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                isSelected
                    ? NudgeTheme.primary
                    : (isToday ? NudgeTheme.primary.opacity(0.12) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Runs the deterministic engine on the selected future day and reports
    /// the outcome inline. Zero AI; placements are marked manual so that
    /// day's morning auto-run respects them and refills around them.
    private func planSelectedDay() {
        NudgeHaptics.medium()
        let outcome = DayPlanEngine.plan(
            day: selectedDay,
            profile: profile,
            modelContext: modelContext
        )
        NudgeArbiter.shared.reevaluate(
            reason: .taskCreatedOrEdited,
            profile: profile,
            modelContext: modelContext
        )
        switch outcome {
        case .placed(let count, _, _, _):
            planDayNote = "Planned \(count) task\(count == 1 ? "" : "s") for this day."
        case .noCandidates:
            planDayNote = "Nothing available to place on this day."
        case .noRoom:
            planDayNote = "No room left on this day."
        case .windowCollapsed:
            planDayNote = "Couldn't compute this day's window, check wake and bedtime in Settings."
        }
    }

    private func calendarItemRow(_ item: CalendarDayItem) -> some View {
        Button {
            NudgeHaptics.light()
            editingTarget = CalendarEditTarget(id: item.task.id)
        } label: {
            HStack(spacing: 10) {
                Text(kindLabel(item.kind))
                    .font(.custom(NudgeTheme.fontMedium, size: 10))
                    .foregroundColor(kindColor(item.kind))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().stroke(kindColor(item.kind).opacity(0.5), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.task.title)
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .lineLimit(1)
                    if let time = item.time {
                        Text(time.formatted(date: .omitted, time: .shortened))
                            .font(.custom(NudgeTheme.fontBody, size: 11))
                            .foregroundColor(NudgeTheme.textMuted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
            }
            .padding(12)
            .background(NudgeTheme.surfaceAlt.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var connectionOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current connection")
                        .font(.custom(NudgeTheme.fontMedium, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)

                    Text(currentConnectionLabel)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                        .foregroundColor(NudgeTheme.textPrimary)
                }

                Spacer()

                Image(systemName: profile.calendarSource.isEmpty ? "calendar.badge.exclamationmark" : "calendar.badge.checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(profile.calendarSource.isEmpty ? NudgeTheme.textMuted : NudgeTheme.primary)
            }

            HStack(spacing: 12) {
                summaryChip(title: "Imported", value: "\(calendarTasks.count)")
                summaryChip(title: "Upcoming", value: "\(upcomingCalendarTasks.count)")
            }

            if let lastImportDate = CalendarService.shared.lastImportDate {
                Text("Last import \(lastImportDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.textSecondary)
            } else if let lastError = CalendarService.shared.lastImportError {
                Text(lastError)
                    .font(.custom(NudgeTheme.fontBody, size: 13))
                    .foregroundColor(NudgeTheme.danger)
            }
        }
        .padding(18)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private var sourcePickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Source")

            ForEach(sourceOptions, id: \.self) { source in
                Button(action: {
                    NudgeHaptics.light()
                    selectedSource = source
                    if source != "Canvas iCal" {
                        canvasURL = ""
                    }
                }) {
                    HStack {
                        Text(source)
                            .font(.custom(NudgeTheme.fontMedium, size: 15))
                            .foregroundColor(NudgeTheme.textPrimary)

                        Spacer()

                        if selectedSource == source {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(NudgeTheme.primary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(selectedSource == source ? NudgeTheme.primary.opacity(0.12) : NudgeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    .overlay(
                        RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                            .stroke(NudgeTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var sourceConfigurationSection: some View {
        switch selectedSource {
        case "Apple Calendar":
            appleCalendarSection
        case "Calendar Link (iCal)", "Canvas iCal":
            canvasSection
        default:
            unsupportedSection(
                title: "Calendar sync is currently off.",
                subtitle: "Pick a source whenever you want Nudge to turn events into tasks."
            )
        }
    }

    private var appleCalendarSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Connected Apple Calendar")

            if availableAppleCalendars.isEmpty {
                Text("Grant calendar access to choose which Apple calendar Nudge should import from.")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NudgeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                    .overlay(
                        RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                            .stroke(NudgeTheme.border, lineWidth: 1)
                    )
            } else {
                VStack(spacing: 10) {
                    ForEach(availableAppleCalendars) { calendar in
                        Button(action: {
                            NudgeHaptics.light()
                            selectedAppleCalendarID = calendar.id
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(calendar.title)
                                        .font(.custom(NudgeTheme.fontMedium, size: 15))
                                        .foregroundColor(NudgeTheme.textPrimary)

                                    if let sourceTitle = calendar.sourceTitle {
                                        Text(sourceTitle)
                                            .font(.custom(NudgeTheme.fontBody, size: 12))
                                            .foregroundColor(NudgeTheme.textMuted)
                                    }
                                }

                                Spacer()

                                Image(systemName: selectedAppleCalendarID == calendar.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(selectedAppleCalendarID == calendar.id ? NudgeTheme.primary : NudgeTheme.textMuted)
                            }
                            .padding(14)
                            .background(NudgeTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                            .overlay(
                                RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                                    .stroke(NudgeTheme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(action: importAppleCalendar) {
                actionLabel(
                    title: CalendarService.shared.isImporting ? "Importing..." : "Connect and Import",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(CalendarService.shared.isImporting)
            .opacity(CalendarService.shared.isImporting ? 0.7 : 1)
        }
    }

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Calendar Link (iCal)")

            // Format note (Roman, Sep 2026): the link must be an iCal feed,
            // not a web page — say so, and say where each service hides it.
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste an iCal link, the address ends in .ics or comes from your calendar's “subscribe” or “publish” option.")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
                Text("Canvas: Calendar → Calendar Feed.  Google: Settings → your calendar → Secret address in iCal format.  Outlook: Settings → Shared calendars → Publish.")
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
                Text("A picture of a schedule isn't a calendar link, use Add from Screenshot below instead.")
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            TextField("Paste your iCal link (.ics)", text: $canvasURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(NudgeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                .overlay(
                    RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                        .stroke(NudgeTheme.border, lineWidth: 1)
                )

            // Check before you run (Roman, Sep 2026): fetches and parses
            // the feed through the SAME validation the import uses, writes
            // nothing, and reports what it found — so a bad link is caught
            // before it touches the store.
            HStack(spacing: 10) {
                Button(action: checkCalendarLink) {
                    HStack(spacing: 6) {
                        Image(systemName: isCheckingLink ? "hourglass" : "checkmark.shield")
                            .font(.system(size: 13, weight: .semibold))
                        Text(isCheckingLink ? "Checking..." : "Check Link")
                            .font(.custom(NudgeTheme.fontMedium, size: 14))
                    }
                    .foregroundColor(NudgeTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .disabled(isCheckingLink || CalendarService.shared.isImporting)

                Button(action: importCanvasCalendar) {
                    actionLabel(
                        title: CalendarService.shared.isImporting ? "Importing..." : "Save Feed and Import",
                        systemImage: "link.badge.plus"
                    )
                }
                .disabled(CalendarService.shared.isImporting || isCheckingLink)
                .opacity(CalendarService.shared.isImporting ? 0.7 : 1)
            }
        }
    }

    // MARK: - Screenshot Import

    /// Lets the user add events from a screenshot (e.g. HotSchedules work
    /// schedule) alongside whatever primary calendar they already connected.
    /// The screenshot path is additive — it does NOT touch profile.calendarSource
    /// or any existing calendar import state.
    private var screenshotImportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Add from Screenshot")

            VStack(alignment: .leading, spacing: 8) {
                Text("Got a schedule that's not on your calendar app, like a work shift screenshot? Snap or upload it and Nudge will read it.")
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)

                // Category selector
                HStack(spacing: 8) {
                    Text("Category:")
                        .font(.custom(NudgeTheme.fontMedium, size: 13))
                        .foregroundColor(NudgeTheme.textSecondary)
                    ForEach(screenshotCategoryOptions, id: \.self) { option in
                        Button {
                            NudgeHaptics.light()
                            screenshotCategory = option
                        } label: {
                            Text(option.capitalized)
                                .font(.custom(NudgeTheme.fontMedium, size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundColor(screenshotCategory == option ? .white : NudgeTheme.textPrimary)
                                .background(
                                    screenshotCategory == option ? NudgeTheme.primary : NudgeTheme.surfaceAlt
                                )
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.top, 4)

                PhotosPicker(selection: $screenshotItem, matching: .images) {
                    HStack(spacing: 8) {
                        if isProcessingScreenshot {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(isProcessingScreenshot ? "Reading screenshot…" : "Upload Schedule Screenshot")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
                .disabled(isProcessingScreenshot)
                .opacity(isProcessingScreenshot ? 0.7 : 1)
                .onChange(of: screenshotItem) { _, newItem in
                    guard let newItem else { return }
                    Task { await handleScreenshotPicked(newItem) }
                }

                if let screenshotStatus {
                    Text(screenshotStatus)
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textSecondary)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
        }
    }

    private func handleScreenshotPicked(_ item: PhotosPickerItem) async {
        isProcessingScreenshot = true
        screenshotStatus = nil
        defer {
            isProcessingScreenshot = false
            screenshotItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                screenshotStatus = "Couldn't read that image. Try another one."
                return
            }

            let result = await ScreenshotCalendarImporter.shared.importFromImage(
                image,
                defaultCategory: screenshotCategory,
                modelContext: modelContext
            )

            if !result.errors.isEmpty {
                screenshotStatus = result.errors.joined(separator: " ")
            } else if result.importedCount == 0 && result.skippedDuplicates == 0 {
                screenshotStatus = "I didn't find any events. Try a clearer screenshot that shows the dates and times directly."
            } else {
                screenshotStatus = result.summary
                // Re-run the arbiter so any new events get their grouped
                // event-block reminders right away.
                NudgeArbiter.shared.reevaluate(
                    reason: .taskCreatedOrEdited,
                    profile: profile,
                    modelContext: modelContext
                )
            }
        } catch {
            screenshotStatus = "Something went wrong reading the image."
        }
    }

    private var importedTasksSection: some View {
        let previewTasks = Array(upcomingCalendarTasks.prefix(6))

        return VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Imported Events")

            if previewTasks.isEmpty {
                Text("Imported calendar events will show up here once you connect a source.")
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
            } else {
                VStack(spacing: 0) {
                    ForEach(previewTasks, id: \.id) { task in
                        importedTaskRow(task)

                        if task.id != previewTasks.last?.id {
                            Rectangle()
                                .fill(NudgeTheme.border)
                                .frame(height: 1)
                                .padding(.leading, 50)
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
        }
    }

    private func importedTaskRow(_ task: NudgeTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(NudgeTheme.primary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.custom(NudgeTheme.fontMedium, size: 14))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .lineLimit(1)

                Text(task.specificTime?.formatted(date: .abbreviated, time: .shortened) ?? task.dueDate?.formatted(date: .abbreviated, time: .omitted) ?? "No date")
                    .font(.custom(NudgeTheme.fontBody, size: 12))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summaryChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.custom(NudgeTheme.fontBody, size: 12))
                .foregroundColor(NudgeTheme.textMuted)

            Text(value)
                .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                .foregroundColor(NudgeTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(NudgeTheme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
    }

    private func unsupportedSection(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                .foregroundColor(NudgeTheme.textPrimary)

            Text(subtitle)
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(NudgeTheme.fontSemiBold, size: 18))
            .foregroundColor(NudgeTheme.textPrimary)
    }

    private func actionLabel(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(NudgeTheme.primary)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
    }

    private func syncDraftState() {
        selectedSource = profile.calendarSource.isEmpty
            ? "I’ll do this later"
            : normalizedSource(profile.calendarSource)
        canvasURL = profile.calendarImportURL ?? ""
        selectedAppleCalendarID = profile.connectedAppleCalendarID
    }

    private func refreshAppleCalendarsIfNeeded() async {
        guard selectedSource == "Apple Calendar" || profile.calendarSource == "Apple Calendar" else { return }
        availableAppleCalendars = await CalendarService.shared.availableAppleCalendars()
        if selectedAppleCalendarID == nil {
            selectedAppleCalendarID = profile.connectedAppleCalendarID ?? availableAppleCalendars.first?.id
        }
    }

    private func importAppleCalendar() {
        Task {
            availableAppleCalendars = await CalendarService.shared.availableAppleCalendars()
            guard !availableAppleCalendars.isEmpty else {
                statusMessage = CalendarService.shared.lastImportError ?? "No Apple calendars were found."
                return
            }

            if selectedAppleCalendarID == nil {
                selectedAppleCalendarID = availableAppleCalendars.first?.id
            }

            let selectedCalendar = availableAppleCalendars.first(where: { $0.id == selectedAppleCalendarID })
            profile.calendarSource = "Apple Calendar"
            profile.calendarImportURL = nil
            profile.connectedAppleCalendarID = selectedCalendar?.id
            profile.connectedAppleCalendarTitle = selectedCalendar?.title ?? "All calendars"

            // Reset cursor so reconnecting / switching calendars starts a
            // fresh 3-week window via the rolling path.
            CalendarService.shared.resetRollingWindowCursor()
            let result = await CalendarService.shared.refreshRollingWindow(
                modelContext: modelContext,
                selectedCalendarIDs: selectedCalendar.map { [$0.id] }
            ) ?? CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: [])

            try? modelContext.save()
            statusMessage = result.errors.isEmpty
                ? "\(result.summary) Connected to \(profile.connectedAppleCalendarTitle ?? "Apple Calendar")."
                : result.errors.joined(separator: "\n")
        }
    }

    /// Dry-run the pasted link: same fetch + validation as the import,
    /// zero writes, result lands in the shared status line.
    private func checkCalendarLink() {
        let trimmedURL = canvasURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            NudgeHaptics.error()
            statusMessage = "Paste a link first, then check it."
            return
        }
        isCheckingLink = true
        Task {
            let result = await CalendarService.shared.checkICalFeed(urlString: trimmedURL)
            isCheckingLink = false
            statusMessage = result.message
            if result.ok { NudgeHaptics.light() } else { NudgeHaptics.error() }
        }
    }

    private func importCanvasCalendar() {
        let trimmedURL = canvasURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            NudgeHaptics.error()
            statusMessage = "Add a Canvas iCal URL before importing."
            return
        }

        Task {
            let result = await CalendarService.shared.importCanvasICal(urlString: trimmedURL, modelContext: modelContext)
            // Persist the connection only on SUCCESS (Sep 2026) — this used
            // to write the URL before fetching, so a failed import still
            // recorded the bad link as the connected feed and clobbered an
            // existing Apple Calendar connection. A failure now changes
            // nothing about the current connection.
            if result.errors.isEmpty {
                profile.calendarSource = "Calendar Link (iCal)"
                profile.calendarImportURL = trimmedURL
                profile.connectedAppleCalendarID = nil
                profile.connectedAppleCalendarTitle = nil
            }
            try? modelContext.save()
            statusMessage = result.errors.isEmpty ? result.summary : result.errors.joined(separator: "\n")
        }
    }
}
