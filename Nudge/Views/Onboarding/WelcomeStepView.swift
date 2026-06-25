//
//  WelcomeStepView.swift
//  Nudge
//
//  Screen 02 — Welcome (step 1/7). Nudge asks the user's name.
//  Uses OnboardingChatShell with a text field + CTA bottom content.
//

import SwiftUI
import SwiftData

struct WelcomeStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext
    @FocusState private var isNameFieldFocused: Bool

    private var canSubmit: Bool {
        !viewModel.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        OnboardingChatShell(viewModel: viewModel) {
            if !viewModel.nameConfirmed {
                HStack(spacing: 10) {
                    // Name text field
                    TextField("Your first name", text: $viewModel.userName)
                        .font(.custom(NudgeTheme.fontBody, size: 16))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        .focused($isNameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { confirmName() }

                    // CTA button
                    Button(action: { confirmName() }) {
                        Text("That's me!")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                            .foregroundColor(.white)
                            .frame(height: 46)
                            .padding(.horizontal, 20)
                            .background(
                                canSubmit
                                    ? NudgeTheme.primary
                                    : NudgeTheme.primary.opacity(0.4)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .onAppear {
            startConversation()
        }
    }

    // MARK: - Conversation Script

    private func startConversation() {
        Task {
            await viewModel.addMascotMessage(
                "Hey there! I'm Nudge, your new productivity buddy \u{1F44B}",
                delay: 0.3,
                typingDuration: 0.6
            )
            await viewModel.addMascotMessage(
                "What should I call you?",
                delay: 0.4,
                typingDuration: 0.5
            )
            isNameFieldFocused = true
        }
    }

    private func confirmName() {
        guard canSubmit else { return }
        NudgeHaptics.medium()

        let name = viewModel.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.addUserMessage(name)
        viewModel.nameConfirmed = true
        viewModel.saveNameToProfile(modelContext)

        Task {
            await viewModel.addMascotMessage(
                "Good to meet you, \(name)! Let's get you set up \u{1F680}",
                delay: 0.5,
                typingDuration: 0.6
            )
            try? await Task.sleep(for: .seconds(1.0))
            viewModel.advance()
        }
    }
}
