//
//  EngagementTracker.swift
//  Nudge
//
//  Records app usage events, updates streaks, computes engagement scores,
//  and manages the escalation state for the smart notification system.
//

import Foundation
import SwiftData

@MainActor
final class EngagementTracker {
    static let shared = EngagementTracker()

    // MARK: - Record App Open

    func recordAppOpen(modelContext: ModelContext) {
        let state = fetchOrCreate(context: modelContext)
        let calendar = Calendar.current
        let now = Date()

        // Reset daily counter if needed
        if let resetDate = state.appOpensResetDate, !calendar.isDateInToday(resetDate) {
            state.appOpensToday = 0
            state.appOpensResetDate = now
        }
        if state.appOpensResetDate == nil {
            state.appOpensResetDate = now
        }

        state.totalAppOpens += 1
        state.appOpensToday += 1
        state.lastAppOpenDate = now

        // Track preferred usage hours
        let hour = calendar.component(.hour, from: now)
        if !state.preferredHours.contains(hour) {
            state.preferredHours.append(hour)
            if state.preferredHours.count > 5 {
                state.preferredHours.removeFirst()
            }
        }

        updateStreak(state: state, calendar: calendar, now: now)
        updateEngagementScore(state: state, modelContext: modelContext)

        // Reset escalation on return
        if state.consecutiveInactiveDays > 0 {
            state.consecutiveInactiveDays = 0
            state.lastEscalationLevel = 0
        }

        try? modelContext.save()
    }

    // MARK: - Check Inactivity (call on app launch or background refresh)

    func updateInactivityState(modelContext: ModelContext) {
        let state = fetchOrCreate(context: modelContext)
        let calendar = Calendar.current

        guard let lastActive = state.lastActiveDate else { return }
        let daysSince = calendar.dateComponents([.day], from: lastActive, to: Date()).day ?? 0

        if daysSince > 0 && !calendar.isDateInToday(lastActive) {
            state.consecutiveInactiveDays = daysSince

            // Escalation levels: 1 = gentle, 2 = stronger, 3+ = urgent
            let newLevel = min(daysSince, 5)
            if newLevel > state.lastEscalationLevel {
                state.lastEscalationLevel = newLevel
                state.lastEscalationDate = Date()
            }

            // Break streak if missed a full day
            if daysSince > 1 {
                state.currentStreak = 0
            }
        }

        try? modelContext.save()
    }

    // MARK: - Record Notification Dismissed

    func recordNotificationIgnored(modelContext: ModelContext) {
        let state = fetchOrCreate(context: modelContext)
        state.notificationsIgnoredTotal += 1
        try? modelContext.save()
    }

    // MARK: - Engagement Score Formula
    //
    // Score 0–100 based on:
    //   - Streak length (max 30 pts)
    //   - Recent activity frequency (max 25 pts)
    //   - Notification tap rate (max 20 pts)
    //   - Task completion rate (max 25 pts)

    private func updateEngagementScore(state: EngagementState, modelContext: ModelContext) {
        var score: Double = 0

        // Streak component: 1 pt per day, max 30
        score += min(Double(state.currentStreak), 30)

        // Activity frequency: based on opens today vs average
        let frequencyScore: Double
        if state.averageSessionsPerDay > 0 {
            frequencyScore = min(Double(state.appOpensToday) / max(state.averageSessionsPerDay, 1) * 25, 25)
        } else {
            frequencyScore = state.appOpensToday > 0 ? 15 : 0
        }
        score += frequencyScore

        // Notification tap rate: 0–20 pts
        score += state.notificationTapRate * 20

        // Task completion: from today's stats
        let stats = fetchTodayStats(context: modelContext)
        if let stats, stats.tasksTotal > 0 {
            let completionRate = Double(stats.tasksCompleted) / Double(stats.tasksTotal)
            score += completionRate * 25
        }

        // Update rolling average sessions per day
        let totalDays = max(
            Calendar.current.dateComponents([.day], from: state.lastActiveDate ?? Date(), to: Date()).day ?? 1,
            1
        )
        state.averageSessionsPerDay = Double(state.totalAppOpens) / Double(totalDays)

        state.engagementScore = min(max(score, 0), 100)
    }

    // MARK: - Streak Logic

    private func updateStreak(state: EngagementState, calendar: Calendar, now: Date) {
        if let lastActive = state.lastActiveDate {
            if calendar.isDateInToday(lastActive) {
                // Already active today, no change
                return
            } else if calendar.isDateInYesterday(lastActive) {
                // Consecutive day
                state.currentStreak += 1
            } else {
                // Gap of more than 1 day — reset
                state.currentStreak = 1
            }
        } else {
            // First ever open
            state.currentStreak = 1
        }

        state.lastActiveDate = now

        if state.currentStreak > state.longestStreak {
            state.longestStreak = state.currentStreak
        }
    }

    // MARK: - Helpers

    private func fetchOrCreate(context: ModelContext) -> EngagementState {
        if let existing = (try? context.fetch(FetchDescriptor<EngagementState>()))?.first {
            return existing
        }
        let state = EngagementState()
        context.insert(state)
        return state
    }

    private func fetchTodayStats(context: ModelContext) -> DailyStats? {
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? .distantFuture
        let descriptor = FetchDescriptor<DailyStats>(
            predicate: #Predicate { $0.date >= today && $0.date < tomorrow }
        )
        return (try? context.fetch(descriptor))?.first
    }
}
