import SwiftUI

/** Something the palette can do: go somewhere, make something. */
struct PaletteCommand {
    let label: String
    var hint: String? = nil
    var keywords = ""
    let run: () -> Void
}

/**
 * ⌘K: one box for everything. What's typed narrows the app's commands (go to a view, new task,
 * quick note, new note in a project) and finds things (tasks, projects, events, notes, files, mail,
 * PLMS) to jump to, opened as their links are.
 */
struct PaletteView: View {
    let commands: [PaletteCommand]
    /** Opens a found thing's link. */
    let open: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var found: [RefItem] = []
    @State private var at = 0
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let run: () -> Void
    }

    private var rows: [Row] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func matches(_ text: String) -> Bool { words.allSatisfy { text.lowercased().contains($0) } }
        let own = commands.filter { matches($0.label + " " + $0.keywords) }.map { c in Row(id: "c:" + c.label, label: c.label, detail: c.hint, run: c.run) }
        let notes = words.isEmpty ? [] : model.data.projects.filter { matches("new note in \($0.name)") }.map { p in
            Row(id: "n:" + p.id, label: "New note in \(p.name)", detail: nil) { QuickNote.make(in: p.id) }
        }
        let things = words.isEmpty ? [] : found.map { r in
            Row(id: "r:" + r.url, label: r.title, detail: [r.kind.rawValue.replacingOccurrences(of: "_", with: " "), r.context].compactMap { $0 }.joined(separator: " · ")) { open(r.url) }
        }
        return own + notes + things
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Go to, make, or find anything…", text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14)
                .focused($focused)
                .onSubmit { choose(at) }
                .onKeyPress(.downArrow) { at = min(at + 1, rows.count - 1); return .handled }
                .onKeyPress(.upArrow) { at = max(at - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            HStack {
                                Text(r.label).lineLimit(1)
                                Spacer()
                                if let d = r.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(i == at ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { choose(i) }
                            .id(i)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: at) { _, i in proxy.scrollTo(i) }
            }
            .frame(height: 340)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in at = 0 }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { found = []; return }
            try? await Task.sleep(for: .milliseconds(150))
            if let refs = try? await model.api.search(q) { found = refs }
        }
    }

    private func choose(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let row = rows[i]
        dismiss()
        row.run()
    }
}
