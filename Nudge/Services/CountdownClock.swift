//
//  CountdownClock.swift
//  Nudge
//
//  Single ticker that drives every CountdownLabel in the app. One timer
//  publishing `now` every 60 seconds — every label observes it, no per-
//  label timer hot loops.
//
//  iOS pauses Timers when the app is backgrounded. The clock restarts on
//  scene-active via ContentView so countdowns immediately catch up when
//  the user returns.
//

import Foundation
import Observation

@Observable
@MainActor
final class CountdownClock {
    static let shared = CountdownClock()

    /// The "current time" all CountdownLabels read from. Updated every 60s.
    var now: Date = Date()

    private var timer: Timer?

    /// We DON'T auto-start in init. The lifecycle (start on scene-active,
    /// stop on background) is owned by `ContentView.onChange(of: scenePhase)`.
    /// Keeping the ticker dormant until then prevents a stray Timer from
    /// running before any countdown is even on screen.
    private init() {}

    /// Starts (or restarts) the 60-second ticker. Safe to call repeatedly —
    /// the previous timer is invalidated first.
    func start() {
        stop()
        // Snap to "now" right away so labels are accurate immediately.
        now = Date()
        // Reference the singleton inside the @MainActor task instead of
        // capturing self in the @Sendable timer closure — Swift 6 strict
        // concurrency disallows the latter.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                CountdownClock.shared.now = Date()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
