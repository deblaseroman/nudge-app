//
//  CheckIn.swift
//  Nudge
//
//  Monthly check-in model. Never rename existing fields — add new ones instead.
//

import Foundation
import SwiftData

@Model
final class CheckIn {
    var id: UUID
    var date: Date
    var monthYear: String
    var aiInsights: String?
    var suggestedAdjustments: String?
    var wasApplied: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        monthYear: String = "",
        aiInsights: String? = nil,
        suggestedAdjustments: String? = nil,
        wasApplied: Bool = false
    ) {
        self.id = id
        self.date = date
        self.monthYear = monthYear
        self.aiInsights = aiInsights
        self.suggestedAdjustments = suggestedAdjustments
        self.wasApplied = wasApplied
    }
}
