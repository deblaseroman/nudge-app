//
//  DistractionMonitor.swift
//  Nudge
//
//  App-side half of the Screen Time integration (Roman's brief, Sep 25
//  2026). Asks for Screen Time authorization, registers the two schedules
//  whose thresholds wake the `NudgeActivityMonitor` extension, and writes
//  the compact snapshot of today the extension reads (it cannot open the
//  store). The extension does the deciding and the posting; this file only
//  arms it.
//
//  Apple's lines: the app never sees usage minutes; it only names the apps
//  (through Apple's picker) and the thresholds. Authorization is the
//  individual kind, which works on any device registered to the developer
//  account; App Store distribution needs the Family Controls capability
//  approved by Apple.
//

import DeviceActivity
import FamilyControls
import Foundation
import SwiftData

@MainActor
final class DistractionMonitor {
    static let shared = DistractionMonitor()
    private init() {}

    static let dailyActivity = DeviceActivityName("nudge.daily")
    static let weeklyActivity = DeviceActivityName("nudge.weekly")
    static let limitEvent100 = DeviceActivityEvent.Name("nudge.limit.100")
    static let limitEvent150 = DeviceActivityEvent.Name("nudge.limit.150")
    static let limitEvent175 = DeviceActivityEvent.Name("nudge.limit.175")
    static let mirrorEvent = DeviceActivityEvent.Name("nudge.mirror")

    private let center = DeviceActivityCenter()

    var isAuthorized: Bool {
        AuthorizationCenter.shared.authorizationStatus == .approved
    }

