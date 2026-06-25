//
//  EventDurationStats.swift
//  Nudge
//
//  Remembers how long named events take. Keyed by NORMALIZED event title
//  (lowercased + whitespace-trimmed) so "Bio 101 Lecture" and "bio 101
//  lecture" map to the same row. First time the user adds an event whose
//  duration is unknown, the AI capture flow (wired in step 6) asks them
//  how long it lasts and writes here. Future imports of the same title
//  skip the question.
//
//  Why title-keyed and not category-keyed?
//  ─────────────────────────────────────────
//  Category duration (`CategoryDurationStats`) describes "how long does
//  ANY school task take" — useful for unknown tasks. Event duration is
//  different: a specific class meets for a specific time, repeated weekly.
//  We don't want a chemistry lab (3 hours) influencing the estimate of a
//  history lecture (50 min). Per-title is the right granularity.
//

import Foundation
import SwiftData

@Model
final class EventDurationStats {
    /// Normalized title (see `EventDurationStats.normalize(_:)`). One
    /// row per unique title.
    var titleKey: String

    /// The user-confirmed duration in minutes. Replaced (not averaged) on
    /// each new sample — class times don't drift, the user just corrects
    /// the initial guess if it was wrong.
    var durationMinutes: Int

    /// Number of times this duration has been written. Currently
    /// informational only; future work may use it to decide whether to
    /// re-ask the user after multiple no-shows.
    var sampleCount: Int

    /// Last update timestamp.
    var updatedAt: Date

    init(
        title: String,
        durationMinutes: Int,
        sampleCount: Int = 1,
        updatedAt: Date = Date()
    ) {
        self.titleKey = Self.normalize(title)
        self.durationMinutes = durationMinutes
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }

    /// Title normalization. Lowercase + collapse internal whitespace +
    /// trim. Keep alphanumerics and spaces; strip punctuation that varies
    /// between captures ("CS 101!" vs "CS 101").
    static func normalize(_ title: String) -> String {
        let lowered = title.lowercased()
        let stripped = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet.whitespaces.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed
    }
}
