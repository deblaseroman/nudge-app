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

    /// TaskIDs with an in-flight LLM refresh. Prevents repeated callers
    /// (e.g. NudgeArbiter.reevaluate, called many times per minute under
    /// rapid foreground/background cycling) from stacking up concurrent
    /// `Task { await refresh(...) }` blocks for the same task. Each such
    /// Task strongly captured a NudgeTask + ModelContext + an in-flight
    /// URLSession request while awaiting Claude — a confirmed contributor
    /// to the rapid-cycling memory jetsam.
    private var inFlightRefreshTaskIDs: Set<UUID> = []

    // MARK: - Public API — READ (synchronous, side-effect-free)

    /// READ-ONLY signal lookup. Returns the cached `TaskIntelligence` row if
    /// one exists and is still fresh; otherwise returns the deterministic
    /// keyword-based fallback.
    ///
    /// This method NEVER spawns a Task and NEVER writes to SwiftData, so it
    /// is safe to call from hot synchronous paths - notably every candidate
    /// builder inside `NudgeArbiter.reevaluate`, which runs on every
    /// foreground and every wake-time change. Keeping the read pure is what
    /// makes `reevaluate` provably free of off-main async work.
    ///
    /// LLM enrichment is triggered SEPARATELY and explicitly by
    /// `refreshSoon(for:)` at the only moments new signals can appear: task
    /// creation and task-title edits. The arbiter never triggers it.
    func cachedIntelligence(for task: NudgeTask, modelContext: ModelContext) -> TaskIntelligence {
        if let cached = fetchCached(taskID: task.id, modelContext: modelContext),
           isFresh(cached) {
            return cached
        }
        return fallback(for: task)
    }

    // MARK: - Public API — ENRICH (async, user-triggered only)

    /// Triggers an LLM re-analysis for a task. Call this ONCE when a task is
    /// created or its title changes — NOT on every read. Single-flight per
    /// taskID (via `inFlightRefreshTaskIDs`) so overlapping calls collapse to
    /// one network request instead of stacking up detached Tasks.
    ///
    /// Note there is no `modelContext` parameter: the refresh owns its own
    /// main-actor `ModelContext` built from the shared container, so it never
    /// captures — or outlives — a SwiftUI view's environment context. That
    /// removes the fragile "pass a thread-affined ModelContext into a
    /// fire-and-forget Task" pattern that caused the off-main SwiftData
    /// saves behind the "Call must be made on main thread" crashes.
    func refreshSoon(for task: NudgeTask) {
        let taskID = task.id
        guard inFlightRefreshTaskIDs.insert(taskID).inserted else { return }

        Task { @MainActor [weak self] in
            await self?.refresh(task: task)
            self?.inFlightRefreshTaskIDs.remove(taskID)
        }
    }

    // MARK: - Refresh path

    private func refresh(task: NudgeTask) async {
        // buildPrompt reads the task's fields BEFORE the suspension point —
        // done on the main actor, before we hand off to the network.
        let prompt = buildPrompt(for: task)
        let taskID = task.id
        let parsed: TaskSignalsJSON? = try? await callAI(prompt: prompt)

        // Resumes on the main actor (this func is @MainActor), so everything
        // below — the SwiftData write and its @Query-invalidation commit —
        // happens on the main thread.
        let row: TaskIntelligence
        if let parsed {
            row = TaskIntelligence(
                taskID: taskID,
                statedUrgency: parsed.statedUrgencyEnum,
                suggestedFirstStep: parsed.suggestedFirstStep,
                analyzedAt: Date()
            )
        } else {
            row = fallback(for: task)
        }

        // Own context from the shared container — created and used entirely
        // within this @MainActor body, never escaping.
        let context = ModelContext(SharedModelContainer.container)
        upsert(row, modelContext: context)
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
