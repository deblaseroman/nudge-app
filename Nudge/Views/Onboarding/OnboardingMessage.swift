//
//  OnboardingMessage.swift
//  Nudge
//
//  Ephemeral chat message model for the onboarding conversation flow.
//  Not persisted — onboarding messages are scripted per step.
//

import Foundation

struct OnboardingMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let text: String

    enum Role: Equatable {
        case mascot
        case user
    }
}
