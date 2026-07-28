//
//  NudgeOutcomeClassifier.swift
//  Nudge
//
//  Resolves delivered-but-unanswered `NudgeOutcome` rows into a real
//  result. This is the RECORDING half of the learning loop — it writes
//  what happened to each nudge and nothing else. Whether anything acts on
//  the result is `NudgeConfig.fatigueGateEnabled`'s decision, and that is
//  currently OFF.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────
//  Only taps were ever captured. `.ignored` had no writer anywhere,
//  `.dismissed` was unreachable, and `NudgeArbiter.cancelAll` deleted every
//  pending row on every reevaluate — so the record of a delivered nudge was
//  destroyed minutes after it fired, before anything could judge it. The
//  fatigue gate could therefore never trip and break-it-down could never
//  fire. `cancelAll` now keeps past-due pending rows; this file is what
//  turns them into evidence.
//
//  ── THE THREE RESULTS ──────────────────────────────────────────────────
//  For a row whose fire time passed more than
//  `outcomeClassificationGraceMinutes` ago, look at the response window
//  [fireDate, fireDate + outcomeActionWindowMinutes]:
//
//    .acted    — the user did the thing it asked for inside the window
//    .engaged  — the app was opened inside the window, but no action
//    .ignored  — the app was never opened inside the window
//
//  Taps are NOT handled here: `NudgeNotificationService` writes those
//  synchronously, so a tapped row is no longer `pending` and this sweep
//  never sees it. A row reaching this file is by definition one the user
//  did not touch on the notification itself.
//
//  Grace > window is load-bearing: it guarantees every window being judged
//  is already closed, so the foreground that RUNS the sweep can never be
//  mistaken for engagement with the row it is classifying.
//
//  ── WHAT `.ignored` DOES NOT MEAN ──────────────────────────────────────
//  `.ignored` is written for EVERY kind, including the ones whose success
//  case never touches the app. A "Class in 1 hour" reminder that worked
//  perfectly lands here as `.ignored`, because the user read it and went to
//  class. That is recorded faithfully and is not a bug in this file — it IS
//  what happened as far as the app can see. The bug would be treating it as
//  failure, so `NudgeOutcomeKind.successIsObservableInApp` marks those kinds
//  and both fatigue consumers in `NudgeArbiter` skip their rows.
//
//  `NudgeOutcome.feedback` (the 👍/👎 notification actions) is the channel
//  built to break the tie behaviour can't. It lives in its own column so a
//  row can say `.ignored` and `markedHelpful` at once.
//

import Foundation
import SwiftData

@MainActor
final class NudgeOutcomeClassifier {

    static let shared = NudgeOutcomeClassifier()
    private init() {}

    // MARK: - Sweep

    /// Classifies every pending row whose fire time passed more than the
    /// grace period ago. Safe to call on every foreground: rows it resolves
    /// stop being `pending`, so each row is judged exactly once.
    @discardableResult
    func classifyPending(modelContext: ModelContext) -> Int {
        let now = Date()
        let rows = sweepableRows(now: now, modelContext: modelContext)
        guard !rows.isEmpty else { return 0 }

        let count = resolve(rows, now: now, modelContext: modelContext)
        #if DEBUG
        print("[NudgeOutcomeClassifier] Classified \(count) delivered nudge(s).")
        #endif
        return count
    }

