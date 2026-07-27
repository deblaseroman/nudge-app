//
//  AppOpenLog.swift
//  Nudge
//
//  A capped, self-pruning list of app-foreground timestamps in App Group
//  UserDefaults. Exists for exactly one question:
//
//      "Was the app open at any point between 2:15 and 3:15 PM yesterday?"
//
//  which is what `NudgeOutcomeClassifier` asks to separate `engaged` from
//  `ignored`.
//
//  ── WHY NOT EngagementState ────────────────────────────────────────────
//  `EngagementState` already tracks opens, but not in a form that can
//  answer the above: `lastAppOpenDate` is a SINGLE value overwritten on
//  every open, and `preferredHours` keeps hours-of-day with no dates. By
//  the time the sweep runs, `lastAppOpenDate` is almost always "just now".
//  It also only updates from `ContentView.onAppear` — a background →
//  foreground transition never touched it.
//
//  ── WHY NOT A @Model ───────────────────────────────────────────────────
//  A SwiftData row per app open would mean a fourth hand-synced schema
//  list (see ARCHITECTURE invariant 2), a fetch on the foreground hot
//  path, and unbounded growth in the same identity map the arbiter is
//  already careful about. A bounded array in the shared defaults is one
//  read + one write per foreground and prunes itself. If richer session
//  analytics are ever wanted, THAT is the point to promote this to a model
//  — not now.
//

import Foundation

enum AppOpenLog {
    private static let key = "nudge.appOpenTimestamps"

    /// Records a foreground. Called from both `ContentView.onAppear` and
    /// the scene-active handler, which fire together on a cold launch — so
    /// an open within 60s of the newest entry collapses into it rather
    /// than writing a duplicate.
    static func record(_ date: Date = Date()) {
        var stamps = timestamps()
        if let newest = stamps.last, date.timeIntervalSince(newest) < 60 { return }
        stamps.append(date)
        write(prune(stamps))
    }

    /// True if the app was foregrounded at any point inside `window`.
    static func didOpen(in window: ClosedRange<Date>) -> Bool {
        timestamps().contains { window.contains($0) }
    }

    /// Recorded foregrounds, oldest first.
    static func timestamps() -> [Date] {
        let raw = SharedModelContainer.appGroupDefaults
            .array(forKey: key) as? [Double] ?? []
        return raw.map { Date(timeIntervalSinceReferenceDate: $0) }
    }

    // MARK: - Storage

    private static func prune(_ stamps: [Date]) -> [Date] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -NudgeConfig.appOpenLogRetentionDays,
            to: Date()
        ) ?? .distantPast
        var kept = stamps.filter { $0 >= cutoff }.sorted()
        if kept.count > NudgeConfig.appOpenLogMaxEntries {
            kept.removeFirst(kept.count - NudgeConfig.appOpenLogMaxEntries)
        }
        return kept
    }

    private static func write(_ stamps: [Date]) {
        SharedModelContainer.appGroupDefaults.set(
            stamps.map { $0.timeIntervalSinceReferenceDate },
            forKey: key
        )
    }
}
