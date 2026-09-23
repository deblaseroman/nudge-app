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

import CryptoKit
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

    /// Asks for a refresh of a task's signals. Safe to call on every
    /// lifecycle event (creation, editor open, editor save): it is a no-op
    /// while a cached row is fresh and its `inputHash` matches the task's
    /// current inputs, so only a new task or a changed title / category /
    /// due line reaches the API (Sep 23 2026; before this every call paid).
    /// Single-flight per taskID so overlapping calls collapse to one.
    ///
    /// `container` defaults to the shared store; the eval harness passes
    /// its own in-memory container so nothing it does touches the app's.
    func refreshSoon(for task: NudgeTask, in container: ModelContainer = SharedModelContainer.container) {
        let taskID = task.id
        guard inFlightRefreshTaskIDs.insert(taskID).inserted else { return }

        Task { @MainActor [weak self] in
            _ = await self?.refreshIfNeeded(task: task, in: container)
            self?.inFlightRefreshTaskIDs.remove(taskID)
        }
    }

    /// The awaitable form. Returns TRUE when an API call was made, FALSE
    /// when the cache answered. The harness counts these.
    @discardableResult
    func refreshIfNeeded(task: NudgeTask, in container: ModelContainer = SharedModelContainer.container) async -> Bool {
        // Inputs are read BEFORE the suspension point, on the main actor.
        let inputs = Inputs(task: task)
        let taskID = task.id
        let context = ModelContext(container)
        if let cached = fetchCached(taskID: taskID, modelContext: context),
           isFresh(cached), cached.inputHash == inputs.hash {
            #if DEBUG
            print("[NudgeIntelligence] cache hit for \"\(inputs.title)\" — no call")
            #endif
            return false
        }

        let signals = try? await ClaudeService.shared.analyzeTask(
            title: inputs.title, category: inputs.category, dueLine: inputs.dueLine
        )

        // Resumes on the main actor (this func is @MainActor), so the
        // SwiftData write below happens on the main thread.
        let row: TaskIntelligence
        if let signals {
            row = TaskIntelligence(
                taskID: taskID,
                statedUrgency: StatedUrgency(rawValue: signals.statedUrgency) ?? .none,
                suggestedFirstStep: signals.suggestedFirstStep,
                analyzedAt: Date()
            )
        } else {
            row = fallback(for: task)
        }
        row.inputHash = inputs.hash
        upsert(row, modelContext: ModelContext(container))
        return true
    }

    // MARK: - Prompt inputs

    /// Every value the prompt sees, and their hash. Anything added to the
    /// prompt must be added here or the cache will serve stale answers.
    private struct Inputs {
        let title: String
        let category: String
        let dueLine: String

        init(task: NudgeTask) {
            title = task.title
            category = task.category ?? "uncategorized"
            dueLine = task.dueDate.map(ISO8601DateFormatter().string(from:)) ?? "none"
        }

        var hash: String {
            let digest = SHA256.hash(data: Data("\(title)\u{1F}\(category)\u{1F}\(dueLine)".utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
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
