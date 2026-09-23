//
//  CaptureHistoryExporter.swift
//  Nudge
//
//  DEBUG-only. Two pieces of capture-history plumbing for the eval set:
//
//  `CaptureLog` — appended by `CaptureWriter.apply` after every real capture
//  (never by the eval harness): the message, the model's own items with
//  `dueKind`, and the rows exactly as written. `Documents/CaptureLog.jsonl`.
//  From the day this ships, the export below is exact for these captures.
//
//  `CaptureHistoryExporter` — `-nudge-export-captures [path]` writes
//  `eval/cases.draft.json` in `cases.json` shape from everything the device
//  knows: logged captures (exact), and before the log existed, the
//  `DailySession` transcripts paired by day and order with the capture rows'
//  `createdAt` bursts (best effort, marked). Messages the small-talk or plan
//  routers took are listed as their own cases. Every case is
//  `"unverified": true`; nothing here touches `cases.json`. Read-only apart
//  from the two files it writes; capture behavior is untouched.
//

#if DEBUG
import Foundation
import SwiftData

// MARK: - Capture log (written at the write site)

enum CaptureLog {
    static let fileName = "CaptureLog.jsonl"

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    /// One capture: what was typed, what the model returned, what was written.
    struct Entry: Codable {
        struct Item: Codable {
            let title: String
            let isEvent: Bool?
            let dueDate: String?
            let dueTime: String?
            let dueKind: String?
            let estimatedMinutes: Int?
            let sequenceIndex: Int?
        }
        struct Row: Codable {
            let id: String
            let title: String
            let isEvent: Bool
            let dueDate: Date?
            let specificTime: Date?
            let intendedDate: Date?
            let plannedStartDate: Date?
            let estimatedMinutes: Int?
            let priority: String
            let sequenceIndex: Int?
        }
        let at: Date
        let message: String
        let reply: String
        let items: [Item]
        let rows: [Row]
        let dropped: [String]
    }

    @MainActor
    static func record(message: String, response: ClaudeResponse, result: CaptureWriteResult) {
        let entry = Entry(
            at: Date(),
            message: message,
            reply: response.message,
            items: response.tasks.map {
                Entry.Item(title: $0.title, isEvent: $0.isEvent, dueDate: $0.dueDate, dueTime: $0.dueTime,
                           dueKind: $0.dueKind, estimatedMinutes: $0.estimatedMinutes, sequenceIndex: $0.sequenceIndex)
            },
            rows: result.created.map {
                Entry.Row(id: $0.id.uuidString, title: $0.title, isEvent: $0.isInformationalEvent,
                          dueDate: $0.dueDate, specificTime: $0.specificTime, intendedDate: $0.intendedDate,
                          plannedStartDate: $0.plannedStartDate, estimatedMinutes: $0.estimatedMinutes,
                          priority: $0.priority, sequenceIndex: $0.sequenceIndex)
            },
            dropped: result.dropped.map { "\($0.title): \($0.reason)" }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    static func entries() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Entry.self, from: data)
        }
    }
}

// MARK: - Exporter

