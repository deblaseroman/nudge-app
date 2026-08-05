//
//  GoalsTabView.swift
//  Nudge
//
//  Personal goals: the things the user keeps meaning to get to. Lists
//  active goals with how long each has been waiting, and owns add/edit/
//  remove. Onboarding lands here so the user sees the goals they just set.
//

import SwiftUI
import SwiftData

struct GoalsTabView: View {
    @Binding var selectedTab: AppTab
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NudgeGoal.createdAt) private var allGoals: [NudgeGoal]

    /// nil = sheet closed; `.add` = blank form; `.edit` = prefilled.
    @State private var editorMode: GoalEditorMode?

    private var activeGoals: [NudgeGoal] {
        allGoals.filter { $0.isActive }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    AccountShortcutButton(selectedTab: $selectedTab)
                    ScreenHeader(title: "Goals", subtitle: "The things you keep meaning to get to.")
                    Spacer(minLength: 0)
                }

                if activeGoals.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(activeGoals) { goal in
                            goalRow(goal)
                        }
                    }

                    addButton(label: "Add a goal")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(NudgeTheme.background)
        .sheet(item: $editorMode) { mode in
            GoalEditorSheet(mode: mode)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Rows

    private func goalRow(_ goal: NudgeGoal) -> some View {
        Button(action: {
            NudgeHaptics.light()
            editorMode = .edit(goal)
        }) {
            HStack(spacing: 12) {
                Text(goal.emoji.isEmpty ? "🎯" : goal.emoji)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(NudgeTheme.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))

                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.title)
                        .font(.custom(NudgeTheme.fontMedium, size: 16))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .lineLimit(2)

                    Text(elapsedLine(for: goal))
                        .font(.custom(NudgeTheme.fontBody, size: 13))
                        .foregroundColor(NudgeTheme.textMuted)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NudgeTheme.textPlaceholder)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NudgeTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                    .stroke(NudgeTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(goal.title), \(elapsedLine(for: goal))")
        .accessibilityHint("Opens this goal for editing.")
    }

    /// The row's second line. No activity tracking exists yet, so this
    /// reads from `createdAt` — "Set 3 weeks ago" states a fact without
    /// implying a lapse the user never started. When last-activity lands
    /// on the model, this becomes "Worked on N ago" for goals that have
    /// any.
    private func elapsedLine(for goal: NudgeGoal) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: goal.createdAt, relativeTo: Date())
        return "Set \(relative)"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("🎯")
                .font(.system(size: 40))

            Text("No goals yet")
                .font(.custom(NudgeTheme.fontSemiBold, size: 17))
                .foregroundColor(NudgeTheme.textPrimary)

            Text("What have you been meaning to get to? Set it here and Nudge will keep an eye on the time for you.")
                .font(.custom(NudgeTheme.fontBody, size: 14))
                .foregroundColor(NudgeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            addButton(label: "Set a goal")
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }

    private func addButton(label: String) -> some View {
        Button(action: {
            NudgeHaptics.light()
            editorMode = .add
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(NudgeTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor sheet

enum GoalEditorMode: Identifiable {
    case add
    case edit(NudgeGoal)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let goal): return goal.id.uuidString
        }
    }
}

struct GoalEditorSheet: View {
    let mode: GoalEditorMode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var emoji: String = "🎯"
    @State private var confirmingRemoval = false

    private static let emojiChoices = ["🎯", "📚", "🗣️", "💪", "💻", "✍️", "😴", "🎨", "🎸", "🏃"]

    private var editingGoal: NudgeGoal? {
        if case .edit(let goal) = mode { return goal }
        return nil
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingGoal == nil ? "New goal" : "Edit goal")
                .font(.custom(NudgeTheme.fontSemiBold, size: 20))
                .foregroundColor(NudgeTheme.textPrimary)

            TextField("What do you want to make space for?", text: $title)
                .font(.custom(NudgeTheme.fontBody, size: 15))
                .foregroundColor(NudgeTheme.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(NudgeTheme.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.emojiChoices, id: \.self) { choice in
                        Button(action: {
                            NudgeHaptics.light()
                            emoji = choice
                        }) {
                            Text(choice)
                                .font(.system(size: 22))
                                .frame(width: 44, height: 44)
                                .background(emoji == choice ? NudgeTheme.primary.opacity(0.12) : NudgeTheme.surfaceAlt)
                                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                                .overlay(
                                    RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                                        .stroke(emoji == choice ? NudgeTheme.primary : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Emoji \(choice)")
                        .accessibilityAddTraits(emoji == choice ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }

            Button(action: save) {
                Text(editingGoal == nil ? "Add goal" : "Save")
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(trimmedTitle.isEmpty ? NudgeTheme.primaryLight : NudgeTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
            }
            .buttonStyle(.plain)
            .disabled(trimmedTitle.isEmpty)

            if editingGoal != nil {
                Button(action: {
                    NudgeHaptics.light()
                    confirmingRemoval = true
                }) {
                    Text("Remove goal")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.overdue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Remove this goal?",
                    isPresented: $confirmingRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) { remove() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Tasks stay; Nudge just stops watching this one.")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(NudgeTheme.background)
        .onAppear {
            if let goal = editingGoal {
                title = goal.title
                emoji = goal.emoji.isEmpty ? "🎯" : goal.emoji
            }
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        NudgeHaptics.medium()
        if let goal = editingGoal {
            goal.title = trimmedTitle
            goal.emoji = emoji
        } else {
            modelContext.insert(NudgeGoal(title: trimmedTitle, emoji: emoji))
        }
        dismiss()
    }

    private func remove() {
        guard let goal = editingGoal else { return }
        NudgeHaptics.medium()
        modelContext.delete(goal)
        dismiss()
    }
}
