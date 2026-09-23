//
//  PlanProposalSweep.swift
//  Nudge
//
//  "Prepare the user for what's ahead" (cycle 2026-09-16-01, Roman's
//  realignment). For a task or event WITH A DUE DATE that is worth
//  preparing for, the app builds the subtasks that prepare for or complete
//  it, Opus explains them in the Tasks-tab message box, and the user's Yes
//  is the only thing that writes. A No changes nothing.
//
//  Two halves, deliberately split:
//
//    • THE READER (AI, proposes, writes nothing) — `runIfNeeded` picks the
//      anchored candidates deterministically, sends ONE batched Opus call
//      (`ClaudeService.proposePlans`), and stores each verdict in
//      `PlanProposalStore`: worth a plan (with sessions) or not. A verdict
//      is final for that anchor; if the anchor moves, it is void.
//
//    • THE WRITER (deterministic) — `accept` turns a stored proposal into
//      `NudgeTask` rows through the rules the exam sweep already has:
//      idempotent per (parent, day), tombstoned days never recreated.
//
//  THE TWO-CLOCK RULE governs what gets written: a session is SCHEDULED
//  (`intendedDate`), never DUE. Only the parent carries the anchor. That is
//  what stops a slipped study session from reading as "overdue calculus".
//
//  Runs in the day-change chain where `ExamPrepSweep` runs — before the
//  arbiter, never in its path (DESIGN.md) — and once after a capture or
//  import that may have created an anchored row. No key / offline: nothing
//  is proposed and nothing is written; the app adds only what the user
//  asked for.
//

import Foundation
import SwiftData

// MARK: - What the message box renders

/// One proposed session: a title, the day it is meant for, its length.
struct PlanSession: Equatable, Codable {
    let title: String
    /// `yyyyMMdd`, the exam sweep's stamp convention.
    let dayStamp: String
    let minutes: Int
}

/// A proposal awaiting the user's answer — read by the Tasks tab and
/// rendered by the message box with Yes / No.
struct PlanProposalContext: Equatable {
    let parentID: UUID
    let parentTitle: String
    /// Opus's one sentence — the headline.
    let reason: String
    let sessions: [PlanSession]
}

extension Notification.Name {
    /// Posted when a proposal lands or is answered, so a mounted Tasks tab
    /// re-reads without waiting for its next appear.
    static let nudgePlanProposalsChanged = Notification.Name("nudge.planProposals.changed")
}

// MARK: - Store (App Group defaults, JSON; no new @Model)

/// Per-parent decisions. One JSON blob keyed by the parent's id string.
/// `anchorStamp` is the anchor's day at decision time: a moved anchor voids
/// the decision, so the item becomes a candidate again.
enum PlanProposalStore {
    enum Status: String, Codable {
        case proposed, accepted, declined, notWorth
        /// The user made their own plan for this anchor (Roman, Sep 16:
        /// the app's subtasks are overwritten only when the user says so
        /// and makes their own). App-made sessions were removed; never
        /// re-proposed for this anchor.
        case userOwned
    }

    struct Decision: Codable {
        var status: Status
        var anchorStamp: String
        var parentTitle: String
        var reason: String
        var sessions: [PlanSession]
        var decidedAt: Date
    }

    static let key = "nudge.planProposals"
    static let callsDayKey = "nudge.planProposals.callsDay"
    static let callsCountKey = "nudge.planProposals.callsCount"

    static func all() -> [String: Decision] {
        let defaults = SharedModelContainer.appGroupDefaults
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Decision].self, from: data)
        else { return [:] }
        return decoded
    }

    static func write(_ decisions: [String: Decision]) {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        SharedModelContainer.appGroupDefaults.set(data, forKey: key)
    }

    static func set(_ decision: Decision, for parentID: UUID) {
        var decisions = all()
        decisions[parentID.uuidString] = decision
        write(decisions)
    }

    static func callsToday(now: Date = Date()) -> Int {
        let defaults = SharedModelContainer.appGroupDefaults
        guard defaults.string(forKey: callsDayKey) == NudgeCopyStore.dayStamp(now) else { return 0 }
        return defaults.integer(forKey: callsCountKey)
    }

    static func noteCall(now: Date = Date()) {
        let defaults = SharedModelContainer.appGroupDefaults
        let count = callsToday(now: now) + 1
        defaults.set(NudgeCopyStore.dayStamp(now), forKey: callsDayKey)
        defaults.set(count, forKey: callsCountKey)
    }
}

