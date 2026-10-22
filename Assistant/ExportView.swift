import SwiftUI

/** Where an export starts: a folder, and the file it was asked for on (picked, and first). */
struct ExportTarget: Identifiable {
    let folder: String
    let first: String?
    var id: String { folder + "|" + (first ?? "") }
}

/** "1-3, 5" as page indices (from 0); empty: all; nil pages and an error for what isn't pages. */
func exportPages(_ text: String) throws -> [Int]? {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return nil }
    var pages: [Int] = []
    for part in t.split(whereSeparator: { $0 == "," || $0 == " " }) {
        let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...2).contains(ends.count), let from = ends.first ?? nil, let to = ends.last ?? nil, from >= 1, to >= from else {
            throw ExportError.pages(String(part))
        }
        pages += (from...to).map { $0 - 1 }
    }
    return pages
}

enum ExportError: LocalizedError {
    case pages(String)
    case nothing
    var errorDescription: String? {
        switch self {
        case .pages(let p): "“\(p)” isn't a page or a range"
        case .nothing: "Pick something to export"
        }
    }
}

/**
 * Notebooks, PDFs and notes in a folder made into one PDF to hand in: which, in what order, which
 * pages, and a cover page; saved to Downloads, or in the folder ([onSaved] with where).
 */
struct ExportView: View {
    let folder: String
    let first: String?
    var onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DriveStore.shared

    private struct Row: Identifiable {
        let entry: DriveEntry
        var on: Bool
        var pages = ""
        var id: String { entry.path }
    }

    @State private var rows: [Row]?
    @State private var cover = true
    @State private var title = ""
    @State private var subtitle = ""
    @AppStorage("exportAuthor") private var author = ""
    @State private var date = Date.now.formatted(.iso8601.year().month().day())
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export as PDF").font(.title2.bold())
            Text("One PDF to hand in: notebooks with their writing, PDFs, and notes typeset as they show here, in this order.")
                .font(.callout).foregroundStyle(.secondary)
            if let rows {
                if rows.isEmpty { Text("No PDFs or notes in this folder.").foregroundStyle(.secondary) }
                List {
                    ForEach(Binding(get: { self.rows ?? [] }, set: { self.rows = $0 })) { $row in
                        HStack {
                            Toggle("", isOn: $row.on).labelsHidden()
                            Image(systemName: driveIcon(driveKind(row.entry.name, folder: false))).foregroundStyle(.secondary)
                            Text(row.entry.name).lineLimit(1).truncationMode(.middle).foregroundStyle(row.on ? .primary : .secondary)
                            Spacer()
                            if driveKind(row.entry.name, folder: false) == .pdf {
                                TextField("All pages", text: $row.pages).frame(width: 110).disabled(!row.on).help("Pages, e.g. 1-3, 5 (empty: all)")
                            } else {
                                Text("Note").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                            }
                        }
                    }
                    .onMove { from, to in self.rows?.move(fromOffsets: from, toOffset: to) }
                }
                .frame(minHeight: 160, maxHeight: 300)
            } else {
                ProgressView()
            }
            Toggle("Cover page", isOn: $cover)
            if cover {
                Grid(alignment: .leading) {
                    GridRow { TextField("Title", text: $title); TextField("Course", text: $subtitle) }
                    GridRow { TextField("Name, student ID", text: $author); TextField("Date", text: $date) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save in This Folder") { run(save: true) }.disabled(busy || picked.isEmpty)
                Button(busy ? "Making It…" : "Save to Downloads") { run(save: false) }
                    .keyboardShortcut(.defaultAction).disabled(busy || picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            let parts = folder.split(separator: "/").map(String.init)
            title = parts.last ?? "Export"
            if parts.first == "Projects", parts.count > 2 { subtitle = parts[1] }
            await store.load(folder)
            let files = (store.children[folder] ?? []).filter { !$0.folder && [.pdf, .markdown].contains(driveKind($0.name, folder: false)) }
            let ordered = files.filter { $0.path == first } + files.filter { $0.path != first }
            rows = ordered.map { Row(entry: $0, on: first == nil || $0.path == first) }
        }
    }

    private var picked: [Row] { (rows ?? []).filter(\.on) }
    private var fileName: String {
        let name = (cover && !title.trimmingCharacters(in: .whitespaces).isEmpty) ? title : (picked.first.map { ($0.entry.name as NSString).deletingPathExtension } ?? "Export")
        return name.replacingOccurrences(of: "/", with: " ") + ".pdf"
    }

    private func request() throws -> ExportRequest {
        let items = try picked.map { r in
            ExportRequest.Item(path: r.entry.path, pages: driveKind(r.entry.name, folder: false) == .pdf ? try exportPages(r.pages) : nil)
        }
        if items.isEmpty { throw ExportError.nothing }
        func given(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        return ExportRequest(items: items, cover: cover ? .init(title: given(title) ?? "Export", subtitle: given(subtitle), author: given(author), date: given(date)) : nil)
    }

    private func run(save: Bool) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let request = try request()
                if save {
                    let path = try await AppModel.shared.api.driveExportSave(request, to: folder + fileName)
                    await store.load(folder)
                    onSaved(path)
                } else {
                    let pdf = try await AppModel.shared.api.driveExport(request)
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    var dest = downloads.appending(path: fileName)
                    var n = 2
                    let stem = (fileName as NSString).deletingPathExtension
                    while FileManager.default.fileExists(atPath: dest.path) {
                        dest = downloads.appending(path: "\(stem) (\(n)).pdf")
                        n += 1
                    }
                    try pdf.write(to: dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
