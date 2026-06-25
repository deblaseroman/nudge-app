//
//  CalendarImportStepView.swift
//  Nudge
//
//  Captures the user's preferred calendar source so events can be turned into tasks later.
//

import SwiftUI
import SwiftData

struct CalendarImportStepView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.modelContext) private var modelContext

    private let sources = ["Apple Calendar", "Canvas iCal", "Google Calendar", "I’ll do this later"]

    var body: some View {
        OnboardingChatShell(viewModel: viewModel) {
            VStack(spacing: 10) {
                ForEach(sources, id: \.self) { source in
                    Button(action: {
                        NudgeHaptics.light()
                        viewModel.selectedCalendarSource = source
                    }) {
                        HStack {
                            Text(source)
                                .font(.custom(NudgeTheme.fontMedium, size: 15))
                                .foregroundColor(NudgeTheme.textPrimary)

                            Spacer()

                            if viewModel.selectedCalendarSource == source {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(NudgeTheme.primary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(
                            viewModel.selectedCalendarSource == source ? NudgeTheme.primary.opacity(0.12) : NudgeTheme.surface
                        )
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        .overlay(
                            RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                                .stroke(NudgeTheme.border, lineWidth: 1)
                        )
                    }
                }

                if viewModel.selectedCalendarSource == "Canvas iCal" {
                    TextField("Paste your Canvas iCal URL", text: $viewModel.calendarImportURL)
                        .font(.custom(NudgeTheme.fontBody, size: 15))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                }

                Button(action: confirmCalendar) {
                    Text("Save calendar setup")
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
                await viewModel.addMascotMessage("Do you want me to pull from your calendars and turn events into tasks?")
                await viewModel.addMascotMessage("Pick the source you use most. You can finish the actual connection later if needed.", delay: 0.2)
            }
        }
    }

    private func confirmCalendar() {
        NudgeHaptics.medium()
        viewModel.addUserMessage(viewModel.selectedCalendarSource)
        viewModel.saveCalendarToProfile(modelContext)

        Task {
            let service = CalendarService.shared

            switch viewModel.selectedCalendarSource {
            case "Apple Calendar":
                let granted = await service.requestCalendarAccess()
                if granted {
                    // Reset the rolling cursor so first-time connection always
                    // imports the full 3-week window via the rolling path.
                    service.resetRollingWindowCursor()
                    let result = await service.refreshRollingWindow(modelContext: modelContext)
                        ?? CalendarImportResult(importedCount: 0, skippedDuplicates: 0, errors: [])
                    await viewModel.addMascotMessage(
                        "Nice! \(result.summary) I turned your calendar events into tasks.",
                        delay: 0.3
                    )
                } else {
                    await viewModel.addMascotMessage(
                        "No worries — you can connect your calendar later in Settings.",
                        delay: 0.3
                    )
                }

            case "Canvas iCal":
                let url = viewModel.calendarImportURL
                if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await viewModel.addMascotMessage(
                        "I'll need that URL to pull your assignments. You can add it later in Settings.",
                        delay: 0.3
                    )
                } else {
                    let result = await service.importCanvasICal(urlString: url, modelContext: modelContext)
                    if result.errors.isEmpty {
                        await viewModel.addMascotMessage(
                            "Nice! \(result.summary) Your Canvas deadlines are now tasks.",
                            delay: 0.3
                        )
                    } else {
                        await viewModel.addMascotMessage(
                            "Hmm, I couldn't reach that URL. Double-check it and try again in Settings.",
                            delay: 0.3
                        )
                    }
                }

            default:
                await viewModel.addMascotMessage(
                    "Nice. That will help me build your to-do list from real deadlines.",
                    delay: 0.3
                )
            }

            try? await Task.sleep(for: .seconds(0.7))
            viewModel.advance()
        }
    }
}
