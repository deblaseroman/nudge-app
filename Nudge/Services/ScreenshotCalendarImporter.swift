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
        // 1. OCR
        let ocrText: String
        do {
            ocrText = try await recognizeText(in: image)
        } catch {
            return CalendarImportResult(
                importedCount: 0,
                skippedDuplicates: 0,
                errors: ["Couldn't read the image. Try a clearer screenshot."]
            )
        }

        let trimmed = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        print("[ScreenshotCalendarImporter] OCR text (\(trimmed.count) chars):\n\(trimmed)")
        #endif
        guard !trimmed.isEmpty else {
            return CalendarImportResult(
                importedCount: 0,
                skippedDuplicates: 0,
                errors: ["No readable text found in the screenshot."]
            )
        }

        // 2. AI parse
        let parsed: [ParsedScreenshotEvent]
        do {
            parsed = try await ClaudeService.shared.parseScheduleScreenshot(
                ocrText: trimmed,
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

    private func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw ImporterError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
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
        let day = calendar.startOfDay(for: event.startDate)

        let allTasks = (try? modelContext.fetch(FetchDescriptor<NudgeTask>())) ?? []
        return allTasks.contains { existing in
            guard let existingTime = existing.specificTime else { return false }
            guard calendar.isDate(existingTime, inSameDayAs: day) else { return false }
            let existingTitle = existing.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Same day + same title (case-insensitive) treated as duplicate
            // regardless of which source brought it in.
            return existingTitle == normalizedTitle
        }
    }

    enum ImporterError: Error {
        case invalidImage
    }
}

// MARK: - DTO

struct ParsedScreenshotEvent {
    let title: String
    let startDate: Date
    let estimatedMinutes: Int?
    let category: String?
}
