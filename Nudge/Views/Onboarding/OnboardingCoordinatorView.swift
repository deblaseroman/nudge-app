//
//  OnboardingCoordinatorView.swift
//  Nudge
//
//  Routes each onboarding screen and applies the shared transition style.
//

import SwiftUI

struct OnboardingCoordinatorView: View {
    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        Group {
            switch viewModel.currentScreen {
            case .splash:
                SplashView(viewModel: viewModel)
                    .transition(.opacity)
            case .welcome:
                WelcomeStepView(viewModel: viewModel)
                    .transition(chatTransition)
            case .bedtime:
                BedtimeStepView(viewModel: viewModel)
                    .transition(chatTransition)
            case .wakeUp:
                WakeUpStepView(viewModel: viewModel)
                    .transition(chatTransition)
            case .routines:
                RoutineStepView(viewModel: viewModel)
                    .transition(chatTransition)
            case .calendar:
                CalendarImportStepView(viewModel: viewModel)
                    .transition(chatTransition)
            case .goals:
                GoalsStepView(viewModel: viewModel)
                    .transition(chatTransition)
            case .complete:
                OnboardingCompleteView(viewModel: viewModel)
                    .transition(chatTransition)
            }
        }
        .animation(NudgeAnimation.standard, value: viewModel.currentScreen)
    }

    private var chatTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}
