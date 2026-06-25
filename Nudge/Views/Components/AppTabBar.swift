//
//  AppTabBar.swift
//  Nudge
//
//  Custom bottom tab bar with floating home button.
//

import SwiftUI

struct AppTabBar: View {
    @Binding var selectedTab: AppTab
    private let composer = ChatComposerStore.shared

    /// True when the floating button should act as a "send" button instead
    /// of a "go to chat" button.
    private var inSendMode: Bool {
        selectedTab == .home && composer.hasSendableText
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                sideTabButton(title: "Settings", systemImage: "gearshape.fill", tab: .settings)
                sideTabButton(title: "Calendar", systemImage: "calendar", tab: .calendar)
                sideTabButton(title: "Stats", systemImage: "chart.bar.fill", tab: .stats)
                sideTabButton(title: "Tasks", systemImage: "checklist", tab: .tasks)

                // Reserves room for the floating chat button on the right.
                Spacer()
                    .frame(width: 72)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .background(NudgeTheme.surface)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(NudgeTheme.border)
                    .frame(height: 1)
            }

            Button(action: handleFloatingTap) {
                Group {
                    if composer.isWaitingForAI && selectedTab == .home {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: inSendMode ? "paperplane.fill" : "message.fill")
                            .font(.system(size: 22, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(NudgeTheme.primary)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(NudgeTheme.surface, lineWidth: 6)
                )
                .shadow(color: NudgeTheme.primary.opacity(0.24), radius: 14, y: 6)
            }
            .disabled(composer.isWaitingForAI && selectedTab == .home)
            .animation(NudgeAnimation.standard, value: inSendMode)
            .animation(NudgeAnimation.standard, value: composer.isWaitingForAI)
            .offset(x: -23, y: -18)
            // HIG: icon-only controls need accessibility labels + hints so
            // VoiceOver users understand both the action and its current mode.
            .accessibilityLabel(floatingAccessibilityLabel)
            .accessibilityHint(floatingAccessibilityHint)
        }
        // HIG: respect Dynamic Type but cap growth at .accessibility2 so the
        // tab bar layout doesn't break catastrophically at AX5. Users beyond
        // this size will still get readable text in the rest of the app.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var floatingAccessibilityLabel: String {
        if composer.isWaitingForAI && selectedTab == .home { return "Sending message" }
        return inSendMode ? "Send message" : "Open chat"
    }

    private var floatingAccessibilityHint: String {
        if inSendMode { return "Sends what you've typed to Nudge." }
        return "Switches to the chat tab."
    }

    /// Sends the composer's text if the user has typed something while on
    /// the chat tab, otherwise jumps to the chat tab.
    private func handleFloatingTap() {
        NudgeHaptics.medium()
        if inSendMode, let send = composer.sendAction {
            send()
        } else {
            withAnimation(NudgeAnimation.standard) {
                selectedTab = .home
            }
        }
    }

    private func sideTabButton(title: String, systemImage: String, tab: AppTab) -> some View {
        let isSelected = selectedTab == tab
        return Button(action: {
            NudgeHaptics.light()
            withAnimation(NudgeAnimation.standard) {
                selectedTab = tab
            }
        }) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    // HIG: scale the icon with Dynamic Type (anchored to
                    // .caption so it doesn't grow as aggressively as body).
                    .font(.system(size: 16, weight: .semibold))
                    .imageScale(.medium)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)

                Text(title)
                    // `relativeTo:` ties the custom font to the system text
                    // style so it scales with the user's Dynamic Type setting.
                    .font(.custom(NudgeTheme.fontMedium, size: 11, relativeTo: .caption2))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(isSelected ? NudgeTheme.primary : NudgeTheme.textMuted)
            // HIG: every interactive control must have at least a 44pt hit
            // target. `maxWidth: .infinity` handles width; `minHeight: 44`
            // guarantees vertical reach. `contentShape` makes the entire
            // padded area tappable, not just the icon/label glyphs.
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // HIG: VoiceOver should announce the tab's title, the "selected"
        // state when active, and that it's a tab control rather than a
        // generic button.
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "Currently selected tab." : "Switches to the \(title) tab.")
    }
}
