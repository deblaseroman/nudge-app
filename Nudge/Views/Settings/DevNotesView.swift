//
//  DevNotesView.swift
//  Nudge
//
//  Roman's in-app notebook (Sep 21 2026), DEBUG builds only: a place to
//  jot issues and changes while using the app, instead of switching to
//  another app. The notes are a plain text file in the app's Documents
//  folder so they can be pulled from a connected phone without any cloud:
//
//      scripts/pull-dev-notes.sh        (phone plugged in, trusted)
//
//  which copies Documents/DevNotes.md off the device for Claude Code to
//  read. Nothing here is compiled into a release build.
//

#if DEBUG
import SwiftUI

// MARK: - Store

struct DevNote: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var text: String
    var done: Bool
}

/// JSON for the app, Markdown mirror for the human reading it off the
/// device. Both live in Documents; the mirror is rewritten on every save.
enum DevNotesStore {
    static let jsonName = "DevNotes.json"
    static let markdownName = "DevNotes.md"

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func load() -> [DevNote] {
        let url = documents.appendingPathComponent(jsonName)
        guard let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([DevNote].self, from: data)
        else { return [] }
        return notes
    }

    static func save(_ notes: [DevNote]) {
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: documents.appendingPathComponent(jsonName), options: .atomic)
        }
        try? markdown(notes).write(
            to: documents.appendingPathComponent(markdownName), atomically: true, encoding: .utf8
        )
    }

    static func markdown(_ notes: [DevNote]) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Dev notes\n\nWritten in the app by Roman. Newest first. [x] = done.\n\n"
        for note in notes.sorted(by: { $0.createdAt > $1.createdAt }) {
            out += "- [\(note.done ? "x" : " ")] \(fmt.string(from: note.createdAt))  \(note.text.replacingOccurrences(of: "\n", with: "\n      "))\n"
        }
        return out
    }
}

// MARK: - View

struct DevNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [DevNote] = DevNotesStore.load()
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var open: [DevNote] { notes.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt } }
    private var done: [DevNote] { notes.filter { $0.done }.sorted { $0.createdAt > $1.createdAt } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Issue or change to make…", text: $draft, axis: .vertical)
                        .font(.custom(NudgeTheme.fontBody, size: 15))
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(12)
                        .background(NudgeTheme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    Button {
                        add()
                    } label: {
                        Text("Add")
                            .font(.custom(NudgeTheme.fontSemiBold, size: 14))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 44)
                            .background(draft.trimmingCharacters(in: .whitespaces).isEmpty ? NudgeTheme.textMuted : NudgeTheme.primary)
                            .clipShape(RoundedRectangle(cornerRadius: NudgeTheme.radiusButton))
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)

                List {
                    if open.isEmpty && done.isEmpty {
                        Text("Nothing noted yet.")
                            .font(.custom(NudgeTheme.fontBody, size: 14))
                            .foregroundColor(NudgeTheme.textMuted)
                    }
                    if !open.isEmpty {
                        Section("Open") {
                            ForEach(open) { note in noteRow(note) }
                        }
                    }
                    if !done.isEmpty {
                        Section("Done") {
                            ForEach(done) { note in noteRow(note) }
                        }
                    }
                }
                .listStyle(.insetGrouped)

                Text("Saved on this phone at Documents/DevNotes.md. Plug in and run scripts/pull-dev-notes.sh to hand them to Claude Code.")
                    .font(.custom(NudgeTheme.fontBody, size: 11))
                    .foregroundColor(NudgeTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .background(NudgeTheme.background)
            .navigationTitle("Dev notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func noteRow(_ note: DevNote) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                toggle(note)
            } label: {
                Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(note.done ? NudgeTheme.primary : NudgeTheme.textMuted)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.text)
                    .font(.custom(NudgeTheme.fontBody, size: 14))
                    .foregroundColor(note.done ? NudgeTheme.textMuted : NudgeTheme.textPrimary)
                    .strikethrough(note.done)
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.custom(NudgeTheme.fontBody, size: 11))
                    .foregroundColor(NudgeTheme.textMuted)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { remove(note) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.append(DevNote(id: UUID(), createdAt: Date(), text: text, done: false))
        draft = ""
        DevNotesStore.save(notes)
        NudgeHaptics.light()
    }

    private func toggle(_ note: DevNote) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].done.toggle()
        DevNotesStore.save(notes)
        NudgeHaptics.light()
    }

    private func remove(_ note: DevNote) {
        notes.removeAll { $0.id == note.id }
        DevNotesStore.save(notes)
    }
}
#endif
