//
//  DistractionSettings.swift
//  Nudge
//
//  Roman's notification brief, Sep 25 2026: the user names the apps that
//  pull them away (Apple's picker) and a daily limit. Crossing the limit
//  during the day window fires the limit ladder (100 / 150 / 175 percent,
//  once each per day); crossing the weekly sum plus 25 percent fires the
//  mirror, once a week at most. iOS runs Nudge's DeviceActivity extension
//  at those moments; the extension cannot open the app's store, so the app
//  writes it a compact snapshot of today and it reads only App Group
//  defaults. Everything here is shared by the app and that extension, so
//  nothing in this file may import UI or SwiftData.
//

import Foundation

/// What the user set. Stored as JSON in App Group defaults.
struct DistractionSettings: Codable, Equatable {
    static let defaultsKey = "nudge.distractions.settings"
    /// The DeviceActivityReport context both the Stats tab (host) and the
    /// report extension (renderer) name; they must agree or nothing draws.
    static let mirrorReportContext = "nudge.mirror"

    /// The picked apps, as Apple's `FamilyActivitySelection` encoded by the
    /// app. Opaque here: only the FamilyControls framework can read it.
    var selectionData: Data? = nil
    var dailyLimitMinutes: Int = 30
    var limitLadderEnabled: Bool = true
    var mirrorEnabled: Bool = true
    /// Set once Screen Time authorization succeeded.
    var authorized: Bool = false

    var hasSelection: Bool { selectionData != nil }

    /// The weekly mirror threshold: seven days of the limit plus a quarter.
    var weeklyMirrorMinutes: Int { Int((Double(dailyLimitMinutes) * 7 * 1.25).rounded()) }

    static func load(from defaults: UserDefaults) -> DistractionSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(DistractionSettings.self, from: data) else { return DistractionSettings() }
        return s
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// What the extension needs to know about today, written by the arbiter
/// after every pass and on foreground. Small on purpose.
struct DistractionSnapshot: Codable {
    static let defaultsKey = "nudge.distractions.snapshot"

    struct Item: Codable {
        let title: String
        let minutes: Int
        let isEvent: Bool
        /// Events and placed tasks: when the block runs. Nil for unplaced.
        let start: Date?
        let end: Date?
    }

    let writtenAt: Date
    /// The day window: wake + 30 to bedtime − 60, and bedtime itself.
    let dayStart: Date
    let dayEnd: Date
    let bedtime: Date
    /// Open items on today's lens plus today's events.
    let items: [Item]
    /// The last session start or completion, for the ladder's tone rule.
    let lastWorkAt: Date?

    static func load(from defaults: UserDefaults) -> DistractionSnapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(DistractionSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Which line the ladder shows. Placeholder titles by Roman's instruction:
/// no tokens, no final copy, until the system is seen working.
enum LimitDecision: Equatable {
    /// Inside an event: say nothing.
    case silent(reason: String)
    /// Inside the last hour before bed, with a task that fits the minutes left.
    case bedtimeTask(title: String, minutesLeft: Int)
    /// Inside the last hour before bed, nothing fits.
    case windDown
    /// The plain ladder, rung 1 to 3, with the tone rule's verdict.
    case rung(Int, calmBecauseWorkedSince: Bool)
    /// Anything the brief did not name.
    case random(reason: String)

    var placeholderTitle: String {
        switch self {
        case .silent: return ""
        case .bedtimeTask: return "LIMIT BEDTIME"
        case .windDown: return "LIMIT WINDDOWN"
        case .rung(let n, _): return "LIMIT \(n)"
        case .random: return "RANDOM LIMIT"
        }
    }

    var placeholderBody: String {
        switch self {
        case .silent(let r): return r
        case .bedtimeTask(let title, let left): return "\(title) fits in the \(left) minutes before bed."
        case .windDown: return "It's almost bedtime. Wind down."
        case .rung(let n, let calm): return calm ? "Rung \(n), you worked since the last one." : "Rung \(n)."
        case .random(let r): return r
        }
    }
}

/// The pure decision, shared by the extension and the eval. Inputs only;
/// no clock, no store, no side effects.
enum LimitDecider {
    /// Minutes before bedtime that count as "late in the day".
    static let bedtimeWindowMinutes = 60

    static func decide(snapshot: DistractionSnapshot?, now: Date, rung: Int, lastRungAt: Date?) -> LimitDecision {
        guard let s = snapshot else { return .random(reason: "no snapshot written by the app yet") }
        guard Calendar.current.isDate(s.writtenAt, inSameDayAs: now) else {
            return .random(reason: "snapshot is from another day")
        }
        // Inside an event: silent.
        if let event = s.items.first(where: { $0.isEvent && ($0.start ?? .distantFuture) <= now && now < ($0.end ?? .distantPast) }) {
            return .silent(reason: "inside event \(event.title)")
        }
        // Outside the day window entirely (before wake, after bed): the
        // brief only covers the day; report it rather than guess.
        if now < s.dayStart { return .random(reason: "before the day window") }
        if now >= s.bedtime { return .random(reason: "after bedtime") }

        let minutesToBed = Int(s.bedtime.timeIntervalSince(now) / 60)
        if minutesToBed <= bedtimeWindowMinutes {
            let candidates = s.items.filter { !$0.isEvent && $0.minutes <= minutesToBed }
            if let pick = candidates.min(by: { $0.minutes < $1.minutes }) {
                return .bedtimeTask(title: pick.title, minutesLeft: minutesToBed)
            }
            return .windDown
        }
        guard (1...3).contains(rung) else { return .random(reason: "rung \(rung) is outside the ladder") }
        let workedSince: Bool = {
            guard let last = s.lastWorkAt else { return false }
            guard let previous = lastRungAt else { return false }
            return last > previous
        }()
        return .rung(rung, calmBecauseWorkedSince: workedSince)
    }
}
