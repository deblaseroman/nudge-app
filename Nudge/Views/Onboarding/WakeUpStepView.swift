//
//  WakeUpStepView.swift
//  Nudge
//
//  Captures the user's usual wake-up time and stores it for morning check-ins.
//

import SwiftUI
import SwiftData

struct WakeUpStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        OnboardingChatShell(viewModel: viewModel) {
            VStack(spacing: 12) {
                DatePicker(
                    "Wake time",
                    selection: $viewModel.selectedWakeTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipped()

                Button(action: confirmWakeTime) {
                    Text("Morning check-in works")
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
                await viewModel.addMascotMessage("When do you usually wake up?")
                await viewModel.addMascotMessage("I’ll use this as your morning check-in time unless you change it later.", delay: 0.2)
            }
        }
    }

    private func confirmWakeTime() {
        NudgeHaptics.medium()
        viewModel.addUserMessage(viewModel.selectedWakeTime.formatted(date: .omitted, time: .shortened))
        viewModel.saveWakeTimeToProfile(modelContext)
        Task {
            await viewModel.addMascotMessage("Nice. I’ll start the day there.", delay: 0.3)
            try? await Task.sleep(for: .seconds(0.7))
            viewModel.advance()
        }
    }
}