    /// Screen Time authorization for this device's user. Throws when the
    /// user declines or the capability is missing from the build.
    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        var settings = DistractionSettings.load(from: SharedModelContainer.appGroupDefaults)
        settings.authorized = isAuthorized
        settings.save(to: SharedModelContainer.appGroupDefaults)
    }

    private static let registeredSignatureKey = "nudge.distractions.registeredSignature"

    /// Registers (or re-registers) both schedules from the saved settings
    /// and the profile's day window. Stops monitoring when there is no
    /// selection or both kinds are off. Called on every launch and after
    /// a Settings save; it does nothing when what it would register is
    /// what is already registered (the day window, the limit, the
    /// selection, the toggles), so a launch never restarts monitoring.
    func apply(profile: UserProfile, force: Bool = false) {
        let defaults = SharedModelContainer.appGroupDefaults
        let settings = DistractionSettings.load(from: defaults)

        let wakeForSig = profile.wakeTime ?? profile.morningCheckInTime
        let sigComps = Calendar.current.dateComponents([.hour, .minute], from: wakeForSig)
        let bedSigComps = Calendar.current.dateComponents([.hour, .minute], from: profile.bedtime)
        let signature = [
            "\(sigComps.hour ?? 0):\(sigComps.minute ?? 0)", "\(bedSigComps.hour ?? 0):\(bedSigComps.minute ?? 0)",
            "\(settings.dailyLimitMinutes)", "\(settings.limitLadderEnabled)", "\(settings.mirrorEnabled)",
            "\(isAuthorized)", settings.selectionData?.base64EncodedString() ?? "-"
        ].joined(separator: "|")
        if !force, defaults.string(forKey: Self.registeredSignatureKey) == signature { return }
        defaults.set(signature, forKey: Self.registeredSignatureKey)

        center.stopMonitoring([Self.dailyActivity, Self.weeklyActivity])

        guard isAuthorized,
              let data = settings.selectionData,
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data),
              settings.limitLadderEnabled || settings.mirrorEnabled
        else {
            #if DEBUG
            print("[DistractionMonitor] not monitoring (authorized=\(isAuthorized) selection=\(settings.hasSelection) ladder=\(settings.limitLadderEnabled) mirror=\(settings.mirrorEnabled))")
            #endif
            return
        }

        let cal = Calendar.current
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        let wakeComps = cal.dateComponents([.hour, .minute], from: wake)
        let bedComps = cal.dateComponents([.hour, .minute], from: profile.bedtime)

        if settings.limitLadderEnabled {
            // The day window: wake to bedtime, repeating daily. Usage in the
            // quiet window is outside it by construction (the Stats graph
            // still shows it, in its own color, through the report view).
            let daily = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: wakeComps.hour, minute: wakeComps.minute),
                intervalEnd: DateComponents(hour: bedComps.hour, minute: bedComps.minute),
                repeats: true
            )
            let limit = settings.dailyLimitMinutes
            let events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [
                Self.limitEvent100: DeviceActivityEvent(applications: selection.applicationTokens,
                                                        categories: selection.categoryTokens,
                                                        webDomains: selection.webDomainTokens,
                                                        threshold: DateComponents(minute: limit)),
                Self.limitEvent150: DeviceActivityEvent(applications: selection.applicationTokens,
                                                        categories: selection.categoryTokens,
                                                        webDomains: selection.webDomainTokens,
                                                        threshold: DateComponents(minute: Int(Double(limit) * 1.5))),
                Self.limitEvent175: DeviceActivityEvent(applications: selection.applicationTokens,
                                                        categories: selection.categoryTokens,
                                                        webDomains: selection.webDomainTokens,
                                                        threshold: DateComponents(minute: Int(Double(limit) * 1.75)))
            ]
            do {
                try center.startMonitoring(Self.dailyActivity, during: daily, events: events)
            } catch {
                #if DEBUG
                print("[DistractionMonitor] daily startMonitoring failed: \(error)")
                #endif
            }
        }

        if settings.mirrorEnabled {
            // Sunday 00:00 to Saturday 23:59, repeating: the week's sum plus
            // a quarter is the mirror's line.
            let weekly = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0, weekday: 1),
                intervalEnd: DateComponents(hour: 23, minute: 59, weekday: 7),
                repeats: true
            )
            let events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [
                Self.mirrorEvent: DeviceActivityEvent(applications: selection.applicationTokens,
                                                      categories: selection.categoryTokens,
                                                      webDomains: selection.webDomainTokens,
                                                      threshold: DateComponents(minute: settings.weeklyMirrorMinutes))
            ]
            do {
                try center.startMonitoring(Self.weeklyActivity, during: weekly, events: events)
            } catch {
                #if DEBUG
                print("[DistractionMonitor] weekly startMonitoring failed: \(error)")
                #endif
            }
        }
        #if DEBUG
        print("[DistractionMonitor] monitoring: daily limit \(settings.dailyLimitMinutes) min (ladder \(settings.limitLadderEnabled)), weekly mirror \(settings.weeklyMirrorMinutes) min (\(settings.mirrorEnabled))")
        #endif
    }

    /// Today, for the extension: the day window, open items on today's
    /// lens, today's events, and the last moment work happened. Called by
    /// the arbiter after every pass, so it is as fresh as the schedule.
    func writeSnapshot(profile: UserProfile, modelContext: ModelContext, now: Date = Date()) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let wake = profile.wakeTime ?? profile.morningCheckInTime
        guard let window = DayWindow.resolve(on: today, wake: wake, bedtime: profile.bedtime) else { return }
        let bedComps = cal.dateComponents([.hour, .minute], from: profile.bedtime)
        var bedtime = cal.date(bySettingHour: bedComps.hour ?? 23, minute: bedComps.minute ?? 0, second: 0, of: today) ?? window.end
        if bedtime < window.start { bedtime = cal.date(byAdding: .day, value: 1, to: bedtime) ?? bedtime }

        let all = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete }
        ))) ?? []
        var items: [DistractionSnapshot.Item] = []
        for t in NudgeTask.dayLens(among: all, on: today, now: now) {
            let mins = t.plannedDurationMinutes ?? t.estimatedMinutes ?? 30
            let end = t.plannedStartDate?.addingTimeInterval(Double(mins) * 60)
            items.append(.init(title: t.title, minutes: mins, isEvent: false, start: t.plannedStartDate, end: end))
        }
        for e in all where e.isInformationalEvent {
            guard let s = e.specificTime, cal.isDate(s, inSameDayAs: today) else { continue }
            let mins = e.eventDurationMinutes(modelContext: modelContext)
            items.append(.init(title: e.title, minutes: mins, isEvent: true, start: s, end: s.addingTimeInterval(Double(mins) * 60)))
        }

        let defaults = SharedModelContainer.appGroupDefaults
        var lastWork: Date? = defaults.object(forKey: NotificationScheduler.lastFocusSessionStartedAtKey) as? Date
        var recordDescriptor = FetchDescriptor<CompletedTaskRecord>(sortBy: [SortDescriptor(\.completedAt, order: .reverse)])
        recordDescriptor.fetchLimit = 1
        if let latest = (try? modelContext.fetch(recordDescriptor))?.first?.completedAt {
            lastWork = [lastWork, latest].compactMap { $0 }.max()
        }

        DistractionSnapshot(writtenAt: now, dayStart: window.start, dayEnd: window.end, bedtime: bedtime,
                            items: items, lastWorkAt: lastWork).save(to: defaults)
    }
}
