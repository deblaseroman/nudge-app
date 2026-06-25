//
//  GoalsStepView.swift
//  Nudge
//
//  Captures the user's personal goals and stores them in SwiftData.
//

import SwiftUI
import SwiftData

struct GoalsStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext

    private let presets = [
        "Read more",
        "Learn a language",
        "Work out",
        "Side project",
        "Journal",
        "Sleep better"
    ]

    var body: some View {
        OnboardingChatShell(viewModel: viewModel) {
            VStack(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(presets, id: \.self) { goal in
                        Button(action: {
                            NudgeHaptics.light()
                            if viewModel.selectedGoals.contains(goal) {
                                viewModel.selectedGoals.remove(goal)
                            } else {
                                viewModel.selectedGoals.insert(goal)
                            }
                        }) {
                            Text(goal)
                                .font(.custom(NudgeTheme.fontMedium, size: 14))
                                .foregroundColor(NudgeTheme.textPrimary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 52)
                                .padding(.horizontal, 8)
                                .background(
                                    viewModel.selectedGoals.contains(goal) ? NudgeTheme.primary.opacity(0.12) : NudgeTheme.surface
                                )
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                                .overlay(
                                    RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                                        .stroke(NudgeTheme.border, lineWidth: 1)
                                )
                        }
                    }
                }

                TextField("Add another goal", text: $viewModel.customGoal)
                    .font(.custom(NudgeTheme.fontBody, size: 15))
                    .foregroundColor(NudgeTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))

                Button(action: confirmGoals) {
                    Text("Finish setup")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(NudgeTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }
            }
        }
        .onAppear {
            guard viewModel.messages.isEmpty else { return }
            Task {
                await viewModel.addMascotMessage("Last one. What personal goals do you want to make space for?")
                await viewModel.addMascotMessage("This can be school, health, hobbies, or something you’ve been meaning to start.", delay: 0.2)
            }
        }
    }

    private func confirmGoals() {
        NudgeHaptics.medium()
        let goals = Array(viewModel.selectedGoals).sorted()
        let summary = !goals.isEmpty ? goals.prefix(3).joined(separator: ", ") : viewModel.customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.addUserMessage(summary.isEmpty ? "I’ll add goals later" : summary)
        viewModel.saveGoals(modelContext)

        Task {
            await viewModel.addMascotMessage("Perfect. I’ll keep those goals visible so the urgent stuff doesn’t crowd them out.", delay: 0.3)
            try? await Task.sleep(for: .seconds(0.7))
            viewModel.advance()
        }
    }
}
