//
//  FocusSessionManager.swift
//  Nudge
//
//  Deprecated. Replaced by SessionCoordinator + LiveActivityManager.
//  Kept only as an inert placeholder so anything still referencing the
//  symbol compiles. Do not use in new code.
//

import Foundation

@MainActor
final class FocusSessionManager {
    static let shared = FocusSessionManager()

    let isActive = false

    private init() {}
}
