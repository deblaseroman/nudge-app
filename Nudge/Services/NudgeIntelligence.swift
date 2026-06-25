//
//  NudgeIntelligence.swift
//  Nudge
//
//  Per-task LLM signal extractor. Pulls two things from the task title and
//  caches them in `TaskIntelligence`:
//
//    • `statedUrgency` — did the user explicitly mark the task urgent in
//      the title ("urgent", "asap", "due tomorrow morning")? Feeds the
//      importance score as a +0.25 bump.
//    • `suggestedFirstStep` — a concrete sub-80-char "first move" copy
//      string shown in the editor and the countdown surface.
//
//  Everything else that used to live here — effort minutes, cognitive
//  load, session count, recommendedStartBy, isDeepWork — moved to
//  deterministic Swift modules:
//    DurationModel  → effort estimate (with on-device learning)
//    StartByPlanner → startBy / sessions / deep-work classification
//    BusyWindowResolver → event-overlap gate
//
//  Hard rules (unchanged from the previous version):
//    • Never block task creation on this. Runs async, after the task is
//      saved. UI must not depend on its completion.
//    • Always return a safe value, even when the network/AI is unavailable.
//    • Cache for `NudgeConfig.intelligenceCacheDays` so repeated lookups
//      are free and we don't burn tokens.
//

import Foundation
import SwiftData

@MainActor
final class NudgeIntelligence {
    static let shared = NudgeIntelligence()
    private init() {}

    // MARK: - Public API

    /// Returns the (cached or freshly computed) signals row for a task. If
    /// a cached row exists and is fresh, returns it immediately. Otherwise
    /// triggers an async refresh and returns the heuristic fallback so
    /// callers (UI + scoring) have something to use right away.
    func intelligence(for task: NudgeTask, modelContext: ModelContext) -> TaskIntelligence {
        if let cached = fetchCached(taskID: task.id, modelContext: modelContext),
           isFresh(cached) {
            return cached
        }

        Task { [weak self] in
            await self?.refresh(task: task, modelContext: modelContext)
        }

        return fallback(for: task)
    }

    /// Force a re-analysis (e.g. user edited the title).
    func refreshSoon(for task: NudgeTask, modelContext: ModelContext) {
        Task { [weak self] in
            await self?.refresh(task: task, modelContext: modelContext)
        }
    }

    // MARK: - Refresh path

    private func refresh(task: NudgeTask, modelContext: ModelContext) async {
        let prompt = buildPrompt(for: task)
        let parsed: TaskSignalsJSON? = try? await callAI(prompt: prompt)

        let row: TaskIntelligence
        if let parsed {
            row = TaskIntelligence(
                taskID: task.id,
                statedUrgency: parsed.statedUrgencyEnum,
                suggestedFirstStep: parsed.suggestedFirstStep,
                analyzedAt: Date()
            )
        } else {
            row = fallback(for: task)
        }

        upsert(row, modelContext: modelContext)
    }

    // MARK: - AI call

    private func callAI(prompt: String) async throws -> TaskSignalsJSON {
        let response = try await ClaudeService.shared.send(userMessage: prompt)
        guard let data = response.message.data(using: .utf8) else {
            throw NudgeIntelligenceError.malformed
        }
        return try JSONDecoder().decode(TaskSignalsJSON.self, from: data)
    }

    private func buildPrompt(for task: NudgeTask) -> String {
        let dueString = task.dueDate.map(ISO8601DateFormatter().string(from:)) ?? "none"
        let categoryString = task.category ?? "uncategorized"
        let today = ISO8601DateFormatter().string(from: Date())

        return """
        Return ONLY valid JSON matching this exact schema (no prose, no fences):
        {
          "statedUrgency": "none" | "explicit",
          "suggestedFirstStep": "<short concrete first action, under 80 chars>"
        }

        Task title: "\(task.title)"
        Category: \(categoryString)
        Due: \(dueString)
        Today: \(today)

        Rules:
        - statedUrgency: "explicit" if the title contains words like "urgent", \
        "asap", "due tonight", "due tomorrow", "deadline", "rush", or otherwise \
        signals time pressure directly. "none" otherwise. Do NOT mark explicit \
        based on the due date — only language in the title.
        - suggestedFirstStep: a tiny concrete action to lower activation energy. \
        Example: "Open the doc and write one sentence." Avoid generic openers \
        like "Get started" — name the first concrete move.
        """
    }

    // MARK: - Fallback
    //
    // Used when the AI is unreachable or the JSON fails to parse. We do
    // simple keyword detection for stated urgency and a generic first-step
    // string. The generic step is the same one the old fallback used —
    // ADHD users have validated that a permission-y phrasing works.

    private func fallback(for task: NudgeTask) -> TaskIntelligence {
        let lowered = task.title.lowercased()
        let urgencyKeywords: [String] = [
            "urgent", "asap", "rush", "deadline", "due tonight",
            "due tomorrow", "by tonight", "by tomorrow"
        ]
        let stated: StatedUrgency = urgencyKeywords.contains(where: { lowered.contains($0) })
            ? .explicit
            : .none

        return TaskIntelligence(
            taskID: task.id,
            statedUrgency: stated,
            suggestedFirstStep: "Open it. Write one sentence. That's the whole goal.",
            analyzedAt: Date()
        )
    }

    // MARK: - Cache

    private func fetchCached(taskID: UUID, modelContext: ModelContext) -> TaskIntelligence? {
        let descriptor = FetchDescriptor<TaskIntelligence>(
            predicate: #Predicate<TaskIntelligence> { $0.taskID == taskID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func isFresh(_ intel: TaskIntelligence) -> Bool {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -NudgeConfig.intelligenceCacheDays,
            to: Date()
        ) ?? .distantPast
        return intel.analyzedAt >= cutoff
    }

    private func upsert(_ new: TaskIntelligence, modelContext: ModelContext) {
        if let existing = fetchCached(taskID: new.taskID, modelContext: modelContext) {
            existing.statedUrgencyRaw = new.statedUrgencyRaw
            existing.suggestedFirstStep = new.suggestedFirstStep
            existing.analyzedAt = new.analyzedAt
        } else {
            modelContext.insert(new)
        }
        try? modelContext.save()
    }
}

// MARK: - DTO

private struct TaskSignalsJSON: Codable {
    let statedUrgency: String
    let suggestedFirstStep: String

    var statedUrgencyEnum: StatedUrgency {
        statedUrgency == "explicit" ? .explicit : .none
    }
}

private enum NudgeIntelligenceError: Error {
    case malformed
}
