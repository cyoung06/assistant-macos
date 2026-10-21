import AVKit
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/** A row of the folder tree: an entry, or "Loading…" inside a folder not listed yet. */
private struct TreeItem: Identifiable, Hashable {
    let id: String
    let entry: DriveEntry?
    var kids: [TreeItem]?
}

/** Where each storage was left (the selected path), so going elsewhere and back keeps it. */
@MainActor private var lastSelection: [String: String] = [:]

/**
 * Projects' storage like a small code editor: the folder tree on the left, what's selected on the
 * right (a file shown as itself, a folder as icons). Right-click for everything; drag to move (⌥
 * copies), out to Finder, or in from it; ⌘C ⌘X ⌘V and ⌫ work on the selection.
 */
struct FilesView: View {
    /** The top shown: a project's folder, or nil for every project's storage. */
    let root: String?
    let rootName: String

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = DriveStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?
    @State private var renaming: DriveEntry?
    @State private var newName = ""
    @State private var naming: String?
    @State private var deleting: DriveEntry?

    private var top: String { root ?? "Projects/" }
    private var selected: DriveEntry? { selection.flatMap { store.entries[$0] } }
    /** Where new things go: the selected folder, or the selected file's. */
    private var here: String { selected.map { $0.folder ? $0.path : driveParent($0.path) } ?? top }

