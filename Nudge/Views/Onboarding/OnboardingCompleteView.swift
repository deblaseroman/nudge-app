//
//  OnboardingCompleteView.swift
//  Nudge
//
//  Final onboarding screen. Walks the user through summary → friendly
//  permission pre-prompt → system permission dialog → confirmation, then
//  marks onboarding complete. The pre-prompt is essential: without it, new
//  users finish onboarding never having seen the iOS permission dialog and
//  the entire notification system silently no-ops.
//

import SwiftUI
import SwiftData

struct OnboardingCompleteView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext

    /// Linear state machine. Each tap advances exactly one stage.
    private enum Stage {
        case summary       // celebratory summary card
        case prePrompt     // friendly mascot intro before the OS dialog
        case granted       // user allowed notifications
        case denied        // user denied; tell them where to flip later
    }

    @State private var stage: Stage = .summary
    @State private var didComplete = false
    @State private var isRequestingPermission = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            MascotAvatarView(size: 120)

            content
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .id(stage)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NudgeTheme.background)
        .animation(NudgeAnimation.standard, value: stage)
        .task {
            // If the user has already authorized (e.g. they re-ran onboarding),
            // skip the pre-prompt entirely so we don't waste a screen on a
            // dialog the OS will never show.
            let state = await NudgeNotificationService.shared.authorizationState()
            if state == .authorized && stage == .summary {
                // Leave them on the summary — they can hit Open Nudge once
                // and skip straight to the app.
            }
        }
    }

    // MARK: - Stage content

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .summary:    summaryContent
        case .prePrompt:  prePromptContent
        case .granted:    grantedContent
        case .denied:     deniedContent
        }
    }

    private var summaryContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("You’re set up")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 28))
                    .foregroundColor(NudgeTheme.textPrimary)

                Text("Nudge now knows your schedule, your routines, how you like to be nudged, and the goals you want to protect time for.")
                    .font(.custom(NudgeTheme.fontBody, size: 15))
                    .foregroundColor(NudgeTheme.textMuted)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                summaryRow(title: "Sleep", value: viewModel.selectedBedtime.formatted(date: .omitted, time: .shortened))
                summaryRow(title: "Wake up", value: viewModel.selectedWakeTime.formatted(date: .omitted, time: .shortened))
                summaryRow(title: "Calendar", value: viewModel.selectedCalendarSource)
            }
            .padding(18)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )

            primaryButton(title: "Continue") {
                NudgeHaptics.light()
                stage = .prePrompt
            }
        }
    }

    private var prePromptContent: some View {
        VStack(spacing: 20) {
            Text("One last thing")
                .font(.custom(NudgeTheme.fontSemiBold, size: 24))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("I need permission to send you notifications. This is how I remind you about tasks and keep you on track. Without this I can't do my job.")
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.center)

            primaryButton(
                title: isRequestingPermission ? "Asking…" : "Allow notifications",
                disabled: isRequestingPermission
            ) {
                Task { await askPermission() }
            }
        }
    }

    private var grantedContent: some View {
        VStack(spacing: 20) {
            Text("Perfect — I’ve got your back")
                .font(.custom(NudgeTheme.fontSemiBold, size: 24))
                .foregroundColor(NudgeTheme.textPrimary)
                .multilineTextAlignment(.center)

            Text("You'll hear from me when it matters — and only then.")
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.center)

            primaryButton(title: "Open Nudge") {
                finishOnboarding()
            }
        }
    }

    private var deniedContent: some View {
        VStack(spacing: 20) {
            Text("No worries")
                .font(.custom(NudgeTheme.fontSemiBold, size: 24))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("You can turn this on later in Settings if you change your mind.")
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(NudgeTheme.textMuted)
                .multilineTextAlignment(.center)

            primaryButton(title: "Open Nudge") {
                finishOnboarding()
            }
        }
    }

    // MARK: - Actions

    private func askPermission() async {
        isRequestingPermission = true
        let result = await NudgeNotificationService.shared.requestAuthorizationIfNeeded()
        isRequestingPermission = false
        // If iOS has already determined state (e.g. user already authorized
        // from a previous run), `.notDetermined` will not be returned —
        // anything other than authorized lands the user on the denied
        // screen so they know where to flip the switch.
        stage = (result == .authorized) ? .granted : .denied
    }

    private func finishOnboarding() {
        guard !didComplete else { return }
        didComplete = true
        NudgeHaptics.success()
        viewModel.completeOnboarding(modelContext)
    }

    // MARK: - Subviews

    private func summaryRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.custom(NudgeTheme.fontMedium, size: 14))
                .foregroundColor(NudgeTheme.textMuted)

            Spacer()

            Text(value)
                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                .foregroundColor(NudgeTheme.textPrimary)
        }
    }

    private func primaryButton(
        title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(disabled ? NudgeTheme.primary.opacity(0.5) : NudgeTheme.primary)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
        .disabled(disabled)
    }
}
