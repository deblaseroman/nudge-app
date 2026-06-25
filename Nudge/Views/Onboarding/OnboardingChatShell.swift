//
//  OnboardingChatShell.swift
//  Nudge
//
//  Reusable chat container for all onboarding steps (02–09b).
//  Provides: header (mascot + step indicator + progress bar),
//  scrolling chat area with message bubbles, and a generic
//  bottom content slot for step-specific inputs.
//

import SwiftUI

struct OnboardingChatShell<BottomContent: View>: View {
    let viewModel: OnboardingViewModel
    @ViewBuilder let bottomContent: () -> BottomContent

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // 1px divider between header and chat
            Rectangle()
                .fill(NudgeTheme.border)
                .frame(height: 1)

            // Chat area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }

                        if viewModel.isTyping {
                            TypingIndicatorView()
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
                .background(NudgeTheme.surface)
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation(NudgeAnimation.standard) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.isTyping) { _, isTyping in
                    if isTyping {
                        // Scroll to show typing indicator
                        withAnimation(NudgeAnimation.standard) {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
            }

            // Bottom action area
            VStack(spacing: 0) {
                Rectangle()
                    .fill(NudgeTheme.border)
                    .frame(height: 1)

                bottomContent()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(NudgeTheme.surface)
        }
        .background(NudgeTheme.surface)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                // Mascot avatar + name + live dot
                HStack(spacing: 8) {
                    MascotAvatarView(size: 34)

                    HStack(spacing: 4) {
                        Text("Nudge")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 16))
                            .foregroundColor(NudgeTheme.textPrimary)

                        Circle()
                            .fill(NudgeTheme.success)
                            .frame(width: 6, height: 6)
                    }
                }

                Spacer()

                // Step indicator
                if let step = viewModel.currentStep {
                    Text("\(step) of \(OnboardingViewModel.totalSteps)")
                        .font(.custom(NudgeTheme.fontMedium, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                }
            }

            // Progress bar
            if let step = viewModel.currentStep {
                OnboardingProgressBar(
                    currentStep: step,
                    totalSteps: OnboardingViewModel.totalSteps
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(NudgeTheme.background)
    }
}
