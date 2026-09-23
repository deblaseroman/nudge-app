//
//  ScreenshotCalendarImporter.swift
//  Nudge
//
//  Lets the user import a calendar from an image (e.g. a HotSchedules work
//  schedule screenshot) without disconnecting their existing Apple Calendar.
//
//  Pipeline:
//    1. Vision OCR on-device — extracts every legible text fragment.
//    2. Claude reads the OCR text + today's date and emits structured
//       events as JSON.
//    3. Each event is inserted as a NudgeTask with isInformationalEvent=true
//       and source="screenshot" so it sits alongside (not on top of) Apple
//       Calendar / Canvas events.
//

import Foundation
import SwiftData
import UIKit
import Vision
import WidgetKit

@MainActor
final class ScreenshotCalendarImporter {

    static let shared = ScreenshotCalendarImporter()
    private init() {}

    // MARK: - Public API

    /// Imports events found inside the given image.
    ///
    /// - Parameters:
    ///   - image: The screenshot to read.
    ///   - defaultCategory: Used for any event the AI doesn't categorize
    ///     itself (e.g. a HotSchedules upload defaults to "work").
    ///   - modelContext: SwiftData context to insert events into.
    /// - Returns: A summary of what was inserted.
    func importFromImage(
        _ image: UIImage,
        defaultCategory: String,
        modelContext: ModelContext
    ) async -> CalendarImportResult {
        // 1. OCR, keeping WHERE each fragment sat. A flat list of lines
        // threw the layout away and left the model guessing which day
        // header a shift belonged to (Sep 21 2026: an on-call shift under
        // "Tue 22" landed on Monday). `ScheduleLayout` resolves the day
        // headers to real dates and assigns every line to its header
        // deterministically; the model only reads times and titles.
        let fragments: [OCRFragment]
        do {
            fragments = try await recognizeText(in: image)
        } catch {
            return CalendarImportResult(
                importedCount: 0,
                skippedDuplicates: 0,
                errors: ["Couldn't read the image. Try a clearer screenshot."]
            )
        }

        let transcript = ScheduleLayout.transcript(fragments, now: Date())
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        print("[ScreenshotCalendarImporter] layout transcript (\(fragments.count) fragments):\n\(trimmed)")
        #endif
        guard !trimmed.isEmpty else {
            return CalendarImportResult(
                importedCount: 0,
                skippedDuplicates: 0,
                errors: ["No readable text found in the screenshot."]
            )
        }

        // 2. AI parse — the picture itself goes along (the model sees the
        // real layout) with the transcript's resolved dates as the rule.
        let parsed: [ParsedScreenshotEvent]
        do {
            parsed = try await ClaudeService.shared.parseScheduleScreenshot(
                imageJPEG: Self.jpegForModel(image),
                transcript: trimmed,
                defaultCategory: defaultCategory
            )
        } catch {
            #if DEBUG
            print("[ScreenshotCalendarImporter] AI parse failed: \(error)")
            #endif
            return CalendarImportResult(
                importedCount: 0,
                skippedDuplicates: 0,
                errors: ["I couldn't make sense of that schedule. Try a different screenshot."]
            )
        }

        #if DEBUG
        print("[ScreenshotCalendarImporter] AI returned \(parsed.count) events. Inserting...")
        for event in parsed {
            print("  → \(event.title) @ \(event.startDate) (cat: \(event.category ?? "none"))")
        }
        #endif

        // 3. Insert (with dedup against existing screenshot/calendar events)
        var importedCount = 0
        var skippedDuplicates = 0

        for event in parsed {
            if isDuplicate(event, modelContext: modelContext) {
                skippedDuplicates += 1
                continue
            }
            let task = NudgeTask(
                title: event.title,
                dueDate: Calendar.current.startOfDay(for: event.startDate),
                dueTime: "specific",
                specificTime: event.startDate,
                priority: "medium",
                category: event.category ?? defaultCategory,
                source: "screenshot",
                estimatedMinutes: event.estimatedMinutes,
                isInformationalEvent: true
            )
            // Stakes writes go through the one guarded automation path
            // (never the init) so every non-user writer inherits the
            // user-override protection.
            task.setStakesFromAutomation(event.stakes)
            modelContext.insert(task)
            importedCount += 1
        }

        try? modelContext.save()
        if importedCount > 0 {
            WidgetCenter.shared.reloadTimelines(ofKind: "NudgeTaskWidget")
        }

        return CalendarImportResult(
            importedCount: importedCount,
            skippedDuplicates: skippedDuplicates,
            errors: []
        )
    }

    // MARK: - Vision OCR

