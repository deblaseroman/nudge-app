//
//  SmartNotificationEngine.swift
//  Nudge
//
//  Cleared in preparation for a new notification system. The smart/engagement
//  driven notification logic that previously lived here has been removed.
//

import Foundation
import SwiftData

@MainActor
final class SmartNotificationEngine {
    static let shared = SmartNotificationEngine()

    private init() {}

    func scheduleSmartNotifications(profile: UserProfile, modelContext: ModelContext) async {}

    func handleSmartNotificationTapped(userInfo: [AnyHashable: Any], modelContext: ModelContext) {}

    struct VariantStats {
        let sent: Int
        let tapped: Int
    }

    func variantPerformance(modelContext: ModelContext) -> [String: VariantStats] {
        [:]
    }
}
