//
//  DayWindow.swift
//  Nudge
//
//  The one derivation of "the user's planning window on a given day."
//

import Foundation

/// A day's planning window: wake + post-wake quiet → bed − pre-bed quiet.
///
/// **Wake is the anchor; bedtime is how far the day extends.** A bedtime
/// earlier on the clock than wake is late in *this* day, not early in the
/// previous one — bed 00:30 with wake 08:00 means the day runs 08:30 today
/// to 23:30 today. That is a property of what a "day" means here, not a
/// midnight special case; the historical bug (cycle 2026-08-02-01's
/// diagnosis) was every caller computing bedtime on the same calendar date
/// as wake, which put bed−60 in the *past* for past-midnight sleepers and
/// silently killed Plan my day for them.
///
/// This type exists because that window used to be derived inline in three
/// places (`planMyDay`, `DayPlanRefiner.refine`, `BusyWindowResolver
/// .dayLoad`) — all three with the same-calendar-day bug. Duplicated logic
/// drifting is this codebase's recurring burn (event durations ×4, countdown
/// text ×2); derive the window HERE or not at all.
struct DayWindow {
    /// Wake clock time realized on the requested day.
    let wake: Date
    /// Bed clock time, rolled to the next calendar day when it reads at or
    /// before wake.
    let bed: Date
    /// `wake + NudgeConfig.postWakeQuietMinutes` — where planning may begin.
    let start: Date
    /// `bed − NudgeConfig.preBedtimeQuietMinutes` — where planning must end.
    let end: Date

    /// Resolves the window for the calendar day containing `day`. `wake` and
    /// `bedtime` are clock-time Dates (only hour/minute are read), as stored
    /// on `UserProfile`. Returns nil when the buffered window still has no
    /// positive width — with the wake anchor that means a sleep schedule
    /// shorter than the two quiet buffers (~90 minutes), i.e. a
    /// misconfigured profile, not a late bedtime. Callers should fail OPEN
    /// and loud, never silently.
    static func resolve(
        on day: Date,
        wake: Date,
        bedtime: Date,
        calendar: Calendar = .current
    ) -> DayWindow? {
        let wakeComps = calendar.dateComponents([.hour, .minute], from: wake)
        let bedComps = calendar.dateComponents([.hour, .minute], from: bedtime)

        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = wakeComps.hour
        comps.minute = wakeComps.minute
        guard let wakeOnDay = calendar.date(from: comps) else { return nil }

        comps.hour = bedComps.hour
        comps.minute = bedComps.minute
        guard var bedOnDay = calendar.date(from: comps) else { return nil }

        // Bedtime at or before wake on the clock ⇒ it belongs to the next
        // calendar date. (Equal reads as a full 24h day — the least-wrong
        // reading of a degenerate config.)
        if bedOnDay <= wakeOnDay {
            guard let rolled = calendar.date(byAdding: .day, value: 1, to: bedOnDay) else { return nil }
            bedOnDay = rolled
        }

        let start = wakeOnDay.addingTimeInterval(Double(NudgeConfig.postWakeQuietMinutes) * 60)
        let end = bedOnDay.addingTimeInterval(-Double(NudgeConfig.preBedtimeQuietMinutes) * 60)
        guard end > start else { return nil }

        return DayWindow(wake: wakeOnDay, bed: bedOnDay, start: start, end: end)
    }
}
