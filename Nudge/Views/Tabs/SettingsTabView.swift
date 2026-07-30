//
//  SettingsTabView.swift
//  Nudge
//
//  Core behavior and notification controls.
//

import SwiftUI
import SwiftData
import UIKit

struct SettingsTabView: View {
    @Bindable var profile: UserProfile
    @Binding var selectedTab: AppTab
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var activeTimeEditor: TimeSettingDestination?
    @State private var notificationAuthorizationState: NudgeNotificationService.AuthorizationState = .notDetermined

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    AccountShortcutButton(selectedTab: $selectedTab)
                    ScreenHeader(title: "Settings", subtitle: "Core behavior and notification controls.")
                    Spacer(minLength: 0)
                }

                timeSettingsRow(
                    title: "Morning check-in",
                    subtitle: "When Nudge should check in to start your day.",
                    value: profile.morningCheckInTime.formatted(date: .omitted, time: .shortened),
                    destination: .morningCheckIn
                )

                timeSettingsRow(
                    title: "Bedtime",
                    subtitle: "Used for wind-down reminders and pacing the day.",
                    value: profile.bedtime.formatted(date: .omitted, time: .shortened),
                    destination: .bedtime
                )

                settingsSection(title: "Quiet hours") {
                    // Quiet hours default to the sleep schedule but are no
                    // longer BOUND to it — bedtime is when you go to bed, not
                    // necessarily when you want to stop being interrupted.
                    toggleSettingsRow(
                        title: "Match my sleep schedule",
                        subtitle: "Quiet from 1 hr before bedtime until 30 min after wake. Turn off to set your own hours.",
                        isOn: quietHoursFollowSleepBinding
                    )

                    if !profile.quietHoursFollowSleepSchedule {
                        timeSettingsRow(
                            title: "Quiet hours start",
                            subtitle: "When Nudge should stop sending discretionary nudges.",
                            value: timeValue(for: .quietHoursStart).formatted(date: .omitted, time: .shortened),
                            destination: .quietHoursStart
                        )
                        timeSettingsRow(
                            title: "Quiet hours end",
                            subtitle: "When Nudge can start again. Earlier than the start time means the window runs overnight.",
                            value: timeValue(for: .quietHoursEnd).formatted(date: .omitted, time: .shortened),
                            destination: .quietHoursEnd
                        )
                    }
                }

                settingsSection(title: "Notifications") {
                    notificationPermissionCard

                    // Master switch — when off, no notification of any kind
                    // fires regardless of the per-kind toggles below.
                    toggleSettingsRow(
                        title: "Allow Nudge notifications",
                        subtitle: "Master switch. When off, nothing fires.",
                        isOn: $profile.notificationsEnabled
                    )

                    Button(action: {
                        NudgeHaptics.medium()
                        NudgeNotificationService.shared.sendTestNotification()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "bell.badge.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Send test notification (5 sec)")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(NudgeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }
                    .buttonStyle(.plain)
                }

                settingsSection(title: "Notification types") {
                    // Each toggle below gates one notification source. The
                    // master toggle above suppresses all of them; these
                    // toggles let the user opt out of just one kind without
                    // killing everything.
                    toggleSettingsRow(
                        title: "Morning prompt",
                        subtitle: "Asks what you want to get done today, 30 min after wake. Skipped when your day is already packed.",
                        isOn: $profile.morningCheckInNotificationsEnabled
                    )
                    // The field name is historical: `taskDueSoonNotificationsEnabled`
                    // has always gated the start-early pushes (the getAhead
                    // builder, now prep), so it keeps doing that after the
                    // Aug 2026 split — a user who turned it off silenced
                    // exactly these.
                    toggleSettingsRow(
                        title: "Start early",
                        subtitle: "A push to start a deadline task days ahead, on the day there's still room to get ahead of it.",
                        isOn: $profile.taskDueSoonNotificationsEnabled
                    )
                    // Split out of get-ahead in Aug 2026: a factual reminder
                    // ~2 hours before something is due. Its own field —
                    // see the note on `UserProfile`.
                    toggleSettingsRow(
                        title: "Due soon",
                        subtitle: "A heads-up about 2 hours before a deadline. Things due within the same hour share one reminder.",
                        isOn: $profile.dueSoonReminderNotificationsEnabled
                    )
                    // Was folded into "Task due soon" until Jul 2026. One
                    // switch for two features meant silencing the mid-day
                    // check-in also silenced every deadline-driven get-ahead
                    // nudge — the more valuable half.
                    toggleSettingsRow(
                        title: "Open work check-in",
                        subtitle: "A mid-day nudge about an undated task you haven't gotten to, 6 hrs after wake.",
                        isOn: $profile.floaterCheckInNotificationsEnabled
                    )
                    // Added Jul 2026. Event blocks were the only kind with no
                    // switch of their own, so the only way to stop them was
                    // the master toggle above.
                    toggleSettingsRow(
                        title: "Event reminders",
                        subtitle: "A heads-up before a block of calendar events, so the first one doesn't start without you.",
                        isOn: $profile.eventReminderNotificationsEnabled
                    )
                    toggleSettingsRow(
                        title: "Session starter",
                        subtitle: "A morning paralysis nudge if you haven't started anything 3 hrs after wake.",
                        isOn: $profile.sessionStarterNotificationsEnabled
                    )
                }

                settingsCard(title: "Calendar source", value: profile.calendarSource.isEmpty ? "Not connected yet" : profile.calendarSource)

                #if DEBUG
                // Debug builds only — stripped from Release. Nothing in the
                // shipping app writes `isPro` or `trialStartDate` yet, so the
                // `isPro || isInTrial` gate on AI Refine (DayPlanRefiner,
                // TasksTabView, HomeTabView) is unreachable without these.
                // Remove once real entitlement logic exists.
                settingsSection(title: "Debug — entitlements") {
                    toggleSettingsRow(
                        title: "Pro access",
                        subtitle: "Sets profile.isPro. Unlocks AI Refine in the Tasks tab and “plan my day” in Home chat.",
                        isOn: $profile.isPro
                    )
                    toggleSettingsRow(
                        title: "14-day trial",
                        subtitle: "Sets trialStartDate to now (clearing it turns the trial off). Expires 14 days after the date it writes.",
                        isOn: debugTrialBinding
                    )
                    settingsCard(title: "Entitlement now", value: debugEntitlementSummary)
                }

                settingsSection(title: "Debug — classifier harness") {
                    Text("Seeds backdated NudgeOutcome rows covering every branch NudgeOutcomeClassifier distinguishes, runs the real decision logic over them, and prints expected vs actual to the Xcode console. Deletes everything it created afterward.")
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: {
                        NudgeHaptics.medium()
                        NudgeOutcomeClassifierHarness.run(modelContext: modelContext)
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "testtube.2")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Run classifier harness")
                                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(NudgeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }
                    .buttonStyle(.plain)
                }
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        .task {
            notificationAuthorizationState = await NudgeNotificationService.shared.authorizationState()
        }
        .sheet(item: $activeTimeEditor) { destination in
            TimeSettingSheet(
                title: destination.title,
                initialValue: timeValue(for: destination),
                onConfirm: { newValue in
                    switch destination {
                    case .morningCheckIn:
                        // Keep wakeTime in sync — the arbiter reads
                        // `wakeTime ?? morningCheckInTime`, so writing only
                        // morningCheckInTime here would leave a stale
                        // wakeTime (set during onboarding) winning the
                        // coalesce and scheduling nudges off the old value.
                        profile.morningCheckInTime = newValue
                        profile.wakeTime = newValue
                    case .eveningCheckIn:
                        profile.eveningCheckInTime = newValue
                    case .bedtime:
                        profile.bedtime = newValue
                    case .quietHoursStart:
                        profile.quietHoursStartTime = newValue
                    case .quietHoursEnd:
                        profile.quietHoursEndTime = newValue
                    }
                    persistSettings()
                }
            )
        }
    }

    private var notificationPermissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notification access")
                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                .foregroundColor(NudgeTheme.textPrimary)

            Text(notificationPermissionMessage)
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.leading)

            if notificationAuthorizationState == .notDetermined {
                Button("Allow notifications") {
                    Task {
                        NudgeHaptics.light()
                        notificationAuthorizationState = await NudgeNotificationService.shared.requestAuthorizationIfNeeded()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(NudgeTheme.primary)
            } else if notificationAuthorizationState == .denied {
                Button("Open system settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .buttonStyle(.bordered)
                .tint(NudgeTheme.primary)
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

    private func settingsCard(title: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)

                Text(value)
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(NudgeTheme.textMuted)
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func toggleSettingsRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)

                Text(subtitle)
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(NudgeTheme.textMuted)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(NudgeTheme.primary)
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
        .onChange(of: isOn.wrappedValue) { _, _ in
            persistSettings()
        }
    }

    private func timeSettingsRow(title: String, subtitle: String, value: String, destination: TimeSettingDestination) -> some View {
        Button(action: {
            NudgeHaptics.light()
            activeTimeEditor = destination
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)

                    Text(subtitle)
                        .font(.custom(NudgeTheme.fontBody, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)
                        .multilineTextAlignment(.leading)

                    Text(value)
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.primary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NudgeTheme.textMuted)
            }
            .padding(16)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 18))
                .foregroundColor(NudgeTheme.textPrimary)

            content()
        }
    }

    private var notificationPermissionMessage: String {
        switch notificationAuthorizationState {
        case .notDetermined:
            return "Nudge has not requested notification access yet."
        case .denied:
            return "Notifications are blocked in iPhone settings. Enable them there to receive reminders."
        case .authorized:
            return "Notifications are enabled for Nudge."
        }
    }

    private func timeValue(for destination: TimeSettingDestination) -> Date {
        switch destination {
        case .morningCheckIn:
            return profile.morningCheckInTime
        case .eveningCheckIn:
            return profile.eveningCheckInTime
        case .bedtime:
            return profile.bedtime
        case .quietHoursStart:
            // Falls back to the sleep-derived window rather than "now" — an
            // unset custom time is what the arbiter itself falls back on, so
            // the row shows the hours actually in force.
            return profile.quietHoursStartTime
                ?? NudgeArbiter.sleepDerivedQuietHours(for: profile).start
        case .quietHoursEnd:
            return profile.quietHoursEndTime
                ?? NudgeArbiter.sleepDerivedQuietHours(for: profile).end
        }
    }

    /// Drives the "Match my sleep schedule" toggle, seeding the custom times
    /// from the derived window on the way OFF.
    ///
    /// Seeding matters: without it, turning the toggle off leaves both times
    /// nil, `quietWindow` falls back to the derived window anyway, and the
    /// two rows below would show hours the user never picked while the
    /// toggle claims they're custom. Seeded, flipping the switch is a
    /// genuine no-op until the user actually moves one.
    private var quietHoursFollowSleepBinding: Binding<Bool> {
        Binding(
            get: { profile.quietHoursFollowSleepSchedule },
            set: { follows in
                if !follows {
                    let derived = NudgeArbiter.sleepDerivedQuietHours(for: profile)
                    if profile.quietHoursStartTime == nil { profile.quietHoursStartTime = derived.start }
                    if profile.quietHoursEndTime == nil { profile.quietHoursEndTime = derived.end }
                }
                profile.quietHoursFollowSleepSchedule = follows
            }
        )
    }

    private func persistSettings() {
        try? modelContext.save()
    }

    #if DEBUG
    /// `trialStartDate` is a `Date?`, so it needs a derived Bool binding to
    /// drive a toggle. Reads back through `isInTrial` rather than a plain
    /// nil-check so a stale (>14 day old) start date shows as off, matching
    /// what the gate actually sees.
    private var debugTrialBinding: Binding<Bool> {
        Binding(
            get: { profile.isInTrial },
            set: { profile.trialStartDate = $0 ? Date() : nil }
        )
    }

    /// Mirrors the `isPro || isInTrial` expression the gates evaluate, so the
    /// row shows why AI Refine is on or off right now.
    private var debugEntitlementSummary: String {
        if profile.isPro { return "Pro — AI Refine unlocked" }
        if profile.isInTrial { return "Trial — AI Refine unlocked" }
        return "Free — AI Refine gated"
    }
    #endif
}

// MARK: - Time Setting Sheet

struct TimeSettingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialValue: Date
    let onConfirm: (Date) -> Void

    @State private var selectedValue: Date

    init(title: String, initialValue: Date, onConfirm: @escaping (Date) -> Void) {
        self.title = title
        self.initialValue = initialValue
        self.onConfirm = onConfirm
        _selectedValue = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                DatePicker(
                    title,
                    selection: $selectedValue,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipped()

                Button(action: {
                    NudgeHaptics.medium()
                    onConfirm(selectedValue)
                    dismiss()
                }) {
                    Text("Confirm")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(NudgeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }

                Spacer()
            }
            .padding(20)
            .background(NudgeTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

enum TimeSettingDestination: String, Identifiable {
    case morningCheckIn
    case eveningCheckIn
    case bedtime
    case quietHoursStart
    case quietHoursEnd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .morningCheckIn:
            return "Morning Check-in"
        case .eveningCheckIn:
            return "Evening Check-in"
        case .bedtime:
            return "Bedtime"
        case .quietHoursStart:
            return "Quiet Hours Start"
        case .quietHoursEnd:
            return "Quiet Hours End"
        }
    }
}
