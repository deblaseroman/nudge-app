//
//  NudgeOutcomeClassifierHarness.swift
//  Nudge
//
//  DEBUG-only fixture runner for `NudgeOutcomeClassifier`. Seeds backdated
//  `NudgeOutcome` rows covering every branch the classifier distinguishes,
//  runs the REAL decision logic over them, prints expected-vs-actual, and
//  deletes everything it created.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────
//  The classifier only ever ran against nudges that had genuinely been
//  delivered hours earlier, so verifying a change to it meant scheduling a
//  notification, waiting out `outcomeClassificationGraceMinutes` (90) plus
//  the response window (60), and hoping you'd produced the right in-app
//  behaviour in between. That is a ~2.5 hour round trip per branch, which
//  is why the branches were never all exercised at once.
//
//  ── WHY IT DOESN'T CALL `classifyPending` ──────────────────────────────
//  Two of the three signals the classifier reads are GLOBAL, single-valued
//  shared state: the last focus-session start (one Date in App Group
//  defaults) and `AppOpenLog` (one array). The harness has to overwrite
//  both to produce its fixtures. A sweep would then judge the user's REAL
//  pending rows against that fake state and write the wrong result to
//  them — permanently, since a row leaves `pending` exactly once.
//
//  So the harness drives `debugResolve`, which is the same per-row decision
//  code `classifyPending` runs, restricted to rows the harness created. The
//  sweep's fetch predicate is covered separately via `debugSweepableIDs`.
//
//  ── WHAT IT RESTORES ───────────────────────────────────────────────────
//  Session-start key and `AppOpenLog` are snapshotted and restored in a
//  `defer`; seeded rows are deleted in the same place. A run that crashes
//  between seed and cleanup leaves orphans behind, so `run` also sweeps
//  orphans from a previous run before it starts.
//

#if DEBUG

import Foundation
import SwiftData

@MainActor
enum NudgeOutcomeClassifierHarness {

    /// Every seeded artifact is tagged with one of these so a crashed run
    /// can be cleaned up by the next one.
    private static let outcomePrefix = "nudge.debug.harness."
    private static let titlePrefix = "[harness]"

    // MARK: - Fixture

    private struct Fixture {
        let label: String
        let kind: NudgeOutcomeKind
        let fire: Date
        /// `nil` means "must NOT be swept" — the row is expected to stay
        /// pending because it's still inside the grace period.
        let expected: NudgeOutcomeResult?
        let taskID: UUID?
        var sessionStart: Date?     = nil
        var completion: Date?       = nil
        var appOpen: Date?          = nil
        var capturedTaskAt: Date?   = nil
        let why: String
    }

    // MARK: - Entry point

