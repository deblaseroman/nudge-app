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

struct CalendarTabView: View {
    @Bindable var profile: UserProfile
    @Binding var selectedTab: AppTab

    @Environment(\.modelContext) private var modelContext
    @Query private var allTasks: [NudgeTask]

    @State private var selectedSource = ""
    @State private var canvasURL = ""
    @State private var availableAppleCalendars: [AppleCalendarOption] = []
    @State private var selectedAppleCalendarID: String?
    @State private var statusMessage: String?

    // Screenshot import state (sits alongside Apple Calendar — doesn't replace it).
    @State private var screenshotItem: PhotosPickerItem?
    @State private var isProcessingScreenshot = false
    @State private var screenshotStatus: String?
    @State private var screenshotCategory: String = "work"
    private let screenshotCategoryOptions = ["work", "school", "personal", "health"]

    private let sourceOptions = ["Apple Calendar", "Canvas iCal", "Google Calendar", "I’ll do this later"]

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
        switch profile.calendarSource {
        case "Apple Calendar":
            return profile.connectedAppleCalendarTitle ?? "All calendars"
        case "Canvas iCal":
            return profile.calendarImportURL?.isEmpty == false ? "Canvas feed connected" : "Canvas feed not added"
        case "Google Calendar":
            return "Google Calendar"
        default:
            return "Not connected"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
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
        case "Canvas iCal":
            canvasSection
        case "Google Calendar":
            unsupportedSection(
                title: "Google Calendar is not wired up yet.",
                subtitle: "Use Apple Calendar or a Canvas iCal feed for now."
            )
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
            sectionLabel("Canvas iCal Feed")

            TextField("Paste your Canvas iCal URL", text: $canvasURL)
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

            Button(action: importCanvasCalendar) {
                actionLabel(
                    title: CalendarService.shared.isImporting ? "Importing..." : "Save Feed and Import",
                    systemImage: "link.badge.plus"
                )
            }
            .disabled(CalendarService.shared.isImporting)
            .opacity(CalendarService.shared.isImporting ? 0.7 : 1)
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
                Text("Got a schedule that's not on your calendar app — like a work shift screenshot? Snap or upload it and Nudge will read it.")
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
        selectedSource = profile.calendarSource.isEmpty ? "I’ll do this later" : profile.calendarSource
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

    private func importCanvasCalendar() {
        let trimmedURL = canvasURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            NudgeHaptics.error()
            statusMessage = "Add a Canvas iCal URL before importing."
            return
        }

        Task {
            profile.calendarSource = "Canvas iCal"
            profile.calendarImportURL = trimmedURL
            profile.connectedAppleCalendarID = nil
            profile.connectedAppleCalendarTitle = nil

            let result = await CalendarService.shared.importCanvasICal(urlString: trimmedURL, modelContext: modelContext)
            try? modelContext.save()
            statusMessage = result.errors.isEmpty ? result.summary : result.errors.joined(separator: "\n")
        }
    }
}
