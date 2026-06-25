//
//  OnboardingViewModel.swift
//  Nudge
//
//  Central state machine for onboarding.
//  Persists the user's sleep schedule, routine habits, coaching preference,
//  calendar source, and personal goals for future use.
//

import SwiftUI
import SwiftData

@Observable
final class OnboardingViewModel {

    // MARK: - Navigation

    enum Screen: Int, CaseIterable {
        case splash = 0
        case welcome = 1
        case bedtime = 2
        case wakeUp = 3
        case routines = 4
        case calendar = 5
        case goals = 6
        case complete = 7
    }

    var currentScreen: Screen = .splash

    var currentStep: Int? {
        let raw = currentScreen.rawValue
        return (raw >= 1 && raw <= 6) ? raw : nil
    }

    static let totalSteps = 6

    // MARK: - Chat State

    var messages: [OnboardingMessage] = []
    var isTyping = false

    // MARK: - Screen State

    var userName = ""
    var nameConfirmed = false

    var selectedBedtime: Date = Calendar.current.date(from: DateComponents(hour: 23, minute: 0)) ?? Date()
    var bedtimeConfirmed = false

    var selectedWakeTime: Date = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
    var wakeTimeConfirmed = false

    struct RoutineDraft: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var time: Date
    }

    var routineDrafts: [RoutineDraft] = [
        RoutineDraft(
            title: "Morning meds",
            time: Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
        )
    ]
    var routinesConfirmed = false

    var selectedCalendarSource = "Apple Calendar"
    var calendarImportURL = ""
    var calendarConfirmed = false

    var selectedGoals: Set<String> = []
    var customGoal = ""
    var goalsConfirmed = false

    // MARK: - Navigation

    func advance() {
        guard let next = Screen(rawValue: currentScreen.rawValue + 1) else { return }
        messages = []
        isTyping = false
        currentScreen = next
    }

    // MARK: - Message Sequencing

    func resetConversation() {
        messages = []
        isTyping = false
    }

    func addMascotMessage(_ text: String, delay: TimeInterval = 0, typingDuration: TimeInterval = 0.7) async {
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        isTyping = true
        try? await Task.sleep(for: .seconds(typingDuration))
        isTyping = false

        withAnimation(NudgeAnimation.standard) {
            messages.append(OnboardingMessage(role: .mascot, text: text))
        }
    }

    func addUserMessage(_ text: String) {
        withAnimation(NudgeAnimation.standard) {
            messages.append(OnboardingMessage(role: .user, text: text))
        }
    }

    // MARK: - Draft Helpers

    func addRoutineDraft() {
        routineDrafts.append(
            RoutineDraft(
                title: "",
                time: Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
            )
        )
    }

    func removeRoutineDraft(id: UUID) {
        routineDrafts.removeAll { $0.id == id }
        if routineDrafts.isEmpty {
            addRoutineDraft()
        }
    }

    // MARK: - Persistence

    func saveNameToProfile(_ modelContext: ModelContext) {
        guard let profile = try? modelContext.fetch(FetchDescriptor<UserProfile>()).first else { return }
        profile.name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveBedtimeToProfile(_ modelContext: ModelContext) {
        guard let profile = try? modelContext.fetch(FetchDescriptor<UserProfile>()).first else { return }
        profile.bedtime = selectedBedtime
    }

    func saveWakeTimeToProfile(_ modelContext: ModelContext) {
        guard let profile = try? modelContext.fetch(FetchDescriptor<UserProfile>()).first else { return }
        profile.wakeTime = selectedWakeTime
        profile.morningCheckInTime = selectedWakeTime
    }

    func saveCalendarToProfile(_ modelContext: ModelContext) {
        guard let profile = try? modelContext.fetch(FetchDescriptor<UserProfile>()).first else { return }
        profile.calendarSource = selectedCalendarSource
        let trimmedURL = calendarImportURL.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.calendarImportURL = trimmedURL.isEmpty ? nil : trimmedURL
    }

    func saveRoutines(_ modelContext: ModelContext) {
        let existingHabits = (try? modelContext.fetch(FetchDescriptor<NudgeHabit>())) ?? []

        for draft in routineDrafts {
            let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { continue }

            if let existingHabit = existingHabits.first(where: { $0.title.caseInsensitiveCompare(trimmedTitle) == .orderedSame }) {
                existingHabit.reminderTime = draft.time
                existingHabit.isActive = true
            } else {
                let habit = NudgeHabit(title: trimmedTitle, emoji: "•", reminderTime: draft.time)
                modelContext.insert(habit)
            }
        }
    }

    func saveGoals(_ modelContext: ModelContext) {
        let existingGoals = (try? modelContext.fetch(FetchDescriptor<NudgeGoal>())) ?? []

        let presets: [String: String] = [
            "Read more": "📚",
            "Learn a language": "🗣️",
            "Work out": "💪",
            "Side project": "💻",
            "Journal": "✍️",
            "Sleep better": "😴",
        ]

        for title in selectedGoals.sorted() {
            if existingGoals.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                continue
            }
            modelContext.insert(NudgeGoal(title: title, emoji: presets[title] ?? "🎯"))
        }

        let trimmedCustomGoal = customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustomGoal.isEmpty && !existingGoals.contains(where: { $0.title.caseInsensitiveCompare(trimmedCustomGoal) == .orderedSame }) {
            modelContext.insert(NudgeGoal(title: trimmedCustomGoal, emoji: "🎯"))
        }
    }

    func completeOnboarding(_ modelContext: ModelContext) {
        guard let profile = try? modelContext.fetch(FetchDescriptor<UserProfile>()).first else { return }
        profile.onboardingComplete = true
    }
}
