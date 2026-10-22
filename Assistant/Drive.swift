import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// ---- The drive as the app shows it ----------------------------------------------------

/** Folders as last listed, what's copied or cut, and the changes made from here. */
@MainActor
final class DriveStore: ObservableObject {
    static let shared = DriveStore()

    /** Copies just made to write on: they open ready to write. */
    var writeOnOpen = Set<String>()

    @Published private(set) var children: [String: [DriveEntry]] = [:]
    @Published private(set) var entries: [String: DriveEntry] = [:]
    @Published var error: String?
    /** Copied or cut, to paste into another folder. */
    @Published var clip: (path: String, cut: Bool)?
    /** Starred files and folders, and the files opened lately (latest first): at the top of Files. */
    @Published private(set) var starred: [String] = []
    @Published private(set) var recent: [String] = []

    /** Starred and recent, as the server has them now. */
    func loadQuick() async {
        if let s = try? await api.driveStarred() { starred = s }
        if let r = try? await api.driveRecent(8) { recent = r }
    }

    func star(_ path: String, _ on: Bool) async {
        starred = on ? (starred + [path]).sorted() : starred.filter { $0 != path }
        try? await api.driveChangeState(path, ["starred": on])
        await loadQuick()
    }

    /** [path] was opened (for Recent). */
    func opened(_ path: String) {
        Task {
            try? await api.driveChangeState(path, ["opened": true])
            await loadQuick()
        }
    }

    private var api: API { AppModel.shared.api }
    private var loading: Set<String> = []

    func load(_ folder: String) async {
        guard !loading.contains(folder) else { return }
        loading.insert(folder)
        defer { loading.remove(folder) }
        do {
            let list = try await api.driveFolder(folder)
            children[folder] = list
            for e in list { entries[e.path] = e }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /** Lists [folder] if it hasn't been yet. */
    func ensure(_ folder: String) {
        if children[folder] == nil { Task { await load(folder) } }
    }

    /** Lists again every folder shown. */
    func reloadAll() async {
        for f in children.keys { await load(f) }
    }

    /** A local copy of a file (downloaded once per version), to show or hand to other apps. */
    func local(_ e: DriveEntry) async throws -> URL {
        let key = SHA256.hash(data: Data("\(e.path)|\(e.modified ?? "")".utf8)).map { String(format: "%02x", $0) }.joined().prefix(20)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Assistant/drive/\(key)")
        let file = dir.appending(path: e.name)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await api.driveDownload(e.path, to: file)
        return file
    }

    // ---- changes (each lists the folders it touched again) ----

    private func run(_ folders: [String], _ change: () async throws -> Void) async {
        do { try await change() } catch { self.error = error.localizedDescription }
        for f in Set(folders) { await load(f) }
        DriveDomain.changed()
    }

    /** Puts [path] into [folder]: moved, or copied ([copy], or always for course files). */
    func put(_ path: String, into folder: String, copy: Bool) async {
        guard !driveReadOnly(folder), !folder.hasPrefix(path) else { return }
        let name = String(driveParts(path).last ?? "")
        let to = folder + name + (path.hasSuffix("/") ? "/" : "")
        if copy || driveFixed(path) {
            await run([folder]) { try await api.driveCopy(path, to) }
        } else if driveParent(path) != folder {
            await run([folder, driveParent(path)]) { try await api.driveMove(path, to) }
        }
    }

    func paste(into folder: String) async {
        guard let c = clip else { return }
        await put(c.path, into: folder, copy: !c.cut)
        if c.cut { clip = nil }
    }

    func duplicate(_ e: DriveEntry) async {
        await run([driveParent(e.path)]) { try await api.driveCopy(e.path, e.path) }
    }

    func rename(_ e: DriveEntry, to name: String) async {
        let clean = name.replacingOccurrences(of: "/", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != e.name else { return }
        let parent = driveParent(e.path)
        await run([parent]) { try await api.driveMove(e.path, parent + clean + (e.folder ? "/" : "")) }
    }

    func delete(_ e: DriveEntry) async {
        await run([driveParent(e.path)]) { try await api.driveDelete(e.path) }
        if clip?.path == e.path { clip = nil }
    }

    func makeFolder(_ name: String, in folder: String) async {
        let clean = name.replacingOccurrences(of: "/", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        await run([folder]) { try await api.driveMakeFolder(folder + clean + "/") }
    }

    /** A new, empty Markdown file in [folder] ("Untitled.md", numbered if taken); its path. */
    func newMarkdown(in folder: String) async -> String? {
        var made: String?
        await run([folder]) {
            made = try await api.driveCreate(folder + "Untitled.md") { try await api.driveWriteNew($0, Data(), type: "text/markdown; charset=utf-8") }
        }
        return made
    }

    /** Uploads files (and folders, with what's in them) from this Mac into [folder]. */
    func upload(_ urls: [URL], into folder: String) async {
        guard !driveReadOnly(folder) else { return }
        await run([folder]) {
            for url in urls {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // Numbered if the name's taken: never over a file that's there.
                if !isDir {
                    try await api.driveCreate(folder + url.lastPathComponent) { try await api.driveUpload($0, from: url) }
                    continue
                }
                let base = url.deletingLastPathComponent().path + "/"
                try await api.driveMakeFolder(folder + url.lastPathComponent + "/")
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let f = files?.nextObject() as? URL {
                    guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    try await api.driveCreate(folder + f.path.dropFirst(base.count)) { try await api.driveUpload($0, from: f) }
                }
            }
        }
    }

    /** Downloads into ~/Downloads and shows it in Finder. */
    func saveToDownloads(_ e: DriveEntry) async {
        do {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            var dest = downloads.appending(path: e.name)
            var n = 2
            let stem = (e.name as NSString).deletingPathExtension, ext = (e.name as NSString).pathExtension
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = downloads.appending(path: ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
                n += 1
            }
            try FileManager.default.copyItem(at: try await local(e), to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            self.error = error.localizedDescription
        }
    }

    /**
     * Opens [e] in its app from the drive in Finder (Assistant, the File Provider): what that app
     * saves goes to the drive. With Assistant off in Finder, a copy kept here opens instead.
     */
    func openExternally(_ e: DriveEntry) async {
        do {
            NSWorkspace.shared.open(try await DriveDomain.url(for: e.path))
        } catch {
            do { NSWorkspace.shared.open(try await local(e)) } catch { self.error = error.localizedDescription }
        }
    }

    /** What a drag of [e] carries: its path (for here) and, for files, the file itself (for Finder and other apps). */
    nonisolated static func provider(_ e: DriveEntry) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = e.name
        p.registerDataRepresentation(forTypeIdentifier: UTType.driveItem.identifier, visibility: .ownProcess) { done in
            done(Data(e.path.utf8), nil)
            return nil
        }
        if !e.folder {
            let type = UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data
            p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
                Task { @MainActor in
                    do { done(try await DriveStore.shared.local(e), false, nil) } catch { done(nil, false, error) }
                }
                return nil
            }
        }
        return p
    }

    /** Takes a drop into [folder]: drive entries moved (copied with ⌥), files from elsewhere uploaded. */
    func accept(_ providers: [NSItemProvider], into folder: String) -> Bool {
        guard !driveReadOnly(folder) else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.driveItem.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.driveItem.identifier) { data, _ in
                    guard let data, let path = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in await DriveStore.shared.put(path, into: folder, copy: copy) }
                }
            } else if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in await DriveStore.shared.upload([url], into: folder) }
                }
            }
        }
        return true
    }
}
