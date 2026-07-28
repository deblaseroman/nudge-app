//
//  EisenhowerScorer.swift
//  Nudge
//
//  Pure, deterministic Swift scoring for task urgency × importance. Replaces
//  the old "LLM vibes a priority number" pattern with two explainable
//  functions whose inputs are well-defined and whose outputs are auditable.
//
//  Feeds NudgeArbiter's candidate ranking AND drives quadrant routing
//  (start-now vs. quick-win vs. get-ahead vs. break-down/silence).
//
//  Nothing in here is async, hits the network, or talks to SwiftData. The
//  arbiter does the I/O; this file does the math.
//

import Foundation

/// Where a candidate falls on the Eisenhower matrix. Drives WHICH nudge
/// template runs; the within-slot score then ranks candidates inside a slot.
enum EisenhowerQuadrant {
    /// Urgent + Important → start-now nudge / event-block reminder.
    case startNow
    /// Urgent + Not Important → quick-win idle nudge.
    case quickWin
    /// Not Urgent + Important → get-ahead nudge at recommended startBy.
    case getAhead
    /// Not Urgent + Not Important → break-it-down offer, or silence.
    case lowPriority
}

enum EisenhowerScorer {

    // MARK: - Urgency
    //
    // Pure function of slack. The closer the deadline gets relative to the
    // work remaining, the more urgent.
    //
    //     slack    = hoursUntilDue − effortHoursRemaining
    //     urgency  = 1 / (1 + exp(slack / k))
    //
    // At slack = 0  (just barely time to finish)        → 0.5
    // At slack ≈ −k (already behind by one k worth)     → ~0.73
    // At slack = +k (one k of headroom)                 → ~0.27
    // At slack = +2k                                    → ~0.12

    /// Logistic urgency curve. Inputs in hours; returns 0...1.
    static func urgency(hoursUntilDue: Double, effortHoursRemaining: Double) -> Double {
        let slack = hoursUntilDue - effortHoursRemaining
        let k = NudgeConfig.urgencySoftness
        return 1.0 / (1.0 + exp(slack / k))
    }

    // MARK: - Importance
    //
    // Weighted sum of stable signals. Category provides the base prior;
    // user-stated urgency, deep-work cognitive load, and dependencies bump
    // it. Clamped to 0...1.

    /// - Parameter stakes: the CONSEQUENCE signal (`NudgeTask.stakes`).
    ///   Defaults to `nil`, which contributes exactly nothing — so a caller
    ///   that doesn't pass it gets the identical pre-stakes number. Every
    ///   production call site is currently in that state on purpose: the
    ///   weights are being validated against real data through
    ///   `NudgeArbiter`'s DEBUG stakes-impact dump before they go live.
    static func importance(
        category: TaskCategory?,
        isDeepWork: Bool,
        statedUrgency: StatedUrgency,
        hasDependencies: Bool,
        stakes: TaskStakes? = nil
    ) -> Double {
        var score = baseImportance(for: category)

        // ── The correlated pair ──────────────────────────────────────────
        // `statedUrgency == .explicit` ("I said this is urgent") and
        // `stakes == .high` ("missing this has lasting consequences") land
        // on the same tasks far more often than not. Summed naively they
        // count one belief twice AND spend 0.45 of a 1.0 budget, which
        // shoves the pair into the clamp below and destroys the ordering
        // the stakes term was added to create. Capped, the pair costs 0.30.
        //
        // A `.low` penalty is NOT part of the cap — it's evidence pointing
        // the other way, so it applies in full and buys separation at the
        // bottom of the range where there's headroom to spend.
        let statedBonus = statedUrgency == .explicit ? 0.25 : 0.0
        let stakesTerm = stakes.flatMap { NudgeConfig.stakesImportanceBonus[$0] } ?? 0.0
        score += min(statedBonus + max(stakesTerm, 0), NudgeConfig.stakesSignalCombinedCap)
        score += min(stakesTerm, 0)

        if isDeepWork                 { score += 0.15 }
        if hasDependencies            { score += 0.10 }
        return min(max(score, 0), 1)
    }

    /// Looks up the per-category prior in `NudgeConfig.categoryImportance`.
    /// Returns `defaultCategoryImportance` when category is nil OR
    /// (defensively) when the dictionary is missing the case — the latter
    /// shouldn't happen for a closed enum but keeps callers safe if a case
    /// is added without updating the config dict.
    static func baseImportance(for category: TaskCategory?) -> Double {
        guard let category else { return NudgeConfig.defaultCategoryImportance }
        return NudgeConfig.categoryImportance[category] ?? NudgeConfig.defaultCategoryImportance
    }

    // MARK: - Final score
    //
    // Within-slot ranking. Urgency exponent is slightly higher than
    // importance because ADHD users under-produce deadline salience, so we
    // want time pressure to win ties.

    static func score(urgency: Double, importance: Double) -> Double {
        pow(urgency, NudgeConfig.urgencyExponent)
            * pow(importance, NudgeConfig.importanceExponent)
    }

    // MARK: - Quadrant routing

    static func quadrant(urgency: Double, importance: Double) -> EisenhowerQuadrant {
        let isUrgent    = urgency    >= NudgeConfig.urgentThreshold
        let isImportant = importance >= NudgeConfig.importantThreshold
        switch (isUrgent, isImportant) {
        case (true,  true):  return .startNow
        case (true,  false): return .quickWin
        case (false, true):  return .getAhead
        case (false, false): return .lowPriority
        }
    }
}
