//
//  NudgeApp.swift
//  Nudge
//
//  Created by Roman DeBlase on 3/25/26.
//

import SwiftUI
import SwiftData

@main
struct NudgeApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            NudgeTask.self,
            NudgeGoal.self,
            NudgeHabit.self,
            UserProfile.self,
            DailyStats.self,
            CheckIn.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.deblaser.nudge")
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