    var body: some View {
        SplitView(leadingWidth: (220, 280, 520), trailingMinWidth: 360) {
            // Hosted by AppKit's split view, outside this view's environment: the model is passed in again.
            tree.frame(maxWidth: .infinity, maxHeight: .infinity).environmentObject(model)
        } trailing: {
            preview.frame(maxWidth: .infinity, maxHeight: .infinity).environmentObject(model)
        }
        .navigationTitle(rootName)
        .task(id: top) {
            selection = lastSelection[top]
            await store.load(top)
        }
        .onChange(of: selection) { _, s in lastSelection[top] = s }
        // A link followed in a note: the file it points to, selected (its folder listed first).
        .onReceive(NotificationCenter.default.publisher(for: .driveReveal)) { note in
            guard let path = note.object as? String, path.hasPrefix(top) else { return }
            Task {
                var folder = top
                for part in path.dropFirst(top.count).split(separator: "/").dropLast() {
                    folder += part + "/"
                    store.ensure(folder)
                }
                await store.load(driveParent(path))
                selection = path
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { upload(into: here) } label: { Label("Upload", systemImage: "square.and.arrow.up") }.disabled(driveReadOnly(here))
                Button { newName = ""; naming = here } label: { Label("New Folder", systemImage: "folder.badge.plus") }.disabled(driveReadOnly(here))
                Button { newMarkdown(in: here) } label: { Label("New Markdown File", systemImage: "doc.badge.plus") }.disabled(driveReadOnly(here))
                Button { Task { await store.reloadAll() } } label: { Label("Reload", systemImage: "arrow.triangle.2.circlepath") }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let e = renaming { Task { await store.rename(e, to: newName) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") { if let f = naming { Task { await store.makeFolder(newName, in: f) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”\(deleting?.folder == true ? " and everything in it" : "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let e = deleting {
                    if selection == e.path { selection = nil }
                    Task { await store.delete(e) }
                }
            }
        } message: {
            Text("It's deleted from the drive for every device.")
        }
    }

    // ---- the tree ----

    private func items(_ folder: String) -> [TreeItem] {
        (store.children[folder] ?? []).sortedForDisplay(in: folder, projects: model.data.projects).map { e in
            guard e.folder else { return TreeItem(id: e.path, entry: e, kids: nil) }
            guard store.children[e.path] != nil else { return TreeItem(id: e.path, entry: e, kids: [TreeItem(id: e.path + "\u{1}", entry: nil, kids: nil)]) }
            let kids = items(e.path)
            return TreeItem(id: e.path, entry: e, kids: kids.isEmpty ? nil : kids)
        }
    }

    private var tree: some View {
        List(items(top), children: \.kids, selection: $selection) { item in
            if let e = item.entry {
                row(e)
            } else {
                // A folder opened before it's listed: listing it replaces this.
                Text("Loading…").foregroundStyle(.secondary).onAppear { store.ensure(String(item.id.dropLast())) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(ids.first.flatMap { store.entries[$0] }, folder: top)
        } primaryAction: { ids in
            if let e = ids.first.flatMap({ store.entries[$0] }), !e.folder { Task { await store.openExternally(e) } }
        }
        .onCopyCommand {
            guard let e = selected else { return [] }
            store.clip = (e.path, false)
            return [NSItemProvider(object: e.path as NSString)]
        }
        .onCutCommand {
            guard let e = selected, !driveFixed(e.path) else { return [] }
            store.clip = (e.path, true)
            return [NSItemProvider(object: e.path as NSString)]
        }
        .onPasteCommand(of: [.fileURL, .plainText]) { providers in
            if store.clip != nil { Task { await store.paste(into: here) } } else { _ = store.accept(providers, into: here) }
        }
        .onDeleteCommand { if let e = selected, !driveFixed(e.path) { deleting = e } }
        .onDrop(of: [.driveItem, .fileURL], isTargeted: nil) { store.accept($0, into: top) }
        .overlay(alignment: .bottom) { errorBar }
    }

    private func row(_ e: DriveEntry) -> some View {
        Label {
            Text(e.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: driveIcon(driveKind(e.name, folder: e.folder))).foregroundStyle(tint(e))
        }
        .help(e.path)
        // A List row's drag data: .onDrag here takes the list's clicks (rows select late, or not at all).
        .itemProvider { DriveStore.provider(e) }
        .onDrop(of: e.folder ? [.driveItem, .fileURL] : [], isTargeted: nil) { store.accept($0, into: e.path) }
    }

    /** Project folders in their project's colour; other folders in the accent colour. */
    private func tint(_ e: DriveEntry) -> Color {
        guard e.folder else { return .secondary }
        if e.path.hasPrefix("Projects/"), e.path.split(separator: "/").count == 2, let p = model.data.projects.first(where: { folderName($0.name) == e.name }) {
            return Color(hex: p.color)
        }
        return .accentColor
    }

    private var errorBar: some View {
        Group {
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: Capsule()).padding(8)
                    .onTapGesture { store.error = nil }
            }
        }
    }

    // ---- what's selected ----

    @ViewBuilder private var preview: some View {
        if let e = selected, !e.folder, driveKind(e.name, folder: false) == .markdown {
            NoteView(path: e.path)
        } else if let e = selected, !e.folder {
            FilePreview(entry: e)
        } else {
            folderGrid(selected?.path ?? top, name: selected?.name ?? rootName)
        }
    }

    private func folderGrid(_ folder: String, name: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(name).font(.headline).lineLimit(1)
                if driveReadOnly(folder) { Text("From PLMS · read-only (copy files out to change them)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            .padding(10)
            Divider()
            ScrollView {
                let list = (store.children[folder] ?? []).sortedForDisplay(in: folder, projects: model.data.projects)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                    ForEach(list) { e in tile(e) }
                }
                .padding(14)
                if store.children[folder]?.isEmpty == true {
                    Text(driveReadOnly(folder) ? "Nothing here." : "Nothing here yet. Drop files here to upload them.").foregroundStyle(.secondary).padding()
                }
            }
            .contextMenu { menu(nil, folder: folder) }
            .onDrop(of: [.driveItem, .fileURL], isTargeted: nil) { store.accept($0, into: folder) }
        }
        .task(id: folder) { store.ensure(folder) }
    }

    private func tile(_ e: DriveEntry) -> some View {
        VStack(spacing: 6) {
            Thumbnail(entry: e, tint: tint(e)).frame(height: 76)
            Text(e.name).font(.callout).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
            if !e.folder { Text(driveSize(e.size)).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(width: 116)
        .padding(8)
        .background(selection == e.path ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(e.name)
        .onTapGesture(count: 2) { if e.folder { selection = e.path } else { Task { await store.openExternally(e) } } }
        .onTapGesture { selection = e.path }
        .contextMenu { menu(e, folder: driveParent(e.path)) }
        .onDrag { DriveStore.provider(e) }
        .onDrop(of: e.folder ? [.driveItem, .fileURL] : [], isTargeted: nil) { store.accept($0, into: e.path) }
    }

    // ---- the right-click menu ----

    @ViewBuilder private func menu(_ e: DriveEntry?, folder: String) -> some View {
        let target = e.map { $0.folder ? $0.path : driveParent($0.path) } ?? folder
        if let e {
            if !e.folder {
                Button("Open", systemImage: "arrow.up.forward.app") { Task { await store.openExternally(e) } }
                if driveKind(e.name, folder: false) == .markdown { Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "note", value: e.path) } }
                Button("Download to Downloads", systemImage: "arrow.down.circle") { Task { await store.saveToDownloads(e) } }
                Divider()
            }
            Button("Copy", systemImage: "doc.on.doc") { store.clip = (e.path, false) }
            if !driveFixed(e.path) { Button("Cut", systemImage: "scissors") { store.clip = (e.path, true) } }
        }
        if let clip = store.clip, !driveReadOnly(target) {
            Button("Paste “\(clip.path.split(separator: "/").last ?? "")”", systemImage: "doc.on.clipboard") { Task { await store.paste(into: target) } }
        }
        if let e, !driveReadOnly(driveParent(e.path)), !(e.path.hasPrefix("Projects/") && e.path.split(separator: "/").count <= 2) {
            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await store.duplicate(e) } }
        }
        if !driveReadOnly(target) {
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus") { newName = ""; naming = target }
            Button("New Markdown File", systemImage: "doc.badge.plus") { newMarkdown(in: target) }
            Button("Upload…", systemImage: "arrow.up.doc") { upload(into: target) }
        }
        if let e {
            Divider()
            Button("Copy Path", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e.path, forType: .string)
            }
            if !driveFixed(e.path) {
                Divider()
                Button("Rename…", systemImage: "pencil") { newName = e.name; renaming = e }
                Button("Delete…", systemImage: "trash", role: .destructive) { deleting = e }
            }
        }
    }

