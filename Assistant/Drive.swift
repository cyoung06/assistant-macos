import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/** A file or folder in the drive; [path] is from its root, folders end with "/". */
struct DriveEntry: Decodable, Hashable, Identifiable {
    let path: String
    let name: String
    let folder: Bool
    let size: Int64
    let modified: String?
    let contentType: String?
    /** Its version, sent back as If-Match when writing a note (absent from older servers). */
    let etag: String?
    var id: String { path }
}

private struct DriveFolderResponse: Decodable {
    let path: String
    let entries: [DriveEntry]
}

/** The drive, through the API (it reaches the WebDAV server for us). */
extension API {
    func driveURL(_ endpoint: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appending(path: "api/v1/drive" + endpoint), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // URLComponents leaves "+" as it is, which servers read as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    func driveFileURL(_ path: String) -> URL { driveURL("/file", ["path": path]) }
    func driveThumbURL(_ e: DriveEntry, width: Int = 240) -> URL { driveURL("/thumb", ["path": e.path, "version": e.modified ?? "", "width": String(width)]) }

    func driveFolder(_ path: String) async throws -> [DriveEntry] {
        try JSONDecoder().decode(DriveFolderResponse.self, from: try await drive("GET", "/folder", ["path": path])).entries
    }

    /** A project's folder (made if needed). */
    func driveProjectFolder(_ projectId: String) async throws -> String {
        try JSONDecoder().decode(DriveFolderResponse.self, from: try await drive("GET", "/projects/\(projectId)")).path
    }

    func driveDownload(_ path: String, to dest: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: driveFileURL(path))
        try check(response, Data())
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /** Uploads [file] to [path] if there's nothing there (If-None-Match: *); false if there is. */
    func driveUpload(_ path: String, from file: URL) async throws -> Bool {
        var req = URLRequest(url: driveFileURL(path))
        req.httpMethod = "PUT"
        req.setValue(UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (data, response) = try await URLSession.shared.upload(for: req, fromFile: file)
        if (response as? HTTPURLResponse)?.statusCode == 412 { return false }
        try check(response, data)
        return true
    }

    /** Writes [data] to [path] if there's nothing there (If-None-Match: *); false if there is. */
    func driveWriteNew(_ path: String, _ data: Data, type: String) async throws -> Bool {
        var req = URLRequest(url: driveFileURL(path))
        req.httpMethod = "PUT"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (out, response) = try await URLSession.shared.upload(for: req, from: data)
        if (response as? HTTPURLResponse)?.statusCode == 412 { return false }
        try check(response, out)
        return true
    }

    /**
     * A new file at [path], or "stem (2).ext" and so on if that's taken, never over a file that's
     * there: [put] writes it to the path it's given, false if something's there (the next name is
     * tried). Where it went.
     */
    func driveCreate(_ path: String, _ put: (String) async throws -> Bool) async throws -> String {
        let folder = driveParent(path), name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...100 {
            let at = folder + (n == 1 ? name : ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if try await put(at) { return at }
        }
        throw APIError(message: "No free name for \(name)")
    }

    func driveWrite(_ path: String, _ data: Data, type: String) async throws { try await drive("PUT", "/file", ["path": path], body: data, type: type) }
    func driveMakeFolder(_ path: String) async throws { try await drive("POST", "/folder", ["path": path]) }
    func driveMove(_ from: String, _ to: String) async throws { try await drive("POST", "/move", ["from": from, "to": to]) }
    func driveDelete(_ path: String) async throws { try await drive("DELETE", "/file", ["path": path]) }

    /** Copies to [to], numbered if that's taken; where the copy went. */
    @discardableResult
    func driveCopy(_ from: String, _ to: String) async throws -> String {
        let out = try await drive("POST", "/copy", ["from": from, "to": to])
        return ((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])?["path"] as? String ?? to
    }

    // ---- notes: reads and writes that know the file's version ----

    /** A file's contents, type and version (ETag); nil if it's still [ifNoneMatch]. */
    func driveRead(_ path: String, ifNoneMatch: String? = nil) async throws -> (data: Data, etag: String?, type: String?)? {
        var req = URLRequest(url: driveFileURL(path), cachePolicy: .reloadIgnoringLocalCacheData)
        if let ifNoneMatch { req.setValue(strongETag(ifNoneMatch), forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return nil }
        try check(response, data)
        return (data, http?.value(forHTTPHeaderField: "ETag").map(strongETag), http?.value(forHTTPHeaderField: "Content-Type"))
    }

    /** Writes a file only if it's still version [ifMatch] (any version without one); its new version, or nil on a conflict. */
    func driveWrite(_ path: String, _ data: Data, type: String, ifMatch: String?) async throws -> DriveWritten? {
        var req = URLRequest(url: driveFileURL(path))
        req.httpMethod = "PUT"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        if let ifMatch { req.setValue(strongETag(ifMatch), forHTTPHeaderField: "If-Match") }
        let (out, response) = try await URLSession.shared.upload(for: req, from: data)
        if (response as? HTTPURLResponse)?.statusCode == 412 { return nil }
        try check(response, out)
        if let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") { return DriveWritten(etag: strongETag(etag)) }
        // Older servers don't say: the listing does.
        let listed = try? await driveFolder(driveParent(path)).first { $0.path == path }
        return DriveWritten(etag: listed?.etag.map(strongETag))
    }

    @discardableResult
    private func drive(_ method: String, _ endpoint: String, _ query: [String: String] = [:], body: Data? = nil, type: String? = nil) async throws -> Data {
        var req = URLRequest(url: driveURL(endpoint, query))
        req.httpMethod = method
        if let type { req.setValue(type, forHTTPHeaderField: "Content-Type") }
        let (data, response) = if let body { try await URLSession.shared.upload(for: req, from: body) } else { try await URLSession.shared.data(for: req) }
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(code) else { return }
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
        throw APIError(message: detail ?? (code == 409 ? "Something is already called that" : "HTTP \(code)"))
    }
}

/** A write that went through: the file's new version, if known. */
struct DriveWritten { let etag: String? }

/** An ETag as the file's own: a compressing proxy on the way marks them weak ("W/"). */
func strongETag(_ etag: String) -> String { etag.hasPrefix("W/") ? String(etag.dropFirst(2)) : etag }

// ---- What a path is ---------------------------------------------------------------------

enum DriveKind { case folder, pdf, image, video, audio, markdown, text, other }

func driveKind(_ name: String, folder: Bool) -> DriveKind {
    if folder { return .folder }
    switch (name as NSString).pathExtension.lowercased() {
    case "pdf": return .pdf
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg": return .image
    case "mp4", "mov", "m4v", "webm": return .video
    case "mp3", "m4a", "wav", "aac", "flac", "ogg": return .audio
    case "md", "markdown": return .markdown
    case "txt", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "log", "tex", "bib", "sh", "py", "ipynb",
         "c", "h", "cc", "cpp", "hpp", "java", "kt", "kts", "js", "jsx", "ts", "tsx", "rs", "go", "rb", "swift", "sql", "m", "r", "ini", "conf":
        return .text
    default: return .other
    }
}

func driveIcon(_ kind: DriveKind) -> String {
    switch kind {
    case .folder: "folder"
    case .pdf: "doc.richtext"
    case .image: "photo"
    case .video: "film"
    case .audio: "waveform"
    case .markdown: "doc.text"
    case .text: "chevron.left.forwardslash.chevron.right"
    case .other: "doc"
    }
}

private func parts(_ path: String) -> [Substring] { path.split(separator: "/") }

/** In a project's Course files (what PLMS has, kept as it is there; copy one out to change it), or that folder itself. */
func driveReadOnly(_ path: String) -> Bool {
    let p = parts(path)
    return p.count >= 3 && p[0] == "Projects" && p[2] == "Course files"
}

/** Not renamed, moved or deleted from here: Projects/, project folders (they follow their projects), course files. */
func driveFixed(_ path: String) -> Bool { (path.hasPrefix("Projects/") && parts(path).count <= 2) || driveReadOnly(path) }

/** The folder a path is in. */
func driveParent(_ path: String) -> String {
    let p = parts(path)
    return p.count <= 1 ? "" : p.dropLast().joined(separator: "/") + "/"
}

func driveSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

extension UTType {
    /** A drive entry dragged within the app (its path). */
    static let driveItem = UTType(importedAs: "com.syeyoung.assistant.drive-item")
}

// ---- The drive as the app shows it ----------------------------------------------------

/** Folders as last listed, what's copied or cut, and the changes made from here. */
@MainActor
final class DriveStore: ObservableObject {
    static let shared = DriveStore()

    @Published private(set) var children: [String: [DriveEntry]] = [:]
    @Published private(set) var entries: [String: DriveEntry] = [:]
    @Published var error: String?
    /** Copied or cut, to paste into another folder. */
    @Published var clip: (path: String, cut: Bool)?

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
    }

    /** Puts [path] into [folder]: moved, or copied ([copy], or always for course files). */
    func put(_ path: String, into folder: String, copy: Bool) async {
        guard !driveReadOnly(folder), !folder.hasPrefix(path) else { return }
        let name = String(parts(path).last ?? "")
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

    /** Opens a copy in the app that handles it. */
    func openExternally(_ e: DriveEntry) async {
        do { NSWorkspace.shared.open(try await local(e)) } catch { self.error = error.localizedDescription }
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