@MainActor
enum CaptureHistoryExporter {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-nudge-export-captures")
    }

    /// Where the draft lands: the path after the flag if one was given (the
    /// simulator can write to a Mac path), else the app's Documents folder,
    /// where `scripts/export-captures.sh` copies it from.
    static func runFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        var target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cases.draft.json")
        if let i = args.firstIndex(of: "-nudge-export-captures"), i + 1 < args.count, !args[i + 1].hasPrefix("-") {
            target = URL(fileURLWithPath: args[i + 1])
        }
        run(to: target)
    }

    private struct Counts {
        var captures = 0, days = 0, swallowed = 0, planIntent = 0, ambiguousDays = 0, logged = 0
    }

    static func run(to target: URL) {
        let context = SharedModelContainer.container.mainContext
        let calendar = Calendar.current

        // The real arbiter run on the real store, so `floaterTarget` below is
        // the arbiter's own answer (the launch reevaluate does this anyway).
        var floaterTargetIDs = Set<UUID>()
        if let profile = (try? context.fetch(FetchDescriptor<UserProfile>()))?.first {
            NudgeArbiter.shared.reevaluate(reason: .taskCreatedOrEdited, profile: profile, modelContext: context)
            let raw = (NudgeArbiter.shared as? NudgeArbiter)?.lastRunSnapshot?.raw ?? []
            floaterTargetIDs = Set(raw.filter { $0.kind == .floater }.compactMap(\.taskID))
        }

        let allTasks = (try? context.fetch(FetchDescriptor<NudgeTask>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        let captureRows = allTasks.filter { $0.source == "capture" }.sorted { $0.createdAt < $1.createdAt }
        let sessions = ((try? context.fetch(FetchDescriptor<DailySession>())) ?? []).sorted { $0.startedAt < $1.startedAt }
        let logged = CaptureLog.entries()

        // Rows grouped into bursts: one capture writes its rows within
        // seconds; a gap of more than 20s is the next capture.
        var bursts: [[NudgeTask]] = []
        for row in captureRows {
            if let last = bursts.last?.last, row.createdAt.timeIntervalSince(last.createdAt) < 20 {
                bursts[bursts.count - 1].append(row)
            } else {
                bursts.append([row])
            }
        }
        // Rows the log already accounts for are not paired by order.
        let loggedRowIDs = Set(logged.flatMap { $0.rows.compactMap { UUID(uuidString: $0.id) } })
        let unloggedBursts = bursts.filter { burst in !burst.contains { loggedRowIDs.contains($0.id) } }
        let burstsByDay = Dictionary(grouping: unloggedBursts) { calendar.startOfDay(for: $0[0].createdAt) }
        let loggedMessages = Set(logged.map { "\(calendar.startOfDay(for: $0.at).timeIntervalSince1970)|\($0.message)" })

        var cases: [[String: Any]] = []
        var swallowed: [[String: Any]] = []
        var planIntents: [[String: Any]] = []
        var counts = Counts()
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.locale = Locale(identifier: "en_US_POSIX")
        let weekdayFmt = DateFormatter(); weekdayFmt.dateFormat = "EEEE"; weekdayFmt.locale = Locale(identifier: "en_US_POSIX")
        var daysSeen = Set<Date>()

        // 1. Logged captures: exact.
        for (n, entry) in logged.enumerated() {
            let day = calendar.startOfDay(for: entry.at)
            daysSeen.insert(day)
            let rows = entry.rows.compactMap { UUID(uuidString: $0.id).flatMap { byID[$0] } }
            var draft: [String: Any] = [
                "capturedOn": "\(dayFmt.string(from: day)) (\(weekdayFmt.string(from: day)))",
                "alignment": "logged",
                "reply": entry.reply,
                "modelItems": entry.items.map { item -> [String: Any] in
                    ["title": item.title, "isEvent": item.isEvent ?? false, "dueDate": item.dueDate ?? NSNull(),
                     "dueTime": item.dueTime ?? NSNull(), "dueKind": item.dueKind ?? NSNull()]
                },
                "rows": entry.rows.map { logRowDraft($0, floaterTargetIDs: floaterTargetIDs, live: byID) },
                "dropped": entry.dropped
            ]
            if rows.count < entry.rows.count { draft["deletedSince"] = entry.rows.count - rows.count }
            cases.append(makeCase(
                id: "hist-\(dayFmt.string(from: day))-log\(n + 1)",
                text: entry.message,
                rows: entry.rows.map { ExpectedRow(fromLog: $0, day: day) },
                rowCount: entry.rows.count,
                draft: draft,
                note: "From the capture log: exact rows as written that day."
            ))
            counts.captures += 1; counts.logged += 1
        }

        // 2. Transcripts: per day, in order, paired with that day's bursts.
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            let messages = decode(session.chatTranscript)
            var userTurns: [(text: String, reply: String)] = []
            for (i, m) in messages.enumerated() where m.role == .user {
                let reply = messages.dropFirst(i + 1).first { $0.role == .assistant }?.text ?? ""
                userTurns.append((m.text, reply))
            }
            guard !userTurns.isEmpty else { continue }
            daysSeen.insert(day)
            let dayLabel = "\(dayFmt.string(from: day)) (\(weekdayFmt.string(from: day)))"
            let dayID = dayFmt.string(from: day)

            var captureTurns: [(text: String, reply: String)] = []
            var n = 0
            for turn in userTurns {
                n += 1
                if loggedMessages.contains("\(day.timeIntervalSince1970)|\(turn.text)") { continue }
                if HomeTabView.isPlanIntent(turn.text) {
                    planIntents.append(routedCase(id: "plan-\(dayID)-\(n)", text: turn.text, route: "plan", day: dayLabel, reply: turn.reply))
                    counts.planIntent += 1
                } else if ChatRouter.isSmallTalk(turn.text) {
                    swallowed.append(routedCase(id: "swallowed-\(dayID)-\(n)", text: turn.text, route: "smallTalk", day: dayLabel, reply: turn.reply))
                    counts.swallowed += 1
                } else {
                    captureTurns.append(turn)
                }
            }
            guard !captureTurns.isEmpty else { continue }

            let dayBursts = (burstsByDay[day] ?? []).sorted { $0[0].createdAt < $1[0].createdAt }
            let exact = dayBursts.count == captureTurns.count
            if !exact { counts.ambiguousDays += 1 }
            for (i, turn) in captureTurns.enumerated() {
                counts.captures += 1
                let rows = exact ? dayBursts[i] : []
                var draft: [String: Any] = [
                    "capturedOn": dayLabel,
                    "alignment": exact ? "exact" : "ambiguous",
                    "reply": turn.reply,
                    "rows": rows.map { liveRowDraft($0, floaterTargetIDs: floaterTargetIDs) }
                ]
                var note = exact
                    ? "Reconstructed: rows paired by day and order; fields are the rows' state now, not at capture."
                    : "Ambiguous day: \(captureTurns.count) capture messages, \(dayBursts.count) row bursts. Pair by hand from draft.dayBursts."
                if !exact {
                    draft["dayBursts"] = dayBursts.map { burst in burst.map { liveRowDraft($0, floaterTargetIDs: floaterTargetIDs) } }
                }
                if !calendar.isDateInToday(day) {
                    note += " Placements older than today were cleared by the rollover, so plannedStart is not exported."
                }
                cases.append(makeCase(
                    id: "hist-\(dayID)-\(i + 1)",
                    text: turn.text,
                    rows: rows.map { ExpectedRow(fromLive: $0, day: day, includePlacement: calendar.isDateInToday(day)) },
                    rowCount: exact ? rows.count : nil,
                    draft: draft,
                    note: note
                ))
            }
        }
        counts.days = daysSeen.count

        let all = cases + swallowed + planIntents
        do {
            let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: target)
            let meta: [String: Any] = [
                "writtenAt": ISO8601DateFormatter().string(from: Date()),
                "captures": counts.captures, "logged": counts.logged, "days": counts.days,
                "swallowed": counts.swallowed, "planIntent": counts.planIntent, "ambiguousDays": counts.ambiguousDays,
                "cases": all.count
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try metaData.write(to: target.deletingLastPathComponent().appendingPathComponent("cases.draft.meta.json"))
        } catch {
            print("EXPORT ERROR \(error)")
            return
        }
        print("EXPORT captures \(counts.captures) over \(counts.days) days (\(counts.logged) from the log), swallowed \(counts.swallowed), plan-intent \(counts.planIntent), ambiguous days \(counts.ambiguousDays) → \(target.path)")
    }

    // MARK: - Case building

    /// The subset of harness row fields the export can state.
    private struct ExpectedRow {
        var fields: [String: Any]

        init(fromLive t: NudgeTask, day: Date, includePlacement: Bool) {
            var f: [String: Any] = [
                "titleContains": t.title,
                "isEvent": t.isInformationalEvent,
                "hasDeadline": t.hasDeadline,
                "countdown": CountdownState.dueDateLine(dueDate: t.dueDate, specificTime: t.specificTime) != nil,
                "intendedDay": t.intendedDate.map { offset($0, from: day) } ?? NSNull()
            ]
            if includePlacement { f["plannedStart"] = t.plannedStartDate.map { offsetClock($0, from: day) } ?? NSNull() }
            if let m = t.estimatedMinutes { f["estimatedMinutes"] = m }
            fields = f
        }

        init(fromLog r: CaptureLog.Entry.Row, day: Date) {
            fields = [
                "titleContains": r.title,
                "isEvent": r.isEvent,
                "hasDeadline": r.dueDate != nil || r.specificTime != nil,
                "countdown": CountdownState.dueDateLine(dueDate: r.dueDate, specificTime: r.specificTime) != nil,
                "intendedDay": r.intendedDate.map { offset($0, from: day) } ?? NSNull(),
                "plannedStart": r.plannedStartDate.map { offsetClock($0, from: day) } ?? NSNull()
            ]
            if let m = r.estimatedMinutes { fields["estimatedMinutes"] = m }
        }
    }

    private static func makeCase(id: String, text: String, rows: [ExpectedRow], rowCount: Int?, draft: [String: Any], note: String) -> [String: Any] {
        var expected: [String: Any] = ["rows": rows.map(\.fields)]
        if let rowCount { expected["rowCount"] = rowCount }
        return ["id": id, "kind": "capture", "unverified": true,
                "input": ["text": text], "expected": expected, "draft": draft, "note": note]
    }

    private static func routedCase(id: String, text: String, route: String, day: String, reply: String) -> [String: Any] {
        ["id": id, "kind": "capture", "unverified": true,
         "input": ["text": text],
         "expected": ["routedTo": route, "rowCount": 0],
         "draft": ["capturedOn": day, "reply": reply],
         "note": route == "smallTalk"
            ? "The small-talk router took this message; no API call, no rows. Change routedTo to capture to assert the fix."
            : "The plan-intent router sent this to the day planner; no rows."]
    }

    private static func dueKind(isEvent: Bool, hasDeadline: Bool, intended: Date?) -> String {
        if isEvent { return "event" }
        if hasDeadline { return "deadline" }
        if intended != nil { return "start" }
        return "none"
    }

    private static func liveRowDraft(_ t: NudgeTask, floaterTargetIDs: Set<UUID>) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return ["title": t.title,
                "dueKind": dueKind(isEvent: t.isInformationalEvent, hasDeadline: t.hasDeadline, intended: t.intendedDate),
                "dueDate": t.dueDate.map(iso.string) ?? NSNull(),
                "specificTime": t.specificTime.map(iso.string) ?? NSNull(),
                "intendedDate": t.intendedDate.map(iso.string) ?? NSNull(),
                "plannedStartDate": t.plannedStartDate.map(iso.string) ?? NSNull(),
                "createdAt": iso.string(from: t.createdAt),
                "isComplete": t.isComplete,
                "floaterTarget": floaterTargetIDs.contains(t.id)]
    }

    private static func logRowDraft(_ r: CaptureLog.Entry.Row, floaterTargetIDs: Set<UUID>, live: [UUID: NudgeTask]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let id = UUID(uuidString: r.id)
        return ["title": r.title,
                "dueKind": dueKind(isEvent: r.isEvent, hasDeadline: r.dueDate != nil || r.specificTime != nil, intended: r.intendedDate),
                "dueDate": r.dueDate.map(iso.string) ?? NSNull(),
                "specificTime": r.specificTime.map(iso.string) ?? NSNull(),
                "intendedDate": r.intendedDate.map(iso.string) ?? NSNull(),
                "plannedStartDate": r.plannedStartDate.map(iso.string) ?? NSNull(),
                "stillInStore": id.map { live[$0] != nil } ?? false,
                "floaterTarget": id.map { floaterTargetIDs.contains($0) } ?? false]
    }

    private static func offset(_ d: Date, from day: Date) -> String {
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: day, to: cal.startOfDay(for: d)).day ?? 0
        return String(format: "%+dd", n)
    }

    private static func offsetClock(_ d: Date, from day: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%@ %02d:%02d", offset(d, from: day), c.hour ?? 0, c.minute ?? 0)
    }

    private static func decode(_ transcript: String) -> [HomeChatMessage] {
        guard let data = transcript.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HomeChatMessage].self, from: data) else { return [] }
        return decoded
    }
}
#endif
