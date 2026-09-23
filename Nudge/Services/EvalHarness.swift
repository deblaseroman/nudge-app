//
//  EvalHarness.swift
//  Nudge
//
//  DEBUG-only eval runner behind `eval/run.sh`. Launched with
//  `-nudge-eval <path to eval/cases.json>` (plus `-nudge-eval-local-only`
//  to skip the API-backed capture cases), it runs every case against the
//  real code on an isolated in-memory store, prints one `EVAL ` line per
//  failing case and one summary line, and the launch hook exits the
//  process. It changes nothing: no app store, no prompt, no arbiter rule.
//
//  What each kind exercises (the same entry points the app uses):
//    capture  → `HomeTabView.isPlanIntent` / `ChatRouter.isSmallTalk` (the
//               routers the Home chat runs first), `ClaudeService.sendChat` (the brain
//               dump's only API entry point), `CaptureWriter.apply` (the
//               write site), `NudgeIntelligence.refreshIfNeeded` per new row
//               (counted: one API call per new task is the invariant),
//               `ExamPrepSweep.run`, `NudgeArbiter.reevaluate`.
//    arbiter  → rows built from the case, optional `PlacementRollover.sweep`,
//               `NudgeArbiter.reevaluate`.
//  Then both read the same fields: `NudgeTask` helpers, `CountdownState`
//  (the Tasks-row line), and the arbiter's raw candidate list by kind.
//
//  The case format is documented in `eval/README.md`.
//

#if DEBUG
import Foundation
import SwiftData