    /// The picture for the model: long edge capped so the request stays
    /// small (a phone screenshot at full resolution is several MB).
    static func jpegForModel(_ image: UIImage, maxEdge: CGFloat = 1400) -> Data? {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: 0.72)
    }

    private func recognizeText(in image: UIImage) async throws -> [OCRFragment] {
        guard let cgImage = image.cgImage else { throw ImporterError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let fragments = observations.compactMap { obs -> OCRFragment? in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
                    return OCRFragment(text: text, box: obs.boundingBox)
                }
                continuation.resume(returning: fragments)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Dedup

    private func isDuplicate(_ event: ParsedScreenshotEvent, modelContext: ModelContext) -> Bool {
        let calendar = Calendar.current
        let normalizedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let startMinute = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: event.startDate)

        let allTasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>())) ?? []
        return allTasks.contains { existing in
            guard let existingTime = existing.specificTime else { return false }
            // Same START (to the minute) + same title, regardless of which
            // source brought it in. Day + title alone dropped the second
            // shift of a double (two "Server" shifts on one Saturday).
            let existingMinute = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: existingTime)
            guard existingMinute == startMinute else { return false }
            let existingTitle = existing.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return existingTitle == normalizedTitle
        }
    }

    enum ImporterError: Error {
        case invalidImage
    }
}

// MARK: - Layout

/// One recognized text fragment and where it sat. `box` is Vision's
/// normalized rect: origin bottom-left, y grows UPWARD.
struct OCRFragment {
    let text: String
    let box: CGRect
}

/// Turns positioned OCR fragments into a transcript the model cannot
/// misread: day headers ("Tue 22", "Mon 6/3", "Sep 22") are found and
/// resolved to real dates deterministically, and every other line is
/// prefixed with the date of the header it visually belongs to — the
/// nearest header row above it, and within that row the nearest header
/// by x (so both vertical day lists and week grids resolve). Pure; no
/// model, no calendar math left to the model.
enum ScheduleLayout {
    struct Header {
        let date: Date
        let box: CGRect
        /// Indices into the fragment array that make up this header, so
        /// the transcript never lists them as body text.
        let fragmentIndices: [Int]
    }