// MARK: - The chat's outstanding question

/// "Want me to build a study plan for X?" was asked in the Home chat this
/// turn. Held in app-group defaults for the rest of the day so the user's
/// one-word answer is routed to capture (not the small-talk lane) and so
/// the message box does not ask the same question a second way.
enum PlanQuestionStore {
    static let parentKey = "nudge.planQuestion.parentID"
    static let dayKey = "nudge.planQuestion.day"

    static func markAsked(parentID: UUID, now: Date = Date()) {
        let defaults = SharedModelContainer.appGroupDefaults
        defaults.set(parentID.uuidString, forKey: parentKey)
        defaults.set(NudgeCopyStore.dayStamp(now), forKey: dayKey)
    }

    static func outstandingParentID(now: Date = Date()) -> UUID? {
        let defaults = SharedModelContainer.appGroupDefaults
        guard defaults.string(forKey: dayKey) == NudgeCopyStore.dayStamp(now),
              let raw = defaults.string(forKey: parentKey)
        else { return nil }
        return UUID(uuidString: raw)
    }

    static func clear() {
        let defaults = SharedModelContainer.appGroupDefaults
        defaults.removeObject(forKey: parentKey)
        defaults.removeObject(forKey: dayKey)
    }
}

// MARK: - The sweep

@MainActor
final class PlanProposalSweep {
    static let shared = PlanProposalSweep()
    private init() {}

    private var inFlight = false

    // MARK: Candidates (deterministic)

    /// The anchor of a row: an event's time, a task's deadline. Nil for
    /// anything without a due date — the vision's rule: only due-dated
    /// things can receive a plan.
    /// The reader's subject test (Roman, Sep 23 2026: a 300-minute work
    /// shift was offered a plan to "spread it out"). Owed WORK can be
    /// prepared for or broken into sessions, so every deadline task
    /// qualifies. An EVENT is something you attend; there is nothing to
    /// prepare unless it is the exam-like thing work builds toward, which
    /// the app already identifies by category (`isExamTitle` at import,
    /// "exam" from capture). Stated on properties, never on the title.
    static func canBePreparedFor(_ task: NudgeTask) -> Bool {
        !task.isInformationalEvent || task.taskCategory == .exam
    }

    static func anchor(of task: NudgeTask) -> Date? {
        if task.isInformationalEvent { return task.specificTime ?? task.dueDate }
        return task.hasDeadline ? task.sortDeadline : nil
    }

    /// Does one of the user's own tasks read as THEIR plan for this
    /// anchored item? The exam sweep's title match, generalized past
    /// studying: a course phrase ("chem 101") anywhere in the title, or a
    /// shared subject token plus a preparing verb ("study", "pack",
    /// "confirm", ...). Deterministic; the user's plan always wins.
    static func userPlanMatch(parentTitle: String, taskTitles: [String]) -> String? {
        let subject = ExamPrepSweep.subjectTokens(parentTitle)
        let phrases = ExamPrepSweep.coursePhrases(parentTitle)
        let prepWords = ["study", "review", "prep", "practice", "revise", "cram",
                         "pack", "book", "confirm", "draft", "outline", "research",
                         "rehearse", "gather", "apply", "prepare", "plan"]
        for title in taskTitles {
            let lower = title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if phrases.contains(where: { lower.contains($0) }) { return title }
            let tokens = Set(lower.components(separatedBy: " ").filter { $0.count >= 2 })
            let hasPrepWord = prepWords.contains { lower.contains($0) }
            if hasPrepWord && !subject.isDisjoint(with: tokens) { return title }
        }
        return nil
    }