    /// The pending rows a sweep running at `now` would resolve: past the
    /// grace period, still `pending`.
    ///
    /// Split out of `classifyPending` so the DEBUG harness can ask "would
    /// this row be picked up?" without running a sweep — that predicate is
    /// itself a behaviour worth testing (a row inside the grace period must
    /// stay pending), and it's the half the harness can't exercise by
    /// calling `resolve` directly.
    private func sweepableRows(now: Date, modelContext: ModelContext) -> [NudgeOutcome] {
        let graceCutoff = now.addingTimeInterval(
            -Double(NudgeConfig.outcomeClassificationGraceMinutes) * 60
        )

        // Bounded like every other outcome fetch in the app — the shared
        // main context is memory-sensitive and an unbounded backlog would
        // be pulled in whole. Anything past the limit gets swept on the
        // next foreground.
        var descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> {
                $0.resultRaw == "pending" && $0.scheduledFor < graceCutoff
            },
            sortBy: [SortDescriptor(\.scheduledFor)]
        )
        descriptor.fetchLimit = 200
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Applies the acted / engaged / ignored decision to `rows` and saves.
    ///
    /// Takes rows as a parameter rather than fetching them so the DEBUG
    /// harness can run the REAL decision logic over its own seeded rows
    /// only — a harness that called `classifyPending` would sweep the
    /// user's genuine pending rows too, and would judge them against the
    /// fake session-start / app-open state the harness has to inject.
    @discardableResult
    private func resolve(
        _ rows: [NudgeOutcome],
        now: Date,
        modelContext: ModelContext
    ) -> Int {
        for row in rows {
            let windowEnd = row.scheduledFor.addingTimeInterval(
                Double(NudgeConfig.outcomeActionWindowMinutes) * 60
            )
            let window = row.scheduledFor...windowEnd

            let result: NudgeOutcomeResult
            if performedAction(for: row, in: window, modelContext: modelContext) {
                result = .acted
            } else if AppOpenLog.didOpen(in: window) {
                result = .engaged
            } else {
                result = .ignored
            }

            row.result = result
            row.classifiedAt = now
        }
        try? modelContext.save()
        return rows.count
    }

    // MARK: - DEBUG seams
    //
    // Thin wrappers so `NudgeOutcomeClassifierHarness` (a separate file,
    // hence no access to the privates above) can drive the real logic.
    // Neither adds behaviour; production paths are unchanged.

    #if DEBUG
    /// Runs the real classification decision over exactly these rows.
    @discardableResult
    func debugResolve(
        _ rows: [NudgeOutcome],
        now: Date,
        modelContext: ModelContext
    ) -> Int {
        resolve(rows, now: now, modelContext: modelContext)
    }

    /// IDs of the rows a sweep at `now` would resolve.
    func debugSweepableIDs(now: Date, modelContext: ModelContext) -> Set<UUID> {
        Set(sweepableRows(now: now, modelContext: modelContext).map(\.id))
    }
    #endif

    // MARK: - "Did they do the thing?"

    /// Whether the user performed the action this nudge asked for inside
    /// the response window.
    private func performedAction(
        for row: NudgeOutcome,
        in window: ClosedRange<Date>,
        modelContext: ModelContext
    ) -> Bool {
        // A focus session started inside the window counts for every kind —
        // starting work IS the action every nudge except the morning prompt
        // asks for.
        //
        // CAVEAT, deliberate: the app group stores only the MOST RECENT
        // session start, so this can miss an older row whose session has
        // since been superseded. It can never produce a false positive, and
        // under-reporting `.acted` is the safe direction while we're only
        // observing. A session-start ring buffer alongside `AppOpenLog`
        // would close the gap if the numbers look too pessimistic.
        if let lastStart = SharedModelContainer.appGroupDefaults
            .object(forKey: NotificationScheduler.lastFocusSessionStartedAtKey) as? Date,
           window.contains(lastStart) {
            return true
        }

        let lower = window.lowerBound
        let upper = window.upperBound

        // The morning prompt asks the user to CAPTURE something ("what do
        // you want to get done today?"). Any task created inside the window
        // is the user answering it — whether they typed into Home chat or
        // added the task by hand.
        if row.kind == .morningPrompt {
            var createdDescriptor = FetchDescriptor<NudgeTask>(
                predicate: #Predicate<NudgeTask> {
                    $0.createdAt >= lower && $0.createdAt <= upper
                }
            )
            createdDescriptor.fetchLimit = 1
            return !((try? modelContext.fetch(createdDescriptor))?.isEmpty ?? true)
        }