    static func run(modelContext: ModelContext) {
        let now = Date()
        let window = Double(NudgeConfig.outcomeActionWindowMinutes)
        let grace  = Double(NudgeConfig.outcomeClassificationGraceMinutes)

        print("")
        print("╔══════════════════════════════════════════════════════════════")
        print("║ NudgeOutcomeClassifier harness")
        print("║ window=\(Int(window))min  grace=\(Int(grace))min")
        print("╚══════════════════════════════════════════════════════════════")

        // Leftovers from a run that crashed before its `defer` fired.
        let orphans = deleteSeededArtifacts(modelContext: modelContext)
        if orphans > 0 {
            print("  (cleaned up \(orphans) orphaned artifact(s) from a previous run)")
        }

        // ── Slot geometry ────────────────────────────────────────────────
        // Fire times are spaced `window + 60` apart so no two response
        // windows overlap AND an "event just past the window" for slot i
        // still lands in the gap before slot i+1 opens. Derived from the
        // config rather than hardcoded, so retuning either constant
        // reshapes the fixtures instead of silently invalidating them.
        let step = window + 60
        let slotCount = 10
        // Newest slot must still clear the grace cutoff.
        let oldest = grace + 30 + (Double(slotCount) - 1) * step
        func slot(_ i: Int) -> Date {
            now.addingTimeInterval(-(oldest - Double(i) * step) * 60)
        }
        func mins(_ n: Double) -> TimeInterval { n * 60 }

        let f0 = slot(0), f1 = slot(1), f2 = slot(2), f3 = slot(3), f4 = slot(4)
        let f5 = slot(5), f6 = slot(6), f7 = slot(7), f8 = slot(8), f9 = slot(9)
        // Inside the grace period — a sweep must not touch it.
        let fRecent = now.addingTimeInterval(-mins(grace / 3))

        let fixtures: [Fixture] = [
            Fixture(
                label: "session started in window",
                kind: .getAhead,
                fire: f0,
                expected: .acted,
                taskID: UUID(),
                sessionStart: f0.addingTimeInterval(mins(window / 2)),
                why: "a focus session inside the window is the action every kind but morningPrompt asks for"
            ),
            Fixture(
                label: "task completed in window",
                kind: .floater,
                fire: f1,
                expected: .acted,
                taskID: UUID(),
                completion: f1.addingTimeInterval(mins(window / 3)),
                why: "CompletedTaskRecord for THIS row's taskID inside the window"
            ),
            Fixture(
                label: "app opened, nothing done",
                kind: .idle,
                fire: f2,
                expected: .engaged,
                taskID: UUID(),
                appOpen: f2.addingTimeInterval(mins(window / 4)),
                why: "the nudge landed and moved them, just not to the action"
            ),
            Fixture(
                label: "no activity at all",
                kind: .getAhead,
                fire: f3,
                expected: .ignored,
                taskID: UUID(),
                why: "no session, no completion, no app open"
            ),
            Fixture(
                label: "acted beats engaged",
                kind: .getAhead,
                fire: f4,
                expected: .acted,
                taskID: UUID(),
                completion: f4.addingTimeInterval(mins(window / 6)),
                appOpen: f4.addingTimeInterval(mins(window / 3)),
                why: "both signals present — precedence must pick .acted"
            ),
            Fixture(
                label: "morning prompt: captured",
                kind: .morningPrompt,
                fire: f5,
                expected: .acted,
                taskID: nil,
                capturedTaskAt: f5.addingTimeInterval(mins(window / 2)),
                why: "morningPrompt's action is ANY task created in the window, not a completion"
            ),
            Fixture(
                label: "morning prompt: nothing captured",
                kind: .morningPrompt,
                fire: f6,
                expected: .ignored,
                taskID: nil,
                why: "no task created in the window"
            ),
            Fixture(
                label: "eventBlock, nil taskID",
                kind: .eventBlock,
                fire: f7,
                expected: .ignored,
                taskID: nil,
                why: "no taskID to check — structurally cannot be .acted (see successIsObservableInApp)"
            ),
            Fixture(
                label: "completion exactly at window edge",
                kind: .getAhead,
                fire: f8,
                expected: .acted,
                taskID: UUID(),
                completion: f8.addingTimeInterval(mins(window)),
                why: "the response window is a CLOSED range — fire+window is inside it"
            ),
            Fixture(
                label: "completion + open just past window",
                kind: .getAhead,
                fire: f9,
                expected: .ignored,
                taskID: UUID(),
                completion: f9.addingTimeInterval(mins(window + 10)),
                appOpen: f9.addingTimeInterval(mins(window + 10)),
                why: "both signals exist but fall outside the window — must not count"
            ),
            Fixture(
                label: "inside grace period",
                kind: .idle,
                fire: fRecent,
                expected: nil,
                taskID: UUID(),
                why: "too recent — the sweep's predicate must leave it pending"
            )
        ]

        // ── Snapshot the global state the fixtures have to overwrite ─────
        let defaults = SharedModelContainer.appGroupDefaults
        let sessionKey = NotificationScheduler.lastFocusSessionStartedAtKey
        let savedSessionStart = defaults.object(forKey: sessionKey) as? Date
        let savedOpenLog = AppOpenLog.timestamps()

        var seededOutcomes: [NudgeOutcome] = []

        defer {
            // Restore shared state first — if row deletion throws, the
            // user's real session/open history still comes back.
            if let savedSessionStart {
                defaults.set(savedSessionStart, forKey: sessionKey)
            } else {
                defaults.removeObject(forKey: sessionKey)
            }
            AppOpenLog.debugReplaceAll(with: savedOpenLog)

            let removed = deleteSeededArtifacts(modelContext: modelContext)
            print("  cleanup: removed \(removed) seeded artifact(s); "
                + "session-start key and AppOpenLog restored")
            print("")
        }

        // ── Seed ─────────────────────────────────────────────────────────
        // Only ONE session start can exist (the app group stores a single
        // Date), which is why exactly one fixture uses that signal.
        var injectedOpens: [Date] = []
        for fixture in fixtures {
            let outcome = NudgeOutcome(
                kind: fixture.kind,
                notificationID: outcomePrefix + UUID().uuidString,
                taskID: fixture.taskID,
                scheduledFor: fixture.fire
            )
            modelContext.insert(outcome)
            seededOutcomes.append(outcome)

            if let start = fixture.sessionStart {
                defaults.set(start, forKey: sessionKey)
            }
            if let open = fixture.appOpen {
                injectedOpens.append(open)
            }
            if let completedAt = fixture.completion, let taskID = fixture.taskID {
                modelContext.insert(CompletedTaskRecord(
                    title: "\(titlePrefix) \(fixture.label)",
                    completedAt: completedAt,
                    sourceTaskID: taskID
                ))
            }
            if let createdAt = fixture.capturedTaskAt {
                modelContext.insert(NudgeTask(
                    title: "\(titlePrefix) capture proof",
                    createdAt: createdAt
                ))
            }
        }
        // Replace wholesale rather than appending: a real open sitting
        // inside a fixture's window would turn an expected .ignored into
        // .engaged and read as a classifier bug.
        AppOpenLog.debugReplaceAll(with: injectedOpens)
        try? modelContext.save()

        // ── Check the sweep predicate, then run the real decision ────────
        let sweepable = NudgeOutcomeClassifier.shared
            .debugSweepableIDs(now: now, modelContext: modelContext)

        let toResolve = zip(fixtures, seededOutcomes)
            .filter { $0.0.expected != nil }
            .map(\.1)
        NudgeOutcomeClassifier.shared
            .debugResolve(toResolve, now: now, modelContext: modelContext)

        // ── Report ───────────────────────────────────────────────────────
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        print("  \(pad("", 5))\(pad("KIND", 15))\(pad("EXPECTED", 10))\(pad("ACTUAL", 10))\(pad("FIRED", 7))CASE")
        var passed = 0
        var failed = 0

        for (fixture, row) in zip(fixtures, seededOutcomes) {
            let actual: String
            let ok: Bool
            if let expected = fixture.expected {
                // A row that should have been resolved must also have been
                // in the sweep's fetch — otherwise the real classifier
                // would never reach it, however right the decision is.
                let wouldSweep = sweepable.contains(row.id)
                actual = wouldSweep ? row.resultRaw : "\(row.resultRaw) (NOT SWEPT)"
                ok = wouldSweep && row.result == expected
            } else {
                actual = sweepable.contains(row.id) ? "\(row.resultRaw) (SWEPT)" : row.resultRaw
                ok = !sweepable.contains(row.id) && row.result == .pending
            }
            if ok { passed += 1 } else { failed += 1 }

            print("  \(pad(ok ? "PASS" : "FAIL", 5))"
                + pad(fixture.kind.rawValue, 15)
                + pad(fixture.expected?.rawValue ?? "pending", 10)
                + pad(actual, 10)
                + pad(fmt.string(from: fixture.fire), 7)
                + fixture.label)
            if !ok {
                print("       ↳ expected because: \(fixture.why)")
            }
        }

        print("  → \(passed) passed, \(failed) failed, \(fixtures.count) total")

        // ── Interference the harness cannot rule out ─────────────────────
        // The morningPrompt branch matches ANY NudgeTask created in the
        // window, so a real task the user captured at that hour on a
        // previous day is indistinguishable from the fixture's own. Report
        // it rather than let it silently flip a verdict.
        for fixture in fixtures where fixture.kind == .morningPrompt {
            let lower = fixture.fire
            let upper = fixture.fire.addingTimeInterval(mins(window))
            var descriptor = FetchDescriptor<NudgeTask>(
                predicate: #Predicate<NudgeTask> {
                    $0.createdAt >= lower && $0.createdAt <= upper
                }
            )
            descriptor.fetchLimit = 20
            let inWindow = (try? modelContext.fetch(descriptor)) ?? []
            let real = inWindow.filter { !$0.title.hasPrefix(titlePrefix) }
            if !real.isEmpty {
                print("  ⚠︎ INCONCLUSIVE — \"\(fixture.label)\": \(real.count) REAL task(s) "
                    + "were created inside this fixture's window "
                    + "(\(real.map(\.title).prefix(3).joined(separator: ", "))). "
                    + "The morningPrompt branch can't tell them from the fixture's.")
            }
        }
    }

    // MARK: - Cleanup

    /// Deletes every artifact tagged as harness-seeded. Returns the count.
    @discardableResult
    private static func deleteSeededArtifacts(modelContext: ModelContext) -> Int {
        var removed = 0

        var outcomes = FetchDescriptor<NudgeOutcome>()
        outcomes.fetchLimit = 500
        for row in (try? modelContext.fetch(outcomes)) ?? []
        where row.notificationID.hasPrefix(outcomePrefix) {
            modelContext.delete(row)
            removed += 1
        }

        // Bounded by date as well as count — these two tables are the
        // user's real history and the harness only ever writes into the
        // last day of it.
        let cutoff = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        var completions = FetchDescriptor<CompletedTaskRecord>(
            predicate: #Predicate<CompletedTaskRecord> { $0.completedAt >= cutoff }
        )
        completions.fetchLimit = 500
        for record in (try? modelContext.fetch(completions)) ?? []
        where record.title.hasPrefix(titlePrefix) {
            modelContext.delete(record)
            removed += 1
        }

        var tasks = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.createdAt >= cutoff }
        )
        tasks.fetchLimit = 500
        for task in (try? modelContext.fetch(tasks)) ?? []
        where task.title.hasPrefix(titlePrefix) {
            modelContext.delete(task)
            removed += 1
        }

        if removed > 0 { try? modelContext.save() }
        return removed
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? String(text.prefix(width - 1)) + " "
            : text + String(repeating: " ", count: width - text.count)
    }
}

#endif