@MainActor
enum EvalHarness {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-nudge-eval")
    }

    static func runFromLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-nudge-eval"), i + 1 < args.count else {
            emit("ERROR -nudge-eval needs a path to the case file")
            return
        }
        // `-nudge-eval-fill`: after each capture case, record what the app
        // did as that case's `expected` and write every case back to
        // `<cases>.filled.json` (`eval/run.sh --fill`). For drafting cases
        // from today's behavior; the input file is never modified.
        fillOutput = args.contains("-nudge-eval-fill")
            ? URL(fileURLWithPath: args[i + 1].replacingOccurrences(of: ".json", with: "") + ".filled.json")
            : nil
        await run(casesPath: args[i + 1], localOnly: args.contains("-nudge-eval-local-only"))
    }

    private static var fillOutput: URL?
    private static var filledCases: [[String: Any]] = []
    /// Every case's in-memory store, kept alive until the run ends: the
    /// arbiter's copy generator (`NudgeCopyGenerator.noteShift`) fetches on
    /// a background task after `reevaluate` returns, and a store released
    /// under it traps inside SwiftData (crash seen Sep 23 2026 on a
    /// 25-row capture). The app never releases its container, so this is
    /// the harness matching the app's lifetime, not a behavior change.
    private static var liveFixtures: [Fixture] = []

    // MARK: - Driver

    private struct Outcome {
        let id: String
        let kind: String
        let passed: Bool
        let unverified: Bool
        let line: String?
    }

    /// Capture-call token totals for the one CACHE line after the summary:
    /// the only place a cache regression is visible without the log.
    private static var captureCalls = 0
    private static var captureUncachedIn = 0
    private static var captureCacheRead = 0
    private static var captureCacheCreation = 0
    private static var intelCalls = 0
    private static var intelRows = 0
    private static var intelSeededAsks = 0
    private static var intelSeededCalls = 0

    static func run(casesPath: String, localOnly: Bool) async {
        let cases: [[String: Any]]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: casesPath))
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                emit("ERROR \(casesPath) is not a flat JSON list of cases")
                return
            }
            cases = list
        } catch {
            emit("ERROR could not read \(casesPath): \(error)")
            return
        }

        var outcomes: [Outcome] = []
        filledCases = []
        liveFixtures = []
        intelCalls = 0
        intelRows = 0
        intelSeededAsks = 0
        intelSeededCalls = 0
        for c in cases {
            let id = (c["id"] as? String) ?? "<no id>"
            let kind = (c["kind"] as? String) ?? "<no kind>"
            let unverified = (c["unverified"] as? Bool) ?? false
            if kind == "capture", localOnly { continue }
            // A seeded-row intelligence case without a stored hash makes
            // one real signal call, so it sits with the paid half.
            if kind == "arbiter", localOnly,
               let intel = (c["input"] as? [String: Any])?["intelligence"] as? [String: Any],
               (intel["seedHash"] as? Bool) != true { continue }
            let failure: String?
            switch kind {
            case "arbiter":
                failure = await runArbiterCase(c)
            case "capture":
                failure = await runCaptureCase(c)
            default:
                failure = "input: ? | expected: kind is \"capture\" or \"arbiter\" | actual: kind=\"\(kind)\""
            }
            outcomes.append(Outcome(id: id, kind: kind, passed: failure == nil, unverified: unverified, line: failure))
        }

        for o in outcomes where !o.passed {
            emit("FAIL \(o.id) | \(o.line ?? "")" + (o.unverified ? " | unverified expectation" : ""))
        }
        let arb = outcomes.filter { $0.kind == "arbiter" }
        let cap = outcomes.filter { $0.kind == "capture" }
        let arbPassed = arb.filter(\.passed).count
        let capPassed = cap.filter(\.passed).count
        let capText: String
        if localOnly {
            capText = "capture skipped (--local-only)"
        } else if cap.isEmpty {
            capText = "capture 0/0 passed (no capture cases)"
        } else {
            let pct = Int((Double(capPassed) / Double(cap.count) * 100).rounded())
            capText = "capture \(capPassed)/\(cap.count) passed (\(pct)%)"
        }
        emit("SUMMARY arbiter \(arbPassed)/\(arb.count) passed, \(capText)")
        if captureCalls > 0 {
            emit("CACHE capture calls \(captureCalls): cache_read=\(captureCacheRead) cache_creation=\(captureCacheCreation) uncached_in=\(captureUncachedIn)")
        }
        if intelRows > 0 || intelSeededAsks > 0 {
            emit("INTEL per-task signal calls \(intelCalls) for \(intelRows) new row(s); \(intelSeededCalls) call(s) for \(intelSeededAsks) refresh ask(s) on existing rows")
        }
        if let fillOutput {
            do {
                let data = try JSONSerialization.data(withJSONObject: filledCases, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: fillOutput)
                emit("FILLED \(filledCases.count) case(s) → \(fillOutput.path)")
            } catch {
                emit("ERROR could not write \(fillOutput.path): \(error)")
            }
        }
    }

    private static func emit(_ line: String) {
        print("EVAL \(line)")
    }

    // MARK: - Isolated store

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let profile: UserProfile
    }

    private static func makeFixture() throws -> Fixture {
        let config = ModelConfiguration(schema: SharedModelContainer.schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SharedModelContainer.schema, configurations: config)
        let context = container.mainContext
        let profile = UserProfile(name: "Eval", onboardingComplete: true)
        context.insert(profile)
        try context.save()
        let fixture = Fixture(container: container, context: context, profile: profile)
        liveFixtures.append(fixture)
        return fixture
    }

    private static func reevaluate(_ f: Fixture) -> NudgeArbiter.DebugRunSnapshot? {
        NudgeArbiter.shared.reevaluate(reason: .taskCreatedOrEdited, profile: f.profile, modelContext: f.context)
        return (NudgeArbiter.shared as? NudgeArbiter)?.lastRunSnapshot
    }

    // MARK: - Arbiter cases

    /// Returns nil on pass, else the failure line body.
    private static func runArbiterCase(_ c: [String: Any]) async -> String? {
        let input = (c["input"] as? [String: Any]) ?? [:]
        let expected = (c["expected"] as? [String: Any]) ?? [:]
        let inputSummary = describeArbiterInput(input)
        let fixture: Fixture
        do { fixture = try makeFixture() } catch {
            return "input: \(inputSummary) | expected: a store | actual: error: \(error)"
        }
        let specs = (input["tasks"] as? [[String: Any]]) ?? []
        do {
            for spec in specs { try insertTask(spec, into: fixture.context) }
            try fixture.context.save()
        } catch {
            return "input: \(inputSummary) | expected: rows inserted | actual: error: \(error)"
        }
        if (input["rolloverSweep"] as? Bool) == true {
            _ = PlacementRollover.sweep(modelContext: fixture.context)
        }
        // `intelligence`: seed a TaskIntelligence row per task (fresh; with
        // the current hash when seedHash is true, none otherwise), then ask
        // for a refresh twice with nothing changed and record which asks
        // made a call. The update path of the upsert is what this covers;
        // capture cases only ever insert.
        var intelResults: [String: [Bool]] = [:]
        if let intel = input["intelligence"] as? [String: Any] {
            let rowsNow = (try? fixture.context.fetch(FetchDescriptor<NudgeTask>())) ?? []
            for task in rowsNow {
                if (intel["seedRow"] as? Bool) ?? true {
                    let seeded = TaskIntelligence(taskID: task.id, suggestedFirstStep: "Seeded by the harness.", analyzedAt: Date())
                    if (intel["seedHash"] as? Bool) == true {
                        seeded.inputHash = NudgeIntelligence.currentInputHash(for: task)
                    }
                    fixture.context.insert(seeded)
                    try? fixture.context.save()
                }
                var made: [Bool] = []
                for _ in 0..<((intel["asks"] as? Int) ?? 2) {
                    made.append(await NudgeIntelligence.shared.refreshIfNeeded(task: task, in: fixture.container))
                }
                intelResults[task.title] = made
                intelSeededAsks += made.count
                intelSeededCalls += made.filter { $0 }.count
            }
        }
        let snapshot = reevaluate(fixture)
        let rows = (try? fixture.context.fetch(FetchDescriptor<NudgeTask>())) ?? []

        var mismatches: [String] = []
        for spec in (expected["tasks"] as? [[String: Any]]) ?? [] {
            guard let title = spec["title"] as? String else {
                mismatches.append("expected row without a title"); continue
            }
            guard let row = rows.first(where: { $0.title == title }) else {
                mismatches.append("\(title): no such row (rows: \(rows.map(\.title).joined(separator: ", ")))")
                continue
            }
            var fields = spec
            if let want = spec["intelligenceCalls"] as? [Int] {
                fields.removeValue(forKey: "intelligenceCalls")
                let have = (intelResults[title] ?? []).map { $0 ? 1 : 0 }
                if have != want { mismatches.append("\(title) intelligenceCalls: expected \(want), actual \(have)") }
            }
            mismatches.append(contentsOf: compare(fields, against: row, snapshot: snapshot, label: title))
        }
        if let count = expected["rowCount"] as? Int, rows.count != count {
            mismatches.append("rowCount: expected \(count), actual \(rows.count)")
        }
        return failureLine(input: inputSummary, mismatches: mismatches)
    }

    private static func describeArbiterInput(_ input: [String: Any]) -> String {
        let specs = (input["tasks"] as? [[String: Any]]) ?? []
        let parts = specs.map { spec -> String in
            var bits: [String] = []
            for key in ["isEvent", "dueDate", "specificTime", "intendedDate", "plannedStartDate", "estimatedMinutes", "source", "sequenceIndex", "skipCount", "isComplete"] {
                if let v = spec[key] { bits.append("\(key)=\(v)") }
            }
            return "\"\((spec["title"] as? String) ?? "?")\"" + (bits.isEmpty ? "" : " {\(bits.joined(separator: ", "))}")
        }
        var s = parts.joined(separator: "; ")
        if (input["rolloverSweep"] as? Bool) == true { s += " + rolloverSweep" }
        return s
    }

    private static func insertTask(_ spec: [String: Any], into context: ModelContext) throws {
        guard let title = spec["title"] as? String else { throw HarnessError.bad("task without a title") }
        let isEvent = (spec["isEvent"] as? Bool) ?? false
        let specificTime = try spec["specificTime"].flatMap { try resolve($0, defaultHour: nil, defaultMinute: nil, field: "specificTime") }
        var dueDate = try spec["dueDate"].flatMap { try resolve($0, defaultHour: 23, defaultMinute: 59, field: "dueDate") }
        if dueDate == nil, let specificTime {
            // The app stores a clock-timed deadline or event as its day's
            // 23:59 dueDate plus the clock in specificTime; mirror that.
            dueDate = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: specificTime)
        }
        let planned = try spec["plannedStartDate"].flatMap { try resolve($0, defaultHour: nil, defaultMinute: nil, field: "plannedStartDate") }
        let created = try spec["createdAt"].flatMap { try resolve($0, defaultHour: nil, defaultMinute: nil, field: "createdAt") } ?? Date()
        let task = NudgeTask(
            title: title,
            dueDate: dueDate,
            dueTime: specificTime.map { clock($0) },
            specificTime: specificTime,
            priority: (spec["priority"] as? String) ?? "medium",
            category: spec["category"] as? String,
            isComplete: (spec["isComplete"] as? Bool) ?? false,
            createdAt: created,
            source: (spec["source"] as? String) ?? "capture",
            estimatedMinutes: spec["estimatedMinutes"] as? Int,
            isInformationalEvent: isEvent,
            plannedStartDate: planned,
            plannedDurationMinutes: spec["plannedDurationMinutes"] as? Int,
            plannedIsAuto: (spec["plannedIsAuto"] as? Bool) ?? false,
            sequenceIndex: spec["sequenceIndex"] as? Int
        )
        if let intent = spec["intendedDate"] {
            task.intendedDate = try resolve(intent, defaultHour: 0, defaultMinute: 0, field: "intendedDate")
                .map { Calendar.current.startOfDay(for: $0) }
        }
        if let skips = spec["skipCount"] as? Int { task.skipCount = skips }
        if let stakes = spec["stakes"] as? String { task.setStakesFromAutomation(TaskStakes.parse(stakes)) }
        context.insert(task)
    }

    // MARK: - Capture cases

    private static func runCaptureCase(_ c: [String: Any]) async -> String? {
        let input = (c["input"] as? [String: Any]) ?? [:]
        let expected = (c["expected"] as? [String: Any]) ?? [:]
        guard let text = input["text"] as? String else {
            return "input: ? | expected: input.text | actual: missing"
        }
        let inputSummary = "\"\(text)\""
        let fixture: Fixture
        do { fixture = try makeFixture() } catch {
            return "input: \(inputSummary) | expected: a store | actual: error: \(error)"
        }

        // The Home chat's routers, in the order the app runs them. The
        // harness reports the route and stops there for the non-capture
        // lanes (their API calls produce a chat reply, never a row).
        let routedTo: String
        if HomeTabView.isPlanIntent(text) {
            routedTo = "plan"
        } else if ChatRouter.isSmallTalk(text) {
            routedTo = "smallTalk"
        } else {
            routedTo = "capture"
        }

        var created: [NudgeTask] = []
        var returned: Int = 0
        var snapshot: NudgeArbiter.DebugRunSnapshot?
        // "template" when the reply is one of ChatRouter's lines (chitchat,
        // or a capture that found nothing), "model" when the model's own
        // message is shown, "plan" for the planner lane.
        var replyKind = routedTo == "smallTalk" ? "template" : (routedTo == "plan" ? "plan" : "model")
        var caseIntelCalls = 0
        if routedTo == "capture" {
            do {
                let response = try await ClaudeService.shared.sendChat(
                    conversationHistory: [],
                    userMessage: text,
                    existingTasks: [],
                    knownCommitmentSizes: [],
                    activeGoals: []
                )
                returned = response.tasks.count
                if ChatRouter.isEmptyCapture(response, questionOutstanding: false) { replyKind = "template" }
                captureCalls += 1
                captureUncachedIn += response.usage?.inputTokens ?? 0
                captureCacheRead += response.usage?.cacheReadInputTokens ?? 0
                captureCacheCreation += response.usage?.cacheCreationInputTokens ?? 0
                let written = CaptureWriter.apply(
                    response: response,
                    allTasks: [],
                    goalContexts: [],
                    modelContext: fixture.context,
                    userMessage: text,
                    writeLog: false
                )
                created = written.created
                try fixture.context.save()
                // The app's post-capture enrichment, on the fixture's own
                // store: one API call per new row, none for a cache hit.
                for row in created {
                    if await NudgeIntelligence.shared.refreshIfNeeded(task: row, in: fixture.container) {
                        caseIntelCalls += 1
                    }
                }
                intelCalls += caseIntelCalls
                intelRows += created.count
                _ = ExamPrepSweep.shared.run(modelContext: fixture.context)
                snapshot = reevaluate(fixture)
            } catch {
                return "input: \(inputSummary) | expected: a capture | actual: error: \(error)"
            }
        }

        var mismatches: [String] = []
        let expectedRoute = (expected["routedTo"] as? String) ?? "capture"
        if routedTo != expectedRoute {
            mismatches.append("routedTo: expected \(expectedRoute), actual \(routedTo)")
        }
        if let want = expected["replyKind"] as? String, want != replyKind {
            mismatches.append("replyKind: expected \(want), actual \(replyKind)")
        }
        // One signal call per new row is the invariant; a case may override.
        let wantIntel = (expected["intelligenceCalls"] as? Int) ?? created.count
        if caseIntelCalls != wantIntel {
            mismatches.append("intelligenceCalls: expected \(wantIntel), actual \(caseIntelCalls)")
        }
        if let count = expected["rowCount"] as? Int, created.count != count {
            mismatches.append("rowCount: expected \(count), actual \(created.count) (model returned \(returned))")
        }
        if fillOutput != nil {
            var filled = c
            var fe = filledExpected(routedTo: routedTo, replyKind: replyKind, created: created, snapshot: snapshot)
            fe["intelligenceCalls"] = caseIntelCalls
            filled["expected"] = fe
            filled["unverified"] = true
            var draft = (c["draft"] as? [String: Any]) ?? [:]
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            draft["expectedFilledFromRerunOn"] = f.string(from: Date())
            filled["draft"] = draft
            filledCases.append(filled)
        }
        for spec in (expected["rows"] as? [[String: Any]]) ?? [] {
            guard let needle = spec["titleContains"] as? String else {
                mismatches.append("expected row without titleContains"); continue
            }
            guard let row = created.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }) else {
                mismatches.append("row containing \"\(needle)\": none (rows: \(created.map(\.title).joined(separator: ", ")))")
                continue
            }
            mismatches.append(contentsOf: compare(spec, against: row, snapshot: snapshot, label: "\"\(needle)\""))
        }
        return failureLine(input: inputSummary, mismatches: mismatches)
    }

    /// The observed outcome in `expected` shape: the same fields the
    /// hand-written cases use, dates relative to today.
    private static func filledExpected(routedTo: String, replyKind: String, created: [NudgeTask], snapshot: NudgeArbiter.DebugRunSnapshot?) -> [String: Any] {
        let rows: [[String: Any]] = created.map { t in
            var r: [String: Any] = [
                "titleContains": t.title,
                "isEvent": t.isInformationalEvent,
                "hasDeadline": t.hasDeadline,
                "countdown": !t.isComplete && CountdownState.dueDateLine(dueDate: t.dueDate, specificTime: t.specificTime) != nil,
                "isOverdue": t.isOverdue,
                "intendedDay": t.intendedDate.map { day($0) } ?? NSNull(),
                "plannedStart": t.plannedStartDate.map { dayAndClock($0) } ?? NSNull()
            ]
            if let m = t.estimatedMinutes { r["estimatedMinutes"] = m }
            return r
        }
        return ["routedTo": routedTo, "replyKind": replyKind, "rowCount": created.count, "rows": rows]
    }

    // MARK: - Field comparison (shared by both kinds)

    /// Every observable the cases can assert on, read from the real helpers.
    private static func actualFields(_ task: NudgeTask, snapshot: NudgeArbiter.DebugRunSnapshot?) -> [String: String] {
        var f: [String: String] = [:]
        f["isEvent"] = str(task.isInformationalEvent)
        f["hasDeadline"] = str(task.hasDeadline)
        // The Tasks-row right-side line: a countdown/due line is shown
        // exactly when this is non-nil on an open row.
        f["countdown"] = str(!task.isComplete && CountdownState.dueDateLine(dueDate: task.dueDate, specificTime: task.specificTime) != nil)
        f["isOverdue"] = str(task.isOverdue)
        f["isSkipped"] = str(task.isSkipped)
        f["intentIsFuture"] = str(task.intentIsFuture())
        f["intendedDay"] = task.intendedDate.map { day($0) } ?? "null"
        f["scheduledDay"] = task.scheduledDay.map { day($0) } ?? "null"
        f["dueDay"] = task.dueDate.map { day($0) } ?? "null"
        f["plannedStart"] = task.plannedStartDate.map { dayAndClock($0) } ?? "null"
        f["plannedIsAuto"] = str(task.plannedIsAuto)
        f["estimatedMinutes"] = task.estimatedMinutes.map(String.init) ?? "null"
        f["priority"] = task.priority
        f["sequenceIndex"] = task.sequenceIndex.map(String.init) ?? "null"
        f["skipCount"] = String(task.skipCount)
        f["source"] = task.source
        f["stakes"] = task.stakes?.rawValue ?? "null"
        f["timeWindow"] = task.timeWindow?.rawValue ?? "null"
        let kinds = Set((snapshot?.raw ?? []).filter { $0.taskID == task.id }.map { $0.kind.rawValue })
        for k in NudgeOutcomeKind.allCases {
            f["candidates.\(k.rawValue)"] = str(kinds.contains(k.rawValue))
        }
        return f
    }

    private static func compare(_ spec: [String: Any], against task: NudgeTask, snapshot: NudgeArbiter.DebugRunSnapshot?, label: String) -> [String] {
        let actual = actualFields(task, snapshot: snapshot)
        var out: [String] = []
        for (key, value) in spec where key != "title" && key != "titleContains" {
            if key == "candidates", let dict = value as? [String: Any] {
                for (kind, want) in dict {
                    let fullKey = "candidates.\(kind)"
                    guard let have = actual[fullKey] else {
                        out.append("\(label) \(fullKey): unknown candidate kind"); continue
                    }
                    let wantStr = normalizeExpected(want)
                    if wantStr != have { out.append("\(label) \(fullKey): expected \(wantStr), actual \(have)") }
                }
                continue
            }
            guard let have = actual[key] else {
                out.append("\(label) \(key): unknown field"); continue
            }
            let wantStr = normalizeExpected(value)
            if wantStr != have { out.append("\(label) \(key): expected \(wantStr), actual \(have)") }
        }
        return out
    }

    private static func failureLine(input: String, mismatches: [String]) -> String? {
        guard !mismatches.isEmpty else { return nil }
        // Each mismatch already carries expected + actual; the line keeps
        // Roman's requested shape with both halves readable.
        let expected = mismatches.map { $0.replacingOccurrences(of: ", actual .*$", with: "", options: .regularExpression) }
        let actual = mismatches.map { m -> String in
            if let r = m.range(of: ", actual ") {
                let head = m[..<m.range(of: ": expected ")!.lowerBound]
                return "\(head): \(m[r.upperBound...])"
            }
            return m
        }
        return "input: \(input) | expected: \(expected.joined(separator: "; ")) | actual: \(actual.joined(separator: "; "))"
    }

    // MARK: - Value formatting

    private enum HarnessError: Error { case bad(String) }

    private static func str(_ b: Bool) -> String { b ? "true" : "false" }

    /// Expected values are written by hand: booleans, ints, strings, null,
    /// or relative dates ("+1d", "-1d 19:00", "today", "tomorrow").
    private static func normalizeExpected(_ v: Any) -> String {
        if v is NSNull { return "null" }
        // JSONSerialization hands back NSNumber for both `true` and `1`;
        // only a real CFBoolean is a Bool here, so `skipCount: 1` stays 1.
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return str(n.boolValue) }
            return "\(n)"
        }
        if let s = v as? String {
            switch s.lowercased() {
            case "today": return "+0d"
            case "tomorrow": return "+1d"
            case "yesterday": return "-1d"
            default: break
            }
            if let (offset, clock) = parseRelative(s) {
                return clock.map { String(format: "%+dd %02d:%02d", offset, $0.h, $0.m) } ?? String(format: "%+dd", offset)
            }
            return s
        }
        return "\(v)"
    }

    private static func parseRelative(_ s: String) -> (Int, (h: Int, m: Int)?)? {
        let pattern = #"^([+-]?\d+)d(?:\s+(\d{1,2}):(\d{2}))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return String(s[r])
        }
        guard let offset = group(1).flatMap(Int.init) else { return nil }
        if let h = group(2).flatMap(Int.init), let mm = group(3).flatMap(Int.init) {
            return (offset, (h, mm))
        }
        return (offset, nil)
    }

    /// Resolves a relative date from the case file against today.
    private static func resolve(_ raw: Any, defaultHour: Int?, defaultMinute: Int?, field: String) throws -> Date? {
        if raw is NSNull { return nil }
        guard let s = raw as? String else { throw HarnessError.bad("\(field): expected a string like \"+1d 09:00\"") }
        let text: String
        switch s.lowercased() {
        case "today": text = "+0d"
        case "tomorrow": text = "+1d"
        case "yesterday": text = "-1d"
        default: text = s
        }
        guard let (offset, clock) = parseRelative(text) else {
            throw HarnessError.bad("\(field): could not read \"\(s)\" (use \"+1d\", \"-2d 19:00\", today, tomorrow, yesterday)")
        }
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        guard let dayDate = cal.date(byAdding: .day, value: offset, to: base) else { return nil }
        let h = clock?.h ?? defaultHour
        let m = clock?.m ?? defaultMinute
        guard let h, let m else {
            throw HarnessError.bad("\(field): needs a clock time, e.g. \"\(s) 09:00\"")
        }
        return cal.date(bySettingHour: h, minute: m, second: 0, of: dayDate)
    }

    private static func day(_ d: Date) -> String {
        let cal = Calendar.current
        let offset = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        return String(format: "%+dd", offset)
    }

    private static func dayAndClock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%@ %02d:%02d", day(d), c.hour ?? 0, c.minute ?? 0)
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
#endif
