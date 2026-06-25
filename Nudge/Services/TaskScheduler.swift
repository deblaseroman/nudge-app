//
//  TaskScheduler.swift
//  Nudge
//
//  Cleared in preparation for a new time block system. The previous
//  conflict-resolving scheduling engine has been removed. The TimeBlock
//  SwiftData model is intact so the rebuild can write to it directly.
//

import Foundation
import SwiftData

@MainActor
final class TaskScheduler {
    static let shared = TaskScheduler()

    private init() {}
}
