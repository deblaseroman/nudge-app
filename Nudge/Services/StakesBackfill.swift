//
//  StakesBackfill.swift
//  Nudge
//
//  One-shot pass that repairs the `stakes` consequence signal on rows that
//  predate it or got it from the wrong classifier. Two populations:
//
//    1. `stakesRaw == nil` — never classified. Rows created before the
//       field existed, plus captures where the model omitted it.
//    2. `source == "calendar"` — stamped by `CalendarService.inferStakes`,
//       which is deliberately deterministic (imports must work offline)
//       and therefore systematically weak outside school: its category
//       ladder sends anything that isn't exam/work/school/health to "low",
//       so a flight, a visa deadline, or a specialist appointment imported
//       as "personal"/"errand" reads as low stakes.
//
//  Both populations exclude completed rows: stakes has no consumer on a
//  finished task, and on a long history they are most of the table and so
//  most of the token spend.
//
//  Rows with `stakesIsUserSet` are never touched. Every write goes through
//  `NudgeTask.setStakesFromAutomation`, which refuses them again — belt and
//  braces, because unlike the import writers this pass overwrites values
//  that already exist.
//
//  Two properties worth knowing before changing anything here:
//
//  • It is ATOMIC. Every title is classified first; a failure anywhere —
//    no API key, offline, a 429 that survives its retry, mangled JSON, or
//    a response that doesn't cover every title sent — abandons the pass
//    having written nothing at all. Stakes enhances data that already
//    works without it, so a failure must cost the user nothing and leave
//    no half-upgraded state to reason about.
//
//  • It is DEDUPED, not per-row. Titles normalize through
//    `EventDurationStats.normalize` and group, so a semester of "BIO 101
//    Lecture" costs one classification instead of forty. A 100-row import
//    typically collapses to ~15 titles = one request.
//
//  Scope boundary: this fixes rows that already exist. Calendar events
//  imported AFTER a successful pass still get the deterministic
//  `inferStakes` value — routing new imports through the AI classifier is
//  separate work, not a backfill.
//

import Foundation
import SwiftData

@MainActor
final class StakesBackfill {

    static let shared = StakesBackfill()

    // MARK: - Stage switch

    enum Mode {
        /// Classify, print the table, write NOTHING — not the rows, not the
        /// completion marker. Repeatable as often as you like, by design:
        /// the point is to eyeball the proposed values before committing.
        case dryRun

        /// Classify and write, then record the version as complete so the
        /// pass doesn't run again.
        case apply
    }

    /// STAGE SWITCH. `.dryRun` prints the proposed table to the Xcode
    /// console and changes nothing; flip to `.apply` once the table looks
    /// right. This is the only line that needs to change between stages.
    static let mode: Mode = .apply

    /// Bump to re-run `.apply` on devices that already completed the
    /// previous version (e.g. after improving the classifier prompt).
    /// Bookkeeping rather than a tunable, so it lives here and not in
    /// `NudgeConfig` — same reasoning as `NotificationScheduler`'s own key.
    private static let version = 1
    private static let completedVersionKey = "nudge.stakesBackfill.completedVersion"

    /// Guards against a second launch trigger firing while the first pass
    /// is still awaiting the network.
    private var isRunning = false

    private init() {}

    // MARK: - Entry point

    /// Fire-and-forget launch hook. Returns immediately; everything past
    /// the first suspension point runs off the launch path at background
    /// priority, and the only main-thread work is one fetch and (in
    /// `.apply`) the writes. Safe to call on every launch.
    func runIfNeeded() {
        Task(priority: .utility) {
            await self.run(mode: Self.mode)
        }
    }

