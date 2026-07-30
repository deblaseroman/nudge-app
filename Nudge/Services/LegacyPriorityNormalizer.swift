//
//  LegacyPriorityNormalizer.swift
//  Nudge
//
//  One-shot repair for the retired "urgent" priority value.
//

import Foundation
import SwiftData

/// Folds the retired `"urgent"` priority into `"high"` on existing rows.
///
/// The canonical vocabulary is high|medium|low (`NudgeTask.priority`'s own
/// doc comment), but the brain-dump prompt offered "urgent" as a fourth
/// value until Jul 2026 — so stored rows could carry a value that rendered
/// differently on every surface: Stats printed it verbatim, the widget's
/// priority pip fell through to the medium style, and the widget's urgent
/// counter (`priority == "high"`) didn't count it as urgent at all.
///
/// The prompt no longer offers "urgent" and `HomeTabView` normalizes both
/// capture write paths, so after one pass over existing rows the value is
/// extinct. The sweep is idempotent and cheap (predicate-scoped, zero rows
/// after the first run), so it needs no completion marker.
@MainActor
enum LegacyPriorityNormalizer {
    static func sweep(modelContext: ModelContext) {
        let urgent = "urgent"
        var changed = 0

        let taskDescriptor = FetchDescriptor<NudgeTask>(
            predicate: #Predicate<NudgeTask> { $0.priority == urgent }
        )
        for task in (try? modelContext.fetch(taskDescriptor)) ?? [] {
            task.priority = "high"
            changed += 1
        }

        // CompletedTaskRecord copies the task's priority at completion time
        // and Stats renders it verbatim — those rows need the same fold.
        let recordDescriptor = FetchDescriptor<CompletedTaskRecord>(
            predicate: #Predicate<CompletedTaskRecord> { $0.priority == urgent }
        )
        for record in (try? modelContext.fetch(recordDescriptor)) ?? [] {
            record.priority = "high"
            changed += 1
        }

        guard changed > 0 else { return }
        #if DEBUG
        print("🧹 LegacyPriorityNormalizer: folded \(changed) \"urgent\" row(s) into \"high\".")
        #endif
        try? modelContext.save()
    }
}