    private func newMarkdown(in folder: String) {
        Task { if let path = await store.newMarkdown(in: folder) { selection = path } }
    }

    private func upload(into folder: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        Task { await store.upload(panel.urls, into: folder) }
    }
}

/** Folders as the server lists them (folders first); project folders in the app's order, No project last. */
private extension Array where Element == DriveEntry {
    func sortedForDisplay(in folder: String, projects: [Project]) -> [DriveEntry] {
        guard folder == "Projects/" else { return self }
        let order = projects.map { folderName($0.name) }
        return sorted { a, b in
            if (a.name == "No project") != (b.name == "No project") { return b.name == "No project" }
            let x = order.firstIndex(of: a.name) ?? Int.max, y = order.firstIndex(of: b.name) ?? Int.max
            return x != y ? x < y : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/** A project's folder name (as the server makes it file-safe). */
private func folderName(_ project: String) -> String {
    var name = project.replacingOccurrences(of: #"[/\\:*?"<>|\u{0}-\u{1f}]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    while name.hasSuffix(".") { name.removeLast() }
    return name
}

/** A project's own storage, for its page. */
struct ProjectFilesView: View {
    let projectId: String
    let name: String
    @EnvironmentObject private var model: AppModel
    @State private var folder: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let folder { FilesView(root: folder, rootName: name) }
            else if let error { Text("Couldn't reach the drive: \(error)").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .task(id: projectId) {
            folder = nil
            do { folder = try await model.api.driveProjectFolder(projectId) } catch { self.error = error.localizedDescription }
        }
    }
}

// ---- icons and previews ----

/** A PDF's first page or an image itself; an icon for anything else (or until it loads). */
private struct Thumbnail: View {
    let entry: DriveEntry
    let tint: Color

    var body: some View {
        let kind = driveKind(entry.name, folder: entry.folder)
        let api = AppModel.shared.api
        switch kind {
        case .pdf, .image:
            AsyncImage(url: kind == .pdf ? api.driveThumbURL(entry) : api.driveFileURL(entry.path)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                } else {
                    icon(kind)
                }
            }
        default:
            icon(kind)
        }
    }

    private func icon(_ kind: DriveKind) -> some View {
        Image(systemName: kind == .folder ? "folder.fill" : driveIcon(kind)).font(.system(size: 40)).foregroundStyle(kind == .folder ? tint : .secondary)
    }
}

/** Text files larger than this aren't shown (opened in their app instead). */
private let textLimit: Int64 = 2 << 20

/** A file shown as itself: PDFs, images, video and audio, text and Markdown; Quick Look for the rest. */
struct FilePreview: View {
    let entry: DriveEntry
    @ObservedObject private var store = DriveStore.shared
    @State private var file: URL?
    @State private var text: String?
    @State private var image: NSImage?
    @State private var pdf: PDFDocument?
    @State private var player: AVPlayer?
    @State private var failed: String?
    /** A PDF written on here, live (see NotebookView). */
    @State private var writing = false

    private var kind: DriveKind { driveKind(entry.name, folder: false) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: driveIcon(kind)).foregroundStyle(.secondary)
                Text(entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(driveSize(entry.size)).font(.caption).foregroundStyle(.secondary)
                if driveReadOnly(entry.path) { Text("From PLMS · read-only").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if kind == .pdf && !driveReadOnly(entry.path) {
                    IconToggle("Write on It (live with your other devices)", symbol: "pencil.and.scribble", isOn: $writing)
                }
                IconButton("Open in Its App", symbol: "arrow.up.forward.app") { Task { await store.openExternally(entry) } }
                IconButton("Download to Downloads", symbol: "arrow.down.circle") { Task { await store.saveToDownloads(entry) } }
            }
            .padding(10)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDrag { DriveStore.provider(entry) }
        .task(id: entry) { await load() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder private var content: some View {
        if kind == .pdf && writing {
            NotebookView(path: entry.path).id(entry.path)
        } else if let failed {
            Text("Couldn't open this: \(failed)").foregroundStyle(.secondary)
        } else if let player {
            VideoPlayer(player: player)
        } else if let file {
            switch kind {
            case .pdf:
                if let pdf { PDFPreview(document: pdf) } else { QuickLookPreview(url: file) }
            case .image:
                if let image { ScrollView([.horizontal, .vertical]) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: image.size.width) }.padding() }
                else { QuickLookPreview(url: file) }
            case .video, .audio: QuickLookPreview(url: file)
            case .markdown, .text:
                if let text {
                    ScrollView {
                        Group {
                            if kind == .markdown, let md = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                                Text(md)
                            } else {
                                Text(text).font(.system(.body, design: .monospaced))
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                } else {
                    QuickLookPreview(url: file)
                }
            case .folder, .other: QuickLookPreview(url: file)
            }
        } else if (kind == .text || kind == .markdown) && entry.size > textLimit {
            Text("Too large to show here. Open it instead.").foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }

    private func load() async {
        file = nil; text = nil; image = nil; pdf = nil; failed = nil; writing = false
        player?.pause(); player = nil
        // Video and audio play as they arrive (the drive serves ranges): not downloaded first.
        if kind == .video || kind == .audio {
            player = AVPlayer(url: AppModel.shared.api.driveFileURL(entry.path))
            return
        }
        if (kind == .text || kind == .markdown) && entry.size > textLimit { return }
        do {
            let url = try await store.local(entry)
            // Read and decoded off the main thread, so other files can be picked meanwhile.
            let kind = kind
            let opened = await Task.detached(priority: .userInitiated) { () -> (String?, NSImage?, PDFDocument?) in
                switch kind {
                case .text, .markdown: ((try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)), nil, nil)
                case .image: (nil, NSImage(contentsOf: url), nil)
                case .pdf: (nil, nil, PDFDocument(url: url))
                default: (nil, nil, nil)
                }
            }.value
            guard !Task.isCancelled else { return }
            (text, image, pdf) = opened
            file = url
        } catch {
            if !Task.isCancelled { failed = error.localizedDescription }
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