    /// The pass. Never throws and never surfaces anything to the user —
    /// see the atomicity note in the file header.
    func run(mode: Mode) async {
        #if !DEBUG
        // The dry run's only output channel is the Xcode console, so in a
        // release build it would spend tokens to print into the void.
        if mode == .dryRun { return }
        #endif

        guard !isRunning else { return }
        if mode == .apply, isVersionComplete { return }

        isRunning = true
        defer { isRunning = false }

        let context = SharedModelContainer.container.mainContext
        let candidates = affectedRows(in: context)
        let groups = groupByNormalizedTitle(candidates)

        guard !groups.isEmpty else {
            log("no rows need stakes — nothing to do")
            if mode == .apply { markVersionComplete() }
            return
        }

        let titles = groups.keys.sorted()
        let covered = groups.values.reduce(0) { $0 + $1.count }
        if covered < candidates.count {
            log("\(candidates.count - covered) row(s) skipped — title normalizes to empty")
        }
        log("\(covered) candidate row(s) → \(titles.count) unique title(s) → classifying…")

        // Nil = something failed; it has already been logged, and nothing
        // has been written. Bail without touching the completion marker so
        // a later launch retries.
        guard let classified = await classify(titles) else { return }

        switch mode {
        case .dryRun:
            printDryRunTable(groups: groups, classified: classified)
        case .apply:
            let written = applyClassifications(
                groups: groups,
                classified: classified,
                context: context
            )
            markVersionComplete()
            log("APPLIED — \(written) row(s) written")
        }
    }

    // MARK: - Row selection

    /// The two populations, minus anything the user owns and anything
    /// already done.
    ///
    /// Completed rows are excluded because stakes has no consumer on a
    /// finished task — nothing scores, ranks, or renders it — while on a
    /// long history they are the bulk of the rows and therefore the bulk
    /// of the token spend.
    ///
    /// Filtered in Swift rather than through a `#Predicate`: the condition
    /// is an OR across a newly-added optional attribute, which is exactly
    /// the shape that behaves inconsistently in SwiftData predicates, and
    /// this runs once over a table the app already materializes in full
    /// elsewhere.
    private func affectedRows(in context: ModelContext) -> [NudgeTask] {
        let all = (try? context.fetch(FetchDescriptor<NudgeTask>())) ?? []
        return all.filter { task in
            guard !task.stakesIsUserSet, !task.isComplete else { return false }
            return task.stakesRaw == nil || task.source == "calendar"
        }
    }

    /// Normalized title → the rows carrying it.
    ///
    /// `EventDurationStats.normalize` is the app's existing title-identity
    /// function (lowercase, strip punctuation, collapse whitespace), so
    /// "CS 101!" and "cs 101" resolve to one classification.
    ///
    /// Rows whose title normalizes to empty (punctuation or emoji only) are
    /// dropped: there is nothing to classify, and an empty key would pool
    /// unrelated rows under a single answer.
    private func groupByNormalizedTitle(_ rows: [NudgeTask]) -> [String: [NudgeTask]] {
        var groups: [String: [NudgeTask]] = [:]
        for row in rows {
            let key = EventDurationStats.normalize(row.title)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(row)
        }
        return groups
    }

    // MARK: - Classification

    /// Classifies every unique title, chunked. Returns nil — never a
    /// partial map — if ANY chunk fails, so the caller writes all or
    /// nothing.
    private func classify(_ titles: [String]) async -> [String: TaskStakes]? {
        var classified: [String: TaskStakes] = [:]

        for (offset, chunk) in titles.chunked(into: NudgeConfig.stakesBackfillChunkSize).enumerated() {
            if offset > 0 {
                try? await Task.sleep(
                    for: .seconds(NudgeConfig.stakesBackfillInterChunkDelaySeconds)
                )
            }
            guard let result = await classifyChunk(chunk) else { return nil }
            classified.merge(result) { _, new in new }
        }

        return classified
    }

    /// One request, with a single backoff retry on a 429. Every other error
    /// fails the chunk immediately — a missing key, no network, a bad key,
    /// or an unparseable response are all things a retry cannot fix.
    private func classifyChunk(_ chunk: [String]) async -> [String: TaskStakes]? {
        do {
            return try await ClaudeService.shared.classifyStakes(titles: chunk)
        } catch ClaudeError.rateLimitExceeded {
            log("rate limited — backing off \(NudgeConfig.stakesBackfillRateLimitBackoffSeconds)s")
            try? await Task.sleep(
                for: .seconds(NudgeConfig.stakesBackfillRateLimitBackoffSeconds)
            )
            do {
                return try await ClaudeService.shared.classifyStakes(titles: chunk)
            } catch {
                log("still failing after backoff — abandoning pass (\(error))")
                return nil
            }
        } catch {
            log("classification failed — abandoning pass (\(error))")
            return nil
        }
    }

