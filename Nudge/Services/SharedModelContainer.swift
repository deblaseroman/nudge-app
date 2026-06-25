//
//  SharedModelContainer.swift
//  Nudge
//
//  Shared SwiftData container using App Groups so both the main app
//  and widget extension read/write the same database.
//

import Foundation
import SwiftData

struct SharedModelContainer {
    static let appGroupID = "group.com.deblaser.nudge"

    /// Shared App Group `UserDefaults` handle. Caching one instance avoids
    /// repeatedly initializing `UserDefaults(suiteName:)` in hot paths
    /// (every `scheduledIDs` getter call in the arbiter, every session
    /// state read in the coordinator, etc.). Repeated init can surface
    /// the benign CFPrefsPlistSource "kCFPreferencesAnyUser …" warning
    /// in Console; caching once per process matches Apple's recommended
    /// pattern and keeps reads/writes consistent.
    ///
    /// Force-unwrapped: this domain is declared in the App Group
    /// entitlement on both targets, so the only way `UserDefaults(suiteName:)`
    /// returns nil here is a misconfigured build, which we want to fail
    /// loudly at launch rather than silently lose data later.
    static let appGroupDefaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            fatalError("App Group \(appGroupID) is not configured on this target's entitlements.")
        }
        return defaults
    }()

    static let schema = Schema([
        NudgeTask.self,
        NudgeGoal.self,
        NudgeHabit.self,
        UserProfile.self,
        DailyStats.self,
        DailySession.self,
        CheckIn.self,
        CompletedTaskRecord.self,
        TimeBlock.self,
        EngagementState.self,
        NotificationEvent.self,
        SentNotificationFlag.self,
        NudgeOutcome.self,
        TaskIntelligence.self,
        CategoryDurationStats.self,
        EventDurationStats.self,
    ])

    nonisolated(unsafe) static var container: ModelContainer = {
        do {
            return try makeContainer()
        } catch {
            resetPersistentStore()

            do {
                return try makeContainer()
            } catch {
                do {
                    let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    return try ModelContainer(for: schema, configurations: [fallbackConfig])
                } catch {
                    fatalError("Could not create shared ModelContainer: \(error)")
                }
            }
        }
    }()

    private static func makeContainer() throws -> ModelContainer {
        let configuration: ModelConfiguration

        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let storeURL = groupURL.appendingPathComponent("Nudge.store")
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func resetPersistentStore() {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }

        let storeURL = groupURL.appendingPathComponent("Nudge.store")
        let sidecarURLs = [
            storeURL,
            storeURL.appendingPathExtension("wal"),
            storeURL.appendingPathExtension("shm")
        ]

        for url in sidecarURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
