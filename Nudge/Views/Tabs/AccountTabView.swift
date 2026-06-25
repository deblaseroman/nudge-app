//
//  AccountTabView.swift
//  Nudge
//
//  User's personal data — name, email, plan status, and profile settings.
//

import SwiftUI
import SwiftData

struct AccountTabView: View {
    @Bindable var profile: UserProfile
    @Environment(\.modelContext) private var modelContext

    @State private var isEditingProfile = false
    @State private var editName = ""
    @State private var editEmail = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Account", subtitle: "Your profile, plan, and setup summary.")

                // Profile card
                VStack(spacing: 16) {
                    MascotAvatarView(size: 72)

                    Text(profile.name.isEmpty ? "Nudge User" : profile.name)
                        .font(.custom(NudgeTheme.fontSemiBold, size: 24))
                        .foregroundColor(NudgeTheme.textPrimary)

                    if !profile.email.isEmpty {
                        Text(profile.email)
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textSecondary)
                    }

                    Text(profile.isPro || profile.isInTrial ? "Pro access active" : "Free plan")
                        .font(.custom(NudgeTheme.fontMedium, size: 14))
                        .foregroundColor(NudgeTheme.primary)

                    Button(action: {
                        editName = profile.name
                        editEmail = profile.email
                        isEditingProfile = true
                    }) {
                        Text("Edit Profile")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                            .foregroundColor(NudgeTheme.primary)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(NudgeTheme.primary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(NudgeTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                        .stroke(NudgeTheme.border, lineWidth: 1)
                )

                // Personal info section
                sectionLabel("Personal Info")
                infoRow(label: "Name", value: profile.name.isEmpty ? "Not set" : profile.name)
                infoRow(label: "Email", value: profile.email.isEmpty ? "Not set" : profile.email)

                // Schedule section
                sectionLabel("Schedule")
                infoRow(label: "Bedtime", value: profile.bedtime.formatted(date: .omitted, time: .shortened))
                infoRow(label: "Wake time", value: profile.wakeTime?.formatted(date: .omitted, time: .shortened) ?? "Not set")
                infoRow(label: "Morning check-in", value: profile.morningCheckInTime.formatted(date: .omitted, time: .shortened))

                // Preferences section
                sectionLabel("Preferences")
                infoRow(label: "Calendar source", value: profile.calendarSource.isEmpty ? "Not connected" : profile.calendarSource)
                if profile.calendarSource == "Apple Calendar" {
                    infoRow(label: "Connected calendar", value: profile.connectedAppleCalendarTitle ?? "All calendars")
                }
                infoRow(label: "Widget style", value: profile.widgetStyle.capitalized)

                // Subscription section
                sectionLabel("Subscription")
                infoRow(label: "Plan", value: profile.isPro ? "Pro" : (profile.isInTrial ? "Trial" : "Free"))
                infoRow(label: "Daily messages used", value: "\(profile.dailyMessageCount)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(NudgeTheme.background)
        .sheet(isPresented: $isEditingProfile) {
            ProfileEditSheet(
                name: $editName,
                email: $editEmail,
                onSave: {
                    profile.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.email = editEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? modelContext.save()
                }
            )
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(NudgeTheme.fontSemiBold, size: 18))
            .foregroundColor(NudgeTheme.textPrimary)
            .padding(.top, 4)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.custom(NudgeTheme.fontMedium, size: 14))
                .foregroundColor(NudgeTheme.textMuted)

            Spacer()

            Text(value)
                .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                .foregroundColor(NudgeTheme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
        .background(NudgeTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusCard))
        .overlay(
            RoundedRectangle(cornerRadius: NudgeTheme.radiusCard)
                .stroke(NudgeTheme.border, lineWidth: 1)
        )
    }
}

// MARK: - Profile Edit Sheet

struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var name: String
    @Binding var email: String
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)

                    TextField("Your name", text: $name)
                        .font(.custom(NudgeTheme.fontBody, size: 16))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .padding(14)
                        .background(NudgeTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        .overlay(
                            RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                                .stroke(NudgeTheme.border, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Email")
                        .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                        .foregroundColor(NudgeTheme.textMuted)

                    TextField("your@email.com", text: $email)
                        .font(.custom(NudgeTheme.fontBody, size: 16))
                        .foregroundColor(NudgeTheme.textPrimary)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(14)
                        .background(NudgeTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                        .overlay(
                            RoundedRectangle(cornerRadius: NudgeTheme.radiusButton)
                                .stroke(NudgeTheme.border, lineWidth: 1)
                        )
                }

                Spacer()
            }
            .padding(20)
            .background(NudgeTheme.background)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        NudgeHaptics.medium()
                        onSave()
                        dismiss()
                    }
                    .font(.custom(NudgeTheme.fontSemiBold, size: 15))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
