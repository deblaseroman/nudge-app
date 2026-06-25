//
//  StatedUrgency.swift
//  Nudge
//
//  Did the user explicitly call out the task as urgent in the title? Two
//  states only — `.explicit` adds a fixed +0.25 importance bump in
//  `EisenhowerScorer.importance`. `.none` is the default.
//
//  Lives in Models/ (not next to EisenhowerScorer) because the SwiftData
//  @Model macro on `TaskIntelligence` needs the type visible at macro
//  expansion time, which requires it to live alongside the model file.
//

import Foundation

enum StatedUrgency: String, Sendable {
    case none
    case explicit
}
