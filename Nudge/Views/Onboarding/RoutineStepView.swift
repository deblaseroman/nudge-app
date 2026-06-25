//
//  RoutineStepView.swift
//  Nudge
//
//  Captures recurring daily routines and stores them as habits with reminder times.
//

import SwiftUI
import SwiftData

struct RoutineStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext

    private var hasValidRoutine: Bool {
        viewModel.routineDrafts.contains { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        OnboardingChatShell(viewModel: viewModel) {
            VStack(spacing: 12) {
                ForEach($viewModel.routineDrafts) { $draft in
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            TextField("Something you do often", text: $draft.title)
                                .font(.custom(NudgeTheme.fontBody, size: 15))
                                .foregroundColor(NudgeTheme.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background(NudgeTheme.surfaceAlt)
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))

                            Button(action: {
                                NudgeHaptics.light()
                                viewModel.removeRoutineDraft(id: draft.id)
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(NudgeTheme.textMuted)
                            }
                        }

                        DatePicker(
                            "Routine time",
                            selection: $draft.time,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(NudgeTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                    .overlay(
                        RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                            .stroke(NudgeTheme.border, lineWidth: 1)
                    )
                }

                Button(action: {
                    NudgeHaptics.light()
                    viewModel.addRoutineDraft()
                }) {
                    Text("Add another routine")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(NudgeTheme.primary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }

                Button(action: confirmRoutines) {
                    Text(hasValidRoutine ? "Save my routines" : "Skip for now")
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
                await viewModel.addMascotMessage("Tell me a few things you do consistently each day.")
                await viewModel.addMascotMessage("Classes, meds, workouts, meals, study blocks, anything I should remember.", delay: 0.2)
            }
        }
    }

    private func confirmRoutines() {
        NudgeHaptics.medium()
        let summaries = viewModel.routineDrafts
            .map { draft in
                draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        viewModel.addUserMessage(
            summaries.isEmpty ? "I’ll add these later" : summaries.prefix(3).joined(separator: ", ")
        )
        viewModel.saveRoutines(modelContext)

        Task {
            await viewModel.addMascotMessage("Great. I’ll treat those like anchors in your day.", delay: 0.3)
            try? await Task.sleep(for: .seconds(0.7))
            viewModel.advance()
        }
    }
}
