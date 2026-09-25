//
//  NudgeActivityReportExtension.swift
//  NudgeActivityReport
//
//  Stage two of Roman's notification brief (Sep 25 2026): the only code
//  Apple lets read Screen Time minutes. iOS renders this view inside the
//  Stats tab, in its own process; the app never sees the numbers, and
//  this process cannot write anything back (no App Group writes, no
//  network). It reads the day window the app wrote for the monitor
//  extension so the graph can split usage into the day window and the
//  quiet window, in two colors, as the brief asked.
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

/// What the view shows. Built once per render from the hourly segments
/// of the filter the app passed (this week, Sunday to now).
struct MirrorSummary {
    struct Day: Identifiable {
        let id: Int
        let label: String
        var dayWindowMinutes: Double = 0
        var quietMinutes: Double = 0
        var total: Double { dayWindowMinutes + quietMinutes }
    }

    var days: [Day]
    var dailyLimitMinutes: Int
    var weeklyMirrorMinutes: Int
    var windowLabel: String

    var weeklyMinutes: Double { days.reduce(0) { $0 + $1.total } }
    var weeklyDayWindowMinutes: Double { days.reduce(0) { $0 + $1.dayWindowMinutes } }
    var weeklyQuietMinutes: Double { days.reduce(0) { $0 + $1.quietMinutes } }
    /// This week's pace, carried over a year.
    var yearlyHours: Double { weeklyMinutes * 52 / 60 }

    static var empty: MirrorSummary {
        MirrorSummary(days: MirrorSummary.blankWeek(), dailyLimitMinutes: 30, weeklyMirrorMinutes: 263, windowLabel: "8:00 AM to 11:00 PM")
    }

    static func blankWeek() -> [Day] {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].enumerated().map { Day(id: $0.offset + 1, label: $0.element) }
    }
}

struct MirrorReportScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .init(DistractionSettings.mirrorReportContext)
    let content: (MirrorSummary) -> MirrorReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> MirrorSummary {
        let defaults = UserDefaults(suiteName: "group.com.deblaser.nudge")
        let settings = defaults.map { DistractionSettings.load(from: $0) } ?? DistractionSettings()
        let snapshot = defaults.flatMap { DistractionSnapshot.load(from: $0) }

        // The day window as clock minutes. The snapshot carries today's
        // wake + 30 and bedtime; the split uses the same line as the
        // monitor's daily schedule so the two colors mean what the
        // ladder means. Fallback when the app has not written one yet.
        let cal = Calendar.current
        func clockMinutes(_ d: Date) -> Int {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        let windowStart = snapshot.map { clockMinutes($0.dayStart) } ?? 8 * 60
        let windowEnd = snapshot.map { clockMinutes($0.bedtime) } ?? 23 * 60

        var days = MirrorSummary.blankWeek()
        for await d in data {
            for await segment in d.activitySegments {
                let start = segment.dateInterval.start
                let minutes = segment.totalActivityDuration / 60
                guard minutes > 0 else { continue }
                let weekday = cal.component(.weekday, from: start)
                guard let index = days.firstIndex(where: { $0.id == weekday }) else { continue }
                let clock = clockMinutes(start)
                let insideWindow: Bool = windowStart <= windowEnd
                    ? (clock >= windowStart && clock < windowEnd)
                    : (clock >= windowStart || clock < windowEnd)
                if insideWindow { days[index].dayWindowMinutes += minutes } else { days[index].quietMinutes += minutes }
            }
        }

        let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
        func label(_ mins: Int) -> String {
            let d = cal.date(bySettingHour: mins / 60, minute: mins % 60, second: 0, of: Date()) ?? Date()
            return fmt.string(from: d)
        }
        return MirrorSummary(days: days,
                             dailyLimitMinutes: settings.dailyLimitMinutes,
                             weeklyMirrorMinutes: settings.weeklyMirrorMinutes,
                             windowLabel: "\(label(windowStart)) to \(label(windowEnd))")
    }
}

/// The two-color week. System fonts and two fixed hues: this process has
/// no access to the app's theme or bundled fonts, and both hues read on
/// light and dark grounds.
struct MirrorReportView: View {
    let summary: MirrorSummary

    private let dayColor = Color(red: 0.95, green: 0.55, blue: 0.20)
    private let quietColor = Color(red: 0.40, green: 0.45, blue: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(minutesText(summary.weeklyMinutes))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("this week")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            chart
                .frame(height: 120)

            HStack(spacing: 14) {
                legend(color: dayColor, text: "Day window, \(summary.windowLabel)")
                legend(color: quietColor, text: "Quiet hours")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your limit is \(summary.dailyLimitMinutes) min a day, \(summary.dailyLimitMinutes * 7) a week. The mirror line is \(summary.weeklyMirrorMinutes).")
                Text("At this week's pace, a year is \(yearlyText).")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var chart: some View {
        let peak = max(summary.days.map(\.total).max() ?? 0, Double(summary.dailyLimitMinutes), 1)
        return GeometryReader { geo in
            let height = geo.size.height - 18
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(summary.days) { day in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(.quaternary).frame(height: height)
                            VStack(spacing: 0) {
                                Rectangle().fill(quietColor)
                                    .frame(height: height * CGFloat(day.quietMinutes / peak))
                                Rectangle().fill(dayColor)
                                    .frame(height: height * CGFloat(day.dayWindowMinutes / peak))
                            }
                            // The daily limit, drawn as a line across every bar.
                            Rectangle().fill(.primary.opacity(0.35))
                                .frame(height: 1)
                                .offset(y: -height * CGFloat(Double(summary.dailyLimitMinutes) / peak))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(day.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }

    private func minutesText(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    private var yearlyText: String {
        let hours = summary.yearlyHours
        if hours >= 48 { return String(format: "%.1f days", hours / 24) }
        return "\(Int(hours.rounded())) hours"
    }
}
