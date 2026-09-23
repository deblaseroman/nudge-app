//
//  NudgeCompanionWidget.swift
//  NudgeWidget
//
//  Widget 4 — Companion widget. Just the mascot at 70×70pt.
//  Tap anywhere to open the app. systemSmall only.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct NudgeCompanionEntry: TimelineEntry {
    let date: Date
}

// MARK: - Timeline Provider

struct NudgeCompanionProvider: TimelineProvider {
    func placeholder(in context: Context) -> NudgeCompanionEntry {
        NudgeCompanionEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (NudgeCompanionEntry) -> ()) {
        completion(NudgeCompanionEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NudgeCompanionEntry>) -> ()) {
        let entry = NudgeCompanionEntry(date: Date())
        // Companion widget is static — no need to refresh
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - View

struct NudgeCompanionView: View {
    var entry: NudgeCompanionEntry

    var body: some View {
        VStack {
            Image("mascot-default")
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 70)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "nudge://open"))
        // No manual .background here — the background is the edge-to-edge
        // containerBackground on the widget config below. A .background sits
        // inside the system content margins and inset the fill from the border.
        .overlay {
            ContainerRelativeShape()
                .strokeBorder(WidgetColors.neutral.opacity(0.28), lineWidth: 1)
        }
    }
}

// MARK: - Widget Configuration

struct NudgeCompanionWidget: Widget {
    let kind: String = "NudgeCompanionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NudgeCompanionProvider()) { entry in
            NudgeCompanionView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetColors.background
                }
        }
        .configurationDisplayName("Nudge Companion")
        .description("Your Nudge mascot \u{2014} tap to open the app.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    NudgeCompanionWidget()
} timeline: {
    NudgeCompanionEntry(date: .now)
}
