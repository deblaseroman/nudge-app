//
//  DeviceActivityMonitorExtension.swift
//  NudgeActivityMonitor
//
//  The code iOS runs when a Screen Time threshold is crossed (Roman's
//  brief, Sep 25 2026). Target `NudgeActivityMonitor`, created in Xcode
//  Sep 25 2026; it also compiles Nudge/Models/DistractionSettings.swift
//  (membership exception in the pbxproj) and carries the App Group
//  `group.com.deblaser.nudge` plus the Family Controls entitlement. The
//  extension reads only App Group defaults: the settings, the snapshot the
//  app writes after every arbiter pass, and its own rung bookkeeping. It
//  never opens the store.
//
//  Placeholder copy by Roman's instruction: LIMIT 1 / 2 / 3, LIMIT BEDTIME,
//  LIMIT WINDDOWN, RANDOM LIMIT, MIRROR. No tokens spent.
//

import DeviceActivity
import Foundation
import UserNotifications

final class NudgeActivityMonitorExtension: DeviceActivityMonitor {
    private let appGroupID = "group.com.deblaser.nudge"
    private let lastRungAtKey = "nudge.distractions.lastRungAt"
    private let lastRungDayKey = "nudge.distractions.lastRungDay"
    private let mirrorLastFiredAtKey = "nudge.distractions.mirrorLastFiredAt"
    /// Every wake of this extension, newest last, capped (Oct 4 2026): the
    /// only evidence the app can read of whether iOS ever calls it. The
    /// app prints it at launch in DEBUG (`DistractionMonitor.debugDump`).
    private let breadcrumbsKey = "nudge.distractions.breadcrumbs"

    private func crumb(_ what: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        var list = defaults.array(forKey: breadcrumbsKey) as? [String] ?? []
        list.append("\(ISO8601DateFormatter().string(from: Date())) \(what)")
        if list.count > 40 { list.removeFirst(list.count - 40) }
        defaults.set(list, forKey: breadcrumbsKey)
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        crumb("intervalDidStart \(activity.rawValue)")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        crumb("intervalDidEnd \(activity.rawValue)")
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        crumb("eventDidReachThreshold \(event.rawValue) in \(activity.rawValue)")
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let settings = DistractionSettings.load(from: defaults)
        let now = Date()

        if event.rawValue == "nudge.mirror" {
            guard settings.mirrorEnabled else { return }
            // Once a week at most: the weekly schedule restarts on Sunday,
            // so one firing per interval is already the ceiling; the stamp
            // is for the Stats tab to read.
            defaults.set(now, forKey: mirrorLastFiredAtKey)
            post(id: "nudge.ext.mirror.\(dayStamp(now))",
                 title: "MIRROR",
                 body: "Hey, got a sec? I want to show you something.",
                 category: "category.mirror",
                 userInfo: ["nudgeKind": "mirror"])
            return
        }

        guard settings.limitLadderEnabled else { return }
        let rung: Int
        switch event.rawValue {
        case "nudge.limit.100": rung = 1
        case "nudge.limit.150": rung = 2
        case "nudge.limit.175": rung = 3
        default: rung = 0
        }
        let snapshot = DistractionSnapshot.load(from: defaults)
        let lastRungAt: Date? = {
            guard defaults.string(forKey: lastRungDayKey) == dayStamp(now) else { return nil }
            return defaults.object(forKey: lastRungAtKey) as? Date
        }()
        let decision = LimitDecider.decide(snapshot: snapshot, now: now, rung: rung, lastRungAt: lastRungAt)

        defaults.set(now, forKey: lastRungAtKey)
        defaults.set(dayStamp(now), forKey: lastRungDayKey)

        crumb("decision rung \(rung): \(decision.placeholderTitle.isEmpty ? "silent (\(decision.placeholderBody))" : decision.placeholderTitle)")
        if case .silent = decision { return }
        post(id: "nudge.ext.limit.\(dayStamp(now)).\(rung)",
             title: decision.placeholderTitle,
             body: decision.placeholderBody,
             category: "category.limit",
             userInfo: ["nudgeKind": "limit", "rung": rung])
    }

    private func post(id: String, title: String, body: String, category: String, userInfo: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [self] error in
            if let error {
                NSLog("[NudgeActivityMonitor] post failed: \(error)")
                crumb("post FAILED \(id): \(error.localizedDescription)")
            } else {
                crumb("posted \(id)")
            }
        }
    }

    private func dayStamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