    private static let weekdayNames: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7
    ]
    private static let monthNames: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12
    ]

    static func transcript(_ fragments: [OCRFragment], now: Date, calendar: Calendar = .current) -> String {
        guard !fragments.isEmpty else { return "" }
        let headers = detectHeaders(fragments, now: now, calendar: calendar)
        var headerOfFragment: [Int: Int] = [:]
        for (h, header) in headers.enumerated() {
            for i in header.fragmentIndices { headerOfFragment[i] = h }
        }

        // Visual rows: top → bottom (Vision y grows upward), left → right.
        let indexed = fragments.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            if abs(a.1.box.midY - b.1.box.midY) > max(a.1.box.height, b.1.box.height) * 0.6 {
                return a.1.box.midY > b.1.box.midY
            }
            return a.1.box.minX < b.1.box.minX
        }
        var rows: [[(Int, OCRFragment)]] = []
        for item in sorted {
            if let last = rows.last?.last, abs(last.1.box.midY - item.1.box.midY) <= max(last.1.box.height, item.1.box.height) * 0.6 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd EEE"
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        let headerFmt = DateFormatter()
        headerFmt.dateFormat = "EEEE MMM d"
        headerFmt.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = []
        var announced = Set<Int>()
        for row in rows {
            // A header is named once, at the first row holding any of its
            // fragments; its fragments never appear as body text.
            for (i, _) in row {
                if let h = headerOfFragment[i], !announced.contains(h) {
                    announced.insert(h)
                    let date = headers[h].date
                    lines.append("## \(headerFmt.string(from: date)) (\(dayFmt.string(from: date)))")
                }
            }
            let others = row.filter { headerOfFragment[$0.0] == nil }.map(\.1)
            guard !others.isEmpty else { continue }
            let text = others.map(\.text).joined(separator: " | ")
            if let owner = owningHeader(for: others[0], headers: headers) {
                lines.append("[\(dayFmt.string(from: owner.date))] \(text)")
            } else {
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The header a fragment belongs to: the header whose TOP edge is at
    /// or above the fragment's centre and nearest to it (a shift level
    /// with its own day's header belongs to that day, not the one above);
    /// among headers in that same band, the nearest by x (week grids).
    static func owningHeader(for frag: OCRFragment, headers: [Header]) -> Header? {
        let tolerance = frag.box.height * 0.6
        let eligible = headers.filter { $0.box.maxY >= frag.box.midY - tolerance }
        guard let nearestTop = eligible.map(\.box.maxY).min(by: { abs($0 - frag.box.midY) < abs($1 - frag.box.midY) }) else { return nil }
        let band = eligible.map(\.box.height).max() ?? 0.02
        let row = eligible.filter { abs($0.box.maxY - nearestTop) <= band }
        return row.min { abs($0.box.midX - frag.box.midX) < abs($1.box.midX - frag.box.midX) }
    }

    /// Day headers, resolved to dates. Recognizes "Tue 22", "Tue, Sep 22",
    /// "Mon 6/3", "Sep 22", "9/22", and a weekday fragment with a bare
    /// day number sitting just below or beside it (calendar cells).
    static func detectHeaders(_ fragments: [OCRFragment], now: Date, calendar: Calendar) -> [Header] {
        var headers: [Header] = []
        var used = Set<Int>()
        let weekdayOnly = fragments.enumerated().filter { weekday(in: $0.element.text) != nil && dayNumber(in: $0.element.text) == nil && monthDay(in: $0.element.text) == nil && $0.element.text.split(separator: " ").count <= 2 }

        for (i, frag) in fragments.enumerated() {
            let text = frag.text
            // Only a fragment that is NOTHING BUT a date reads as a header:
            // "Tue 22", "Mon 6/3", "Sep 22". "1/1 Posted" or "Room 22" do not.
            guard isDateOnly(text) else { continue }
            if let md = monthDay(in: text) {
                if let date = resolve(month: md.month, day: md.day, weekday: weekday(in: text), now: now, calendar: calendar) {
                    headers.append(Header(date: date, box: frag.box, fragmentIndices: [i])); used.insert(i)
                }
                continue
            }
            if let wd = weekday(in: text), let day = dayNumber(in: text) {
                if let date = resolve(month: nil, day: day, weekday: wd, now: now, calendar: calendar) {
                    headers.append(Header(date: date, box: frag.box, fragmentIndices: [i])); used.insert(i)
                }
            }
        }
        // Weekday fragment + a bare number fragment next to it (below or right).
        for (i, frag) in weekdayOnly where !used.contains(i) {
            guard let wd = weekday(in: frag.text) else { continue }
            let near = fragments.enumerated().filter { j, other in
                j != i && !used.contains(j) && isBareNumber(other.text)
                    && abs(other.box.midX - frag.box.midX) < frag.box.width * 2.5 + other.box.width
                    && other.box.midY <= frag.box.midY + frag.box.height
                    && frag.box.midY - other.box.midY < frag.box.height * 3.5
            }
            guard let (j, numFrag) = near.min(by: { a, b in
                hypot(a.element.box.midX - frag.box.midX, a.element.box.midY - frag.box.midY)
                    < hypot(b.element.box.midX - frag.box.midX, b.element.box.midY - frag.box.midY)
            }), let day = Int(numFrag.text.trimmingCharacters(in: .whitespaces)),
               let date = resolve(month: nil, day: day, weekday: wd, now: now, calendar: calendar)
            else { continue }
            headers.append(Header(date: date, box: frag.box.union(numFrag.box), fragmentIndices: [i, j]))
            used.insert(i); used.insert(j)
        }
        return headers
    }

    // MARK: Token readers

    /// True when every token is a weekday, a month, a number, or a
    /// separator — the fragment is a date and nothing else.
    static func isDateOnly(_ text: String) -> Bool {
        let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 4 else { return false }
        return tokens.allSatisfy { weekdayNames[$0] != nil || monthNames[$0] != nil || Int($0) != nil }
    }

    static func weekday(in text: String) -> Int? {
        let tokens = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for t in tokens { if let w = weekdayNames[t] { return w } }
        return nil
    }

    static func dayNumber(in text: String) -> Int? {
        let tokens = text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        for t in tokens { if let n = Int(t), (1...31).contains(n), t.count <= 2 { return n } }
        return nil
    }

    static func isBareNumber(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count <= 2 && Int(t).map { (1...31).contains($0) } == true
    }

    /// "Sep 22", "September 22", "9/22", "6/3", "Tue, Sep 22".
    static func monthDay(in text: String) -> (month: Int, day: Int)? {
        let lower = text.lowercased()
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for (i, t) in tokens.enumerated() {
            if let m = monthNames[t], i + 1 < tokens.count, let d = Int(tokens[i + 1]), (1...31).contains(d) {
                return (m, d)
            }
        }
        // numeric m/d (not a clock time: no am/pm, contains a slash)
        if lower.contains("/"), !lower.contains("am"), !lower.contains("pm") {
            let parts = lower.components(separatedBy: "/").compactMap { Int($0.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)) }
            if parts.count >= 2, (1...12).contains(parts[0]), (1...31).contains(parts[1]) { return (parts[0], parts[1]) }
        }
        return nil
    }

    /// The real date for a header: with a month, this year (or next when
    /// that day is far past); with only a day number and weekday, the
    /// nearest date to today that matches both, within −14…+42 days.
    static func resolve(month: Int?, day: Int, weekday: Int?, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        if let month {
            let year = calendar.component(.year, from: today)
            for y in [year, year + 1, year - 1] {
                guard let d = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { continue }
                let delta = calendar.dateComponents([.day], from: today, to: d).day ?? 0
                if delta >= -60 && delta <= 300 {
                    if let weekday, calendar.component(.weekday, from: d) != weekday { continue }
                    return d
                }
            }
            return nil
        }
        var best: (Date, Int)?
        for offset in -14...42 {
            guard let d = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            guard calendar.component(.day, from: d) == day else { continue }
            if let weekday, calendar.component(.weekday, from: d) != weekday { continue }
            let score = abs(offset) * 2 + (offset < 0 ? 1 : 0)   // nearest wins; future on ties
            if best == nil || score < best!.1 { best = (d, score) }
        }
        return best?.0
    }
}

// MARK: - DTO

struct ParsedScreenshotEvent {
    let title: String
    let startDate: Date
    let estimatedMinutes: Int?
    let category: String?
    /// Consequence signal from the AI parse; nil when the model couldn't
    /// tell (tolerant-parsed — an unknown string never survives to here).
    let stakes: TaskStakes?
}