        // Every other kind names a task; completing THAT task inside the
        // window is the action. `CompletedTaskRecord` is the canonical
        // completion log and survives deletion of the original NudgeTask.
        guard let taskID = row.taskID else { return false }
        var completedDescriptor = FetchDescriptor<CompletedTaskRecord>(
            predicate: #Predicate<CompletedTaskRecord> {
                $0.sourceTaskID == taskID
                    && $0.completedAt >= lower
                    && $0.completedAt <= upper
            }
        )
        completedDescriptor.fetchLimit = 1
        return !((try? modelContext.fetch(completedDescriptor))?.isEmpty ?? true)
    }

    // MARK: - Debug dump

    #if DEBUG
    /// Prints every outcome row from the last 7 days — kind, task title,
    /// scheduled time, result. Called on foreground right after the sweep
    /// so the console shows the classifications as they land.
    func debugDumpRecentOutcomes(modelContext: ModelContext) {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            ?? .distantPast
        var descriptor = FetchDescriptor<NudgeOutcome>(
            predicate: #Predicate<NudgeOutcome> { $0.scheduledFor >= since },
            sortBy: [SortDescriptor(\.scheduledFor, order: .reverse)]
        )
        descriptor.fetchLimit = 300
        let rows = (try? modelContext.fetch(descriptor)) ?? []

        print("[NudgeOutcomeDump] \(rows.count) outcome row(s) in the last 7 days")
        guard !rows.isEmpty else { return }

        // One fetch for the titles instead of one per row.
        let taskIDs = Set(rows.compactMap { $0.taskID })
        var titles: [UUID: String] = [:]
        if !taskIDs.isEmpty {
            let allTasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>())) ?? []
            for task in allTasks where taskIDs.contains(task.id) {
                titles[task.id] = task.title
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        // FEEDBACK is a separate column because it's a separate signal —
        // `result` is what the user DID (tapped, or inferred from behaviour),
        // `feedback` is what they SAID via the 👍/👎 notification actions.
        // A row carrying `ignored` + `helpful` is the interesting one: it
        // means the silence-means-failure inference was wrong for that nudge.
        print("  \(pad("RESULT", 14))\(pad("FEEDBACK", 12))\(pad("KIND", 15))\(pad("SCHEDULED", 14))TASK")
        for row in rows {
            let task = row.taskID.flatMap { titles[$0] } ?? "—"
            print("  "
                + pad(row.resultRaw, 14)
                + pad(feedbackLabel(row), 12)
                + pad(row.kindRaw, 15)
                + pad(fmt.string(from: row.scheduledFor), 14)
                + task)
        }

        // Counts by result — the number actually being watched here.
        let tally = Dictionary(grouping: rows, by: { $0.resultRaw })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
        print("  → \(tally)")

        // Same tally, split by KIND. The aggregate above answers "are nudges
        // working?"; this answers "WHICH nudges are working?", which is the
        // only form of the question you can act on — and the reason
        // `.floater` was split out of `.getAhead` (they were one kind, so
        // their rows summed into a single uninterpretable row here).
        //
        // Iterates `allCases` rather than the rows so a kind that produced
        // NOTHING in the window is visible as an absence instead of just
        // missing — "the floater check-in never fired" and "the floater
        // check-in fired and was ignored" are very different findings.
        print("  → by kind:")
        for kind in NudgeOutcomeKind.allCases {
            let ofKind = rows.filter { $0.kindRaw == kind.rawValue }
            guard !ofKind.isEmpty else {
                print("      \(pad(kind.rawValue, 15))—")
                continue
            }
            let kindTally = Dictionary(grouping: ofKind, by: { $0.resultRaw })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "  ")
            print("      \(pad(kind.rawValue, 15))\(pad("n=\(ofKind.count)", 7))\(kindTally)")
        }

        // Explicit feedback, tallied on its own. Rated rows are expected to
        // be a small minority, so folding them into the line above would
        // hide them; and their whole value is in being cross-referenced
        // against the inferred result rather than summed with it.
        let rated = rows.filter { $0.feedback != nil }
        if rated.isEmpty {
            print("  → feedback: none given yet")
        } else {
            let feedbackTally = Dictionary(grouping: rated, by: { $0.feedback?.rawValue ?? "—" })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "  ")
            // The cross-tab is the point: which inferred results the user
            // disagrees with.
            let crossTab = Dictionary(grouping: rated, by: {
                "\($0.resultRaw)+\($0.feedback?.rawValue ?? "—")"
            })
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "  ")
            print("  → feedback: \(feedbackTally)   (\(rated.count)/\(rows.count) rated)")
            print("  → inferred+stated: \(crossTab)")
        }
    }

    /// Short column label for the explicit rating, or "—" when the user
    /// never pressed a feedback button (the common case).
    private func feedbackLabel(_ row: NudgeOutcome) -> String {
        switch row.feedback {
        case .markedHelpful:   return "👍 helpful"
        case .markedUnhelpful: return "👎 useless"
        default:               return "—"
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? text.prefix(width - 1) + " "
            : text + String(repeating: " ", count: width - text.count)
    }
    #endif
}
