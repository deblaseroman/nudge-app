//
//  PrepTombstone.swift
//  Nudge
//
//  The durable record that the user DELETED a generated study task
//  (`source == "prep"`). A deletion is a decision and it persists
//  (`DESIGN.md`): `ExamPrepSweep` never recreates a tombstoned day, so the
//  record must survive the task's own removal — which is exactly why it
//  can't live on the task. One row per deleted (exam, day) pair.
//
//  Registered in the THREE hand-synced schema lists
//  (`SharedModelContainer.schema`, `widgetSchema` in
//  `NudgeWidget/NudgeWidget.swift`, the `#Preview` container in
//  `ContentView.swift`) and in the widget target's `membershipExceptions`
//  in project.pbxproj — a Models file is invisible to the widget until
//  hand-added there.
//

import Foundation
import SwiftData

@Model
final class PrepTombstone {
    var id: UUID
    /// `NudgeTask.id.uuidString` of the EXAM EVENT the deleted study task
    /// was linked to (its `linkedEventId`). String because that's what the
    /// link field stores.
    var examEventId: String
    /// The exam's title at deletion time — kept here so the message box can
    /// still name the exam if the event itself is later purged.
    var examTitle: String
    /// `yyyyMMdd` stamp of the STUDY DAY the deleted task covered (its due
    /// day). The sweep skips exactly this day for this exam; other days are
    /// unaffected.
    var dayStamp: String
    var deletedAt: Date
    /// When the Tasks message box surfaced its one-time "still want study
    /// time for this exam?" note. Nil = note still pending. The note is
    /// per-EXAM, not per-row: once any row for an exam is stamped, later
    /// tombstones for the same exam are inserted pre-stamped so the note
    /// never repeats.
    var noteShownAt: Date?

    init(
        id: UUID = UUID(),
        examEventId: String,
        examTitle: String,
        dayStamp: String,
        deletedAt: Date = Date(),
        noteShownAt: Date? = nil
    ) {
        self.id = id
        self.examEventId = examEventId
        self.examTitle = examTitle
        self.dayStamp = dayStamp
        self.deletedAt = deletedAt
        self.noteShownAt = noteShownAt
    }
}
