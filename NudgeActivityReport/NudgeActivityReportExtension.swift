//
//  NudgeActivityReportExtension.swift
//  NudgeActivityReport
//
//  Stage two of Roman's notification brief (Sep 25 2026): the only code
//  Apple lets read Screen Time minutes. iOS renders this view inside the
//  Stats tab, in its own process; the app never sees the numbers, and
//  this process cannot write anything back (no App Group writes, no
//  network). One number and one sentence.
//
//  Target `NudgeActivityReport`, compiles Nudge/Models/DistractionSettings.swift
//  through a membership exception; entitlements carry Family Controls and
//  the App Group.
//

import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct NudgeActivityReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        MirrorReportScene { summary in
            MirrorReportView(summary: summary)
        }
    }
}

/// What the view shows: one number and one sentence (Roman, Sep 25 2026:
/// "it should not be this complicated"). The week runs Monday 00:00 to
/// Sunday 23:59; the rate is minutes so far over the part of the week
/// that has passed, carried over a year.
struct MirrorSummary {
    var weeklyMinutes: Double
    /// Fraction of the week elapsed at render time, Monday 00:00 = 0.
    var weekFractionElapsed: Double
    #if DEBUG
    var debugLine: String = ""
    #endif

    /// Days a year at this week's rate.
    var yearlyDays: Double {
        guard weekFractionElapsed > 0 else { return 0 }
        let perWeek = weeklyMinutes / weekFractionElapsed
        return perWeek * 52 / 60 / 24
    }
}

struct MirrorReportScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .init(DistractionSettings.mirrorReportContext)
    let content: (MirrorSummary) -> MirrorReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> MirrorSummary {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let now = Date()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(weekStart) / (7 * 24 * 3600)

        var total: Double = 0
        #if DEBUG
        var sources: [String] = []
        #endif
        for await d in data {
            var forDevice: Double = 0
            for await segment in d.activitySegments {
                forDevice += segment.totalActivityDuration / 60
            }
            total += forDevice
            #if DEBUG
            sources.append("\(d.device.name ?? "device")/\(d.device.model): \(Int(forDevice)) min")
            #endif
        }
        var summary = MirrorSummary(weeklyMinutes: total, weekFractionElapsed: min(max(elapsed, 0), 1))
        #if DEBUG
        summary.debugLine = "debug: \(sources.isEmpty ? "no sources" : sources.joined(separator: "; ")), week from \(weekStart.formatted(date: .abbreviated, time: .shortened))"
        #endif
        return summary
    }
}

/// System fonts: this process has no access to the app's theme or fonts.
struct MirrorReportView: View {
    let summary: MirrorSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(minutesText(summary.weeklyMinutes))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("this week")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Text("At this week's rate, you would spend \(daysText) days on these apps.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            Text(summary.debugLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
    }

    private func minutesText(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    private var daysText: String {
        let d = summary.yearlyDays
        return d < 10 ? String(format: "%.1f", d) : "\(Int(d.rounded()))"
    }
}