    // MARK: - Apply

    /// Writes the classifications back to every row under each title.
    /// Returns the number of rows that actually changed.
    ///
    /// The count is taken by comparing `stakesRaw` across the call rather
    /// than by predicting the outcome, so it stays honest no matter which
    /// guard fires — a row the user hand-set mid-pass is refused by
    /// `setStakesFromAutomation` and correctly counts as unchanged.
    private func applyClassifications(
        groups: [String: [NudgeTask]],
        classified: [String: TaskStakes],
        context: ModelContext
    ) -> Int {
        var written = 0

        for (key, rows) in groups {
            guard let proposed = classified[key] else { continue }
            for row in rows {
                // The classification round-trip is a network call long;
                // the user may have deleted a row in the meantime.
                guard !row.isDeleted else { continue }
                let before = row.stakesRaw
                row.setStakesFromAutomation(proposed)
                if row.stakesRaw != before { written += 1 }
            }
        }

        if written > 0 { try? context.save() }
        return written
    }

    // MARK: - Completion marker

    private var isVersionComplete: Bool {
        SharedModelContainer.appGroupDefaults
            .integer(forKey: Self.completedVersionKey) >= Self.version
    }

    private func markVersionComplete() {
        SharedModelContainer.appGroupDefaults
            .set(Self.version, forKey: Self.completedVersionKey)
    }

    // MARK: - Dry-run reporting

    /// Prints one line per affected ROW (not per unique title) so the whole
    /// blast radius is visible, grouped by normalized title so the dedupe
    /// is visible too.
    private func printDryRunTable(
        groups: [String: [NudgeTask]],
        classified: [String: TaskStakes]
    ) {
        #if DEBUG
        var wouldWrite = 0
        var alreadyCorrect = 0
        var unclassified = 0
        var lines: [String] = []

        for key in groups.keys.sorted() {
            let rows = (groups[key] ?? []).sorted { $0.title < $1.title }
            let proposed = classified[key]

            for row in rows {
                let current = row.stakes
                let result: String
                switch (current, proposed) {
                case (_, nil):
                    result = "unclassified — left as-is"
                    unclassified += 1
                case (nil, _):
                    result = "SET"
                    wouldWrite += 1
                case let (existing?, new?) where existing != new:
                    result = "CHANGE"
                    wouldWrite += 1
                default:
                    result = "same"
                    alreadyCorrect += 1
                }

                lines.append(
                    padded(row.title, 42)
                        + padded(row.source, 12)
                        + padded(current?.rawValue ?? "—", 10)
                        + padded(proposed?.rawValue ?? "—", 10)
                        + result
                )
            }
        }

        let rule = String(repeating: "─", count: 96)
        print("""

        [StakesBackfill] DRY RUN — nothing will be written.
        \(rule)
        \(padded("TITLE", 42))\(padded("SOURCE", 12))\(padded("CURRENT", 10))\(padded("PROPOSED", 10))RESULT
        \(rule)
        \(lines.joined(separator: "\n"))
        \(rule)
        [StakesBackfill] \(lines.count) affected row(s) across \(groups.count) unique title(s)
        [StakesBackfill] would write \(wouldWrite) · \(alreadyCorrect) already correct · \(unclassified) unclassified
        [StakesBackfill] set StakesBackfill.mode = .apply to commit.

        """)
        #endif
    }

    /// Character-count based padding/truncation. `String.padding(toLength:)`
    /// counts UTF-16 units and misaligns on emoji, which task titles have
    /// plenty of.
    private func padded(_ text: String, _ width: Int) -> String {
        let fitted = text.count > width - 1
            ? String(text.prefix(width - 2)) + "…"
            : text
        return fitted + String(repeating: " ", count: max(1, width - fitted.count))
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[StakesBackfill] \(message)")
        #endif
    }
}

// MARK: - Chunking

private extension Array {
    /// Splits into consecutive slices of at most `size`. Used to bound
    /// request size; `size` is always positive here (`NudgeConfig`), but
    /// the guard keeps a bad edit from producing an infinite stride.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
