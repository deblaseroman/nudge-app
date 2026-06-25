//
//  BedtimeStepView.swift
//  Nudge
//
//  Captures the user's preferred bedtime.
//

import SwiftUI
import SwiftData

struct BedtimeStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        OnboardingChatShell(viewModel: viewModel) {
            VStack(spacing: 12) {
                DatePicker(
                    "Bedtime",
                    selection: $viewModel.selectedBedtime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipped()

                Button(action: confirmBedtime) {
                    Text("This looks right")
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
                await viewModel.addMascotMessage("What time do you want to go to bed most nights?")
                await viewModel.addMascotMessage("I’ll use it to time reminders and keep your day from drifting too late.", delay: 0.2)
            }
        }
    }

    private func confirmBedtime() {
        NudgeHaptics.medium()
        viewModel.addUserMessage(viewModel.selectedBedtime.formatted(date: .omitted, time: .shortened))
        viewModel.saveBedtimeToProfile(modelContext)
        Task {
            await viewModel.addMascotMessage("Perfect. That gives me a real end point for the day.", delay: 0.3)
            try? await Task.sleep(for: .seconds(0.7))
            viewModel.advance()
        }
    }
}