    /// The user's own plan overrides the app's (Roman, Sep 16). For every
    /// anchored parent that has app-made sessions, if one of the user's
    /// own open tasks now reads as their plan for it, the app's sessions
    /// are deleted and the anchor is marked `userOwned` so it is never
    /// proposed again. Deterministic, no tokens; runs ahead of every
    /// reader pass and after task edits. Returns rows removed.
    @discardableResult
    static func applyUserPlanOverrides(modelContext: ModelContext, now: Date = Date()) -> Int {
        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete }
        )
        descriptor.fetchLimit = 300
        let open = (try? modelContext.fetch(descriptor)) ?? []
        let sessionsByParent = Dictionary(grouping: open.filter { $0.source == "prep" && $0.linkedEventId != nil }) { $0.linkedEventId! }
        guard !sessionsByParent.isEmpty else { return 0 }
        let userTasks = open.filter { !$0.isInformationalEvent && $0.source != "prep" && $0.source != "commitment" && $0.linkedEventId == nil }

        var removed = 0
        var decisions = PlanProposalStore.all()
        for (parentIDString, sessions) in sessionsByParent {
            guard let parentID = UUID(uuidString: parentIDString),
                  let parent = open.first(where: { $0.id == parentID })
            else { continue }
            let others = userTasks.filter { $0.id != parent.id }.map(\.title)
            guard let hit = userPlanMatch(parentTitle: parent.title, taskTitles: others) else { continue }
            for session in sessions {
                modelContext.delete(session)
                removed += 1
            }
            let stamp = anchor(of: parent).map { ExamPrepSweep.stamp(Calendar.current.startOfDay(for: $0)) } ?? ""
            var decision = decisions[parentIDString] ?? PlanProposalStore.Decision(
                status: .userOwned, anchorStamp: stamp, parentTitle: parent.title,
                reason: "", sessions: [], decidedAt: now
            )
            decision.status = .userOwned
            decision.anchorStamp = stamp
            decision.decidedAt = now
            decisions[parentIDString] = decision
            #if DEBUG
            print("[PlanProposalSweep] \"\(parent.title)\": user's own plan \"\(hit)\" wins — \(sessions.count) app session(s) removed")
            #endif
        }
        if removed > 0 {
            try? modelContext.save()
            PlanProposalStore.write(decisions)
            NotificationCenter.default.post(name: .nudgePlanProposalsChanged, object: nil)
        }
        return removed
    }

    /// Open, anchored inside the horizon, not generated work, not a
    /// commitment (those expand on their own), not already decided for
    /// this anchor, and with nothing already pointing at it — neither a
    /// user-made plan (title match) nor existing sessions.
    static func candidates(in tasks: [NudgeTask], now: Date = Date()) -> [NudgeTask] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let horizonEnd = calendar.date(byAdding: .day, value: NudgeConfig.planProposalHorizonDays, to: today) ?? today
        let decisions = PlanProposalStore.all()

        let open = tasks.filter { !$0.isComplete }
        let childParentIDs = Set(open.compactMap(\.linkedEventId))
        let userTitles = open
            .filter { !$0.isInformationalEvent && $0.source != "prep" && $0.source != "commitment" && $0.linkedEventId == nil }
            .map(\.title)

        return open
            .filter { task in
                guard task.source != "prep", task.source != "commitment",
                      task.commitmentShapeRaw == nil,
                      task.linkedEventId == nil,
                      let anchor = anchor(of: task),
                      Self.canBePreparedFor(task)
                else { return false }
                let anchorDay = calendar.startOfDay(for: anchor)
                guard anchorDay >= today, anchorDay <= horizonEnd else { return false }
                // Needs at least one day before the anchor to put a session on.
                guard anchorDay > today else { return false }
                if let decision = decisions[task.id.uuidString],
                   decision.anchorStamp == ExamPrepSweep.stamp(anchorDay) {
                    return false
                }
                if childParentIDs.contains(task.id.uuidString) { return false }
                // The chat is already asking about this one.
                if PlanQuestionStore.outstandingParentID(now: now) == task.id { return false }
                let othersTitles = userTitles.filter { $0 != task.title }
                if userPlanMatch(parentTitle: task.title, taskTitles: othersTitles) != nil {
                    return false
                }
                return true
            }
            .sorted { (anchor(of: $0) ?? .distantFuture) < (anchor(of: $1) ?? .distantFuture) }
    }

    // MARK: Run

    /// Fire-and-forget. Returns immediately; the call and the store write
    /// happen off the launch path. Safe to call on every chain run: the
    /// per-day call cap and the decision store make repeats free.
    func runIfNeeded(modelContext: ModelContext, now: Date = Date()) {
        // The user's own plan wins first, every time, before any call.
        Self.applyUserPlanOverrides(modelContext: modelContext, now: now)
        guard !inFlight else { return }
        guard PlanProposalStore.callsToday(now: now) < NudgeConfig.planProposalCallsPerDay else { return }

        var descriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { !$0.isComplete }
        )
        descriptor.fetchLimit = 300
        let open = (try? modelContext.fetch(descriptor)) ?? []
        let batch = Array(Self.candidates(in: open, now: now).prefix(NudgeConfig.planProposalBatchSize))
        guard !batch.isEmpty else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let candidates: [ClaudeService.PlanProposalCandidate] = batch.compactMap { task in
            guard let anchor = Self.anchor(of: task) else { return nil }
            let anchorDay = calendar.startOfDay(for: anchor)
            let days = calendar.dateComponents([.day], from: today, to: anchorDay).day ?? 0
            let dueLine = CountdownState.dueDateLine(
                dueDate: task.dueDate, specificTime: task.specificTime
            ) ?? ""
            let when = days == 1 ? "tomorrow" : "in \(days) days"
            return ClaudeService.PlanProposalCandidate(
                id: task.id.uuidString,
                title: task.title,
                kind: task.isInformationalEvent ? "event" : "task",
                anchorLine: dueLine.isEmpty ? when : "\(when) (\(dueLine))",
                daysUntilAnchor: days,
                category: task.category ?? "personal",
                stakes: task.stakes?.rawValue ?? "medium",
                estimatedMinutes: task.estimatedMinutes
            )
        }
        guard !candidates.isEmpty else { return }

        // Titles + anchor stamps for the store, captured before the await.
        let stamps: [String: (title: String, stamp: String)] = Dictionary(uniqueKeysWithValues: batch.compactMap { task in
            guard let anchor = Self.anchor(of: task) else { return nil }
            return (task.id.uuidString, (task.title, ExamPrepSweep.stamp(calendar.startOfDay(for: anchor))))
        })

        inFlight = true
        PlanProposalStore.noteCall(now: now)
        Task { @MainActor [weak self] in
            defer { self?.inFlight = false }
            guard let results = try? await ClaudeService.shared.proposePlans(candidates: candidates) else {
                #if DEBUG
                print("[PlanProposalSweep] reader call failed — nothing stored, nothing written")
                #endif
                return
            }
            var decisions = PlanProposalStore.all()
            for result in results {
                guard let meta = stamps[result.id] else { continue }
                let sessions = Self.validSessions(result.sessions, today: today, daysUntilAnchor:
                    candidates.first { $0.id == result.id }?.daysUntilAnchor ?? 0, calendar: calendar)
                let worth = result.worthPlan && !sessions.isEmpty
                decisions[result.id] = PlanProposalStore.Decision(
                    status: worth ? .proposed : .notWorth,
                    anchorStamp: meta.stamp,
                    parentTitle: meta.title,
                    reason: result.reason,
                    sessions: sessions,
                    decidedAt: now
                )
                #if DEBUG
                print("[PlanProposalSweep] \"\(meta.title)\" → \(worth ? "PROPOSED \(sessions.count) session(s)" : "not worth a plan")")
                #endif
            }
            PlanProposalStore.write(decisions)
            NotificationCenter.default.post(name: .nudgePlanProposalsChanged, object: nil)
        }
    }

    /// The chat path (cycle 2026-09-16-01 item 3): the user already said
    /// yes to a study plan in the Home chat, so this reads the one parent,
    /// asks the reader to BUILD (not judge), writes the sessions at once,
    /// and announces them through the message box. No second Yes / No.
    /// `onWritten` runs on the main actor after rows land, so the caller
    /// can reevaluate the arbiter with its profile.
    func requestPlan(
        parentID: UUID,
        modelContext: ModelContext,
        now: Date = Date(),
        onWritten: @escaping @MainActor (Int) -> Void
    ) {
        guard let parent = try? modelContext.fetch(FetchDescriptor<NudgeTask>(
                  predicate: #Predicate<NudgeTask> { $0.id == parentID }
              )).first,
              !parent.isComplete,
              Self.canBePreparedFor(parent),
              let anchor = Self.anchor(of: parent)
        else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let anchorDay = calendar.startOfDay(for: anchor)
        let days = calendar.dateComponents([.day], from: today, to: anchorDay).day ?? 0
        guard days >= 1 else { return }

        let dueLine = CountdownState.dueDateLine(dueDate: parent.dueDate, specificTime: parent.specificTime) ?? ""
        let when = days == 1 ? "tomorrow" : "in \(days) days"
        let candidate = ClaudeService.PlanProposalCandidate(
            id: parent.id.uuidString,
            title: parent.title,
            kind: parent.isInformationalEvent ? "event" : "task",
            anchorLine: dueLine.isEmpty ? when : "\(when) (\(dueLine))",
            daysUntilAnchor: days,
            category: parent.category ?? "school",
            stakes: parent.stakes?.rawValue ?? "high",
            estimatedMinutes: parent.estimatedMinutes,
            consented: true
        )
        let title = parent.title
        let stamp = ExamPrepSweep.stamp(anchorDay)
        PlanProposalStore.noteCall(now: now)
        Task { @MainActor [weak self] in
            guard let self,
                  let results = try? await ClaudeService.shared.proposePlans(candidates: [candidate]),
                  let result = results.first
            else { return }
            let sessions = Self.validSessions(result.sessions, today: today, daysUntilAnchor: days, calendar: calendar)
            guard !sessions.isEmpty else {
                PlanProposalStore.set(PlanProposalStore.Decision(
                    status: .notWorth, anchorStamp: stamp, parentTitle: title,
                    reason: result.reason, sessions: [], decidedAt: now
                ), for: parentID)
                return
            }
            let proposal = PlanProposalContext(parentID: parentID, parentTitle: title, reason: result.reason, sessions: sessions)
            PlanProposalStore.set(PlanProposalStore.Decision(
                status: .proposed, anchorStamp: stamp, parentTitle: title,
                reason: result.reason, sessions: sessions, decidedAt: now
            ), for: parentID)
            let written = self.accept(proposal, modelContext: modelContext, now: now)
            if written > 0 {
                // Silent creation is not acceptable: the message box says
                // study time was added, the same line the old sweep used.
                ExamPrepSweep.writeAnnouncement(examTitle: title, daysUntil: days, now: now)
            }
            onWritten(written)
        }
    }

    /// Clamp what the reader returned to what the app will actually write:
    /// a session lands on a day from today up to the day before the anchor,
    /// runs 15–120 minutes, and there are at most `planProposalMaxSessions`.
    static func validSessions(
        _ raw: [ClaudeService.PlanProposalSession],
        today: Date,
        daysUntilAnchor: Int,
        calendar: Calendar
    ) -> [PlanSession] {
        var seen = Set<String>()
        var result: [PlanSession] = []
        for session in raw.sorted(by: { $0.dayOffset < $1.dayOffset }) {
            guard session.dayOffset >= 0, session.dayOffset < daysUntilAnchor,
                  let day = calendar.date(byAdding: .day, value: session.dayOffset, to: today)
            else { continue }
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let stamp = ExamPrepSweep.stamp(day)
            let dedupeKey = stamp + "|" + title.lowercased()
            guard seen.insert(dedupeKey).inserted else { continue }
            let minutes = min(max(session.minutes, NudgeConfig.planSessionMinMinutes), NudgeConfig.planSessionMaxMinutes)
            result.append(PlanSession(title: String(title.prefix(60)), dayStamp: stamp, minutes: minutes))
            if result.count == NudgeConfig.planProposalMaxSessions { break }
        }
        return result
    }

    // MARK: What the box shows

    /// The one proposal awaiting an answer: soonest anchor first, and only
    /// while its parent is still open with the same anchor. A stale
    /// proposal (parent done, deleted, or re-dated) is dropped here.
    func currentProposal(modelContext: ModelContext, now: Date = Date()) -> PlanProposalContext? {
        let decisions = PlanProposalStore.all()
        let proposed = decisions.filter { $0.value.status == .proposed }
        guard !proposed.isEmpty else { return nil }
        let calendar = Calendar.current

        var best: (PlanProposalContext, Date)?
        var pruned = decisions
        for (idString, decision) in proposed {
            guard let id = UUID(uuidString: idString),
                  let parent = try? modelContext.fetch(FetchDescriptor<NudgeTask>(
                      predicate: #Predicate<NudgeTask> { $0.id == id }
                  )).first,
                  !parent.isComplete,
                  let anchor = Self.anchor(of: parent),
                  ExamPrepSweep.stamp(calendar.startOfDay(for: anchor)) == decision.anchorStamp
            else {
                pruned.removeValue(forKey: idString)
                continue
            }
            let context = PlanProposalContext(
                parentID: id, parentTitle: parent.title, reason: decision.reason, sessions: decision.sessions
            )
            if best == nil || anchor < best!.1 { best = (context, anchor) }
        }
        if pruned.count != decisions.count { PlanProposalStore.write(pruned) }
        return best?.0
    }

    // MARK: The writer (deterministic)

    /// The user said Yes: one `NudgeTask` per session, SCHEDULED on its day
    /// (`intendedDate`), never due; linked to the parent; the parent's
    /// category and stakes. Idempotent per (parent, day, title) and
    /// tombstone-aware, the exam sweep's own rules. Returns how many rows
    /// were written. The caller saves and reevaluates.
    @discardableResult
    func accept(_ proposal: PlanProposalContext, modelContext: ModelContext, now: Date = Date()) -> Int {
        let parentIDString = proposal.parentID.uuidString
        let parentID = proposal.parentID
        let parent = try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.id == parentID }
        )).first

        let tombstoned = Set(((try? modelContext.fetch(FetchDescriptor<PrepTombstone>(
            predicate: #Predicate<PrepTombstone> { $0.examEventId == parentIDString }
        ))) ?? []).map(\.dayStamp))
        let existing = (try? modelContext.fetch(FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.linkedEventId == parentIDString }
        ))) ?? []
        let existingKeys = Set(existing.map { task in
            (task.intendedDate.map(ExamPrepSweep.stamp) ?? "") + "|" + task.title.lowercased()
        })

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var written = 0
        for session in proposal.sessions {
            guard !tombstoned.contains(session.dayStamp),
                  !existingKeys.contains(session.dayStamp + "|" + session.title.lowercased()),
                  let day = fmt.date(from: session.dayStamp)
            else { continue }
            let task = NudgeTask(
                title: session.title,
                priority: parent?.priority ?? "medium",
                category: parent?.category,
                source: "prep",
                estimatedMinutes: session.minutes,
                linkedEventId: parentIDString
            )
            task.intendedDate = Calendar.current.startOfDay(for: day)
            task.setStakesFromAutomation(parent?.stakes ?? .medium)
            modelContext.insert(task)
            written += 1
        }
        if written > 0 {
            try? modelContext.save()
            NudgeCopyGenerator.shared.noteShift(.generatedWork, modelContext: modelContext)
        }

        var decision = PlanProposalStore.all()[parentIDString] ?? PlanProposalStore.Decision(
            status: .accepted, anchorStamp: "", parentTitle: proposal.parentTitle,
            reason: proposal.reason, sessions: proposal.sessions, decidedAt: now
        )
        decision.status = .accepted
        decision.decidedAt = now
        PlanProposalStore.set(decision, for: proposal.parentID)
        NotificationCenter.default.post(name: .nudgePlanProposalsChanged, object: nil)
        #if DEBUG
        print("[PlanProposalSweep] accepted \"\(proposal.parentTitle)\": \(written) session(s) written, scheduled not due")
        #endif
        return written
    }

    /// The user said No: nothing written, never re-asked for this anchor.
    func decline(_ proposal: PlanProposalContext, now: Date = Date()) {
        var decision = PlanProposalStore.all()[proposal.parentID.uuidString] ?? PlanProposalStore.Decision(
            status: .declined, anchorStamp: "", parentTitle: proposal.parentTitle,
            reason: proposal.reason, sessions: proposal.sessions, decidedAt: now
        )
        decision.status = .declined
        decision.decidedAt = now
        PlanProposalStore.set(decision, for: proposal.parentID)
        NotificationCenter.default.post(name: .nudgePlanProposalsChanged, object: nil)
    }
}
