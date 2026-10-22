import Foundation
import UniformTypeIdentifiers

// The drive's API as the app and its extensions (Finder's, see DriveProvider) use it, and what a path is.

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
struct DriveInfo: Decodable {
    let enabled: Bool
    let url: String
    let username: String
}

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

    /** Where devices reach the drive over WebDAV (Finder's Connect to Server), and as whom. */
    func driveInfo() async throws -> DriveInfo {
        try JSONDecoder().decode(DriveInfo.self, from: try await drive("GET", ""))
    }

    func driveFolder(_ path: String) async throws -> [DriveEntry] {
        try JSONDecoder().decode(DriveFolderResponse.self, from: try await drive("GET", "/folder", ["path": path])).entries
    }

    /** A project's folder (made if needed). */
    func driveProjectFolder(_ projectId: String) async throws -> String {
        try JSONDecoder().decode(DriveFolderResponse.self, from: try await drive("GET", "/projects/\(projectId)")).path
    }

    /** Downloads [path] to [dest]; its version (ETag). */
    @discardableResult
    func driveDownload(_ path: String, to dest: URL) async throws -> String? {
        let (tmp, response) = try await URLSession.shared.download(for: URLRequest(url: driveFileURL(path), cachePolicy: .reloadIgnoringLocalCacheData))
        try check(response, Data())
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag").map(strongETag)
    }

    /**
     * Uploads [file] to [path] only if it's still version [ifMatch] (whatever's there without one);
     * its new version, or nil if it changed meanwhile.
     */
    func driveUpload(_ path: String, from file: URL, ifMatch: String?) async throws -> DriveWritten? {
        var req = URLRequest(url: driveFileURL(path))
        req.httpMethod = "PUT"
        req.setValue(UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let ifMatch { req.setValue(strongETag(ifMatch), forHTTPHeaderField: "If-Match") }
        let (out, response) = try await URLSession.shared.upload(for: req, fromFile: file)
        if (response as? HTTPURLResponse)?.statusCode == 412 { return nil }
        try check(response, out)
        return DriveWritten(etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag").map(strongETag))
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

    // ---- what's kept about files: starred, recently opened, where a PDF was left ----

    /** The starred files and folders' paths (a folder's ends with "/"). */
    func driveStarred() async throws -> [String] {
        try JSONDecoder().decode([FileStatePath].self, from: try await drive("GET", "/starred")).map(\.path)
    }

    /** The files opened most recently, latest first. */
    func driveRecent(_ limit: Int = 8) async throws -> [String] {
        try JSONDecoder().decode([FileStatePath].self, from: try await drive("GET", "/recent", ["limit": String(limit)])).map(\.path)
    }

    /**
     * Which document [path]'s live state is now (nil: none). Throws if the server can't be asked
     * (quickly: it's asked before opening what's kept).
     */
    func syncEpoch(_ path: String) async throws -> String?? {
        var c = URLComponents(url: base.appending(path: "api/v1/sync/epoch"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "doc", value: path)]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var req = URLRequest(url: c.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "no epoch") }
        return .some(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["epoch"] as? String)
    }

    /** Where a PDF was left: its page (from 0) and the tool in hand, if known. */
    func drivePlace(_ path: String) async throws -> (page: Int?, tool: String?) {
        let o = (try JSONSerialization.jsonObject(with: try await drive("GET", "/state", ["path": path]))) as? [String: Any] ?? [:]
        return (o["page"] as? Int, o["tool"] as? String)
    }

    /** Changes what's kept about [path] (what's given is set; the rest stays). */
    func driveChangeState(_ path: String, _ change: [String: Any]) async throws {
        try await drive("PATCH", "/state", ["path": path], body: try JSONSerialization.data(withJSONObject: change), type: "application/json")
    }

    /** A new note (or notebook page) for the class on now (or in [projectId]), in its project's Notes; where it is. */
    func quickNote(notebook: Bool, projectId: String? = nil) async throws -> String {
        var query = [URLQueryItem(name: "kind", value: notebook ? "notebook" : "note")]
        if let projectId { query.append(URLQueryItem(name: "projectId", value: projectId)) }
        var req = URLRequest(url: base.appending(path: "api/v1/quick-note").appending(queryItems: query))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try JSONDecoder().decode(FileStatePath.self, from: data).path
    }

    // ---- exports: notebooks, PDFs and notes as one PDF, to hand in ----

    /** [request]'s files as one PDF. */
    func driveExport(_ request: ExportRequest) async throws -> Data {
        try await drive("POST", "/export", body: try JSONEncoder().encode(request), type: "application/json", timeout: 300)
    }

    /** [request]'s files as one PDF, saved in the drive at [to] (numbered if taken); where it went. */
    func driveExportSave(_ request: ExportRequest, to: String) async throws -> String {
        try JSONDecoder().decode(FileStatePath.self, from: try await drive("POST", "/export/save", ["to": to], body: try JSONEncoder().encode(request), type: "application/json", timeout: 300)).path
    }

    // ---- course PDFs written on in a copy ----

    /** The copy of the course PDF at [path] to write on: the one made before, or a new one in the project's Notes. */
    func driveAnnotate(_ path: String) async throws -> Annotation {
        try JSONDecoder().decode(Annotation.self, from: try await drive("POST", "/annotate", ["path": path]))
    }

    /** What [path] is part of: a copy and its course file (updated since?), or a course file and its copy; nil: neither. */
    func driveAnnotation(_ path: String) async throws -> Annotation? {
        let data = try await drive("GET", "/annotation", ["path": path])
        return data.isEmpty ? nil : try JSONDecoder().decode(Annotation.self, from: data)
    }

    /** Carries the writing in the copy at [path] over to its course file's new version. */
    func driveCarryOver(_ path: String) async throws { _ = try await drive("POST", "/annotation/carry", ["path": path]) }

    /** Keeps the copy at [path] as it is (its course file's update let be). */
    func driveKeepAnnotation(_ path: String) async throws { _ = try await drive("POST", "/annotation/dismiss", ["path": path]) }

    // ---- the trash (deleting moves things there, kept 30 days) ----

    /** What's in the trash, latest first. */
    func driveTrash() async throws -> [Trashed] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = try? Date(s, strategy: .iso8601) { return date }
            return try Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return try decoder.decode([Trashed].self, from: try await drive("GET", "/trash"))
    }

    /** Puts [id] back where it was (numbered if that name's taken); where it went. */
    @discardableResult
    func driveRestore(_ id: String) async throws -> String {
        let out = try await drive("POST", "/trash/\(id)/restore")
        return ((try? JSONSerialization.jsonObject(with: out)) as? [String: Any])?["path"] as? String ?? ""
    }

    /** Deletes [id] from the trash for good. */
    func drivePurge(_ id: String) async throws { try await drive("DELETE", "/trash/\(id)") }

    /** Deletes everything in the trash for good. */
    func driveEmptyTrash() async throws { try await drive("DELETE", "/trash") }

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
    private func drive(_ method: String, _ endpoint: String, _ query: [String: String] = [:], body: Data? = nil, type: String? = nil, timeout: TimeInterval = 60) async throws -> Data {
        var req = URLRequest(url: driveURL(endpoint, query))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let type { req.setValue(type, forHTTPHeaderField: "Content-Type") }
        let (data, response) = if let body { try await URLSession.shared.upload(for: req, from: body) } else { try await URLSession.shared.data(for: req) }
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(code) else { return }
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
        throw APIError(message: detail ?? (code == 409 ? "Something is already called that" : "HTTP \(code)"), status: code)
    }
}

private struct FileStatePath: Decodable { let path: String }

/** What to export: files in order (a PDF's [pages] from 0; nil: all), after a cover if there's one. */
struct ExportRequest: Encodable {
    struct Item: Encodable { let path: String; let pages: [Int]? }
    struct Cover: Encodable { let title: String; let subtitle: String?; let author: String?; let date: String? }
    let items: [Item]
    let cover: Cover?
}

/** A copy of a course file to write on: where it is, the course file, and whether that's been updated since. */
struct Annotation: Decodable, Equatable {
    let copy: String
    let source: String
    let sourceChanged: Bool
}

/** Something in the trash: where it was ([path]; a folder's ends with "/"), and when it was deleted. */
struct Trashed: Decodable, Identifiable, Hashable {
    let id: String
    let path: String
    let name: String
    let folder: Bool
    let size: Int64
    let deletedAt: Date
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

func driveParts(_ path: String) -> [Substring] { path.split(separator: "/") }

/** In a project's Course files (what PLMS has, kept as it is there; copy one out to change it), or that folder itself. */
func driveReadOnly(_ path: String) -> Bool {
    let p = driveParts(path)
    return p.count >= 3 && p[0] == "Projects" && p[2] == "Course files"
}

/** Not renamed, moved or deleted from here: Projects/, project folders (they follow their projects), course files. */
func driveFixed(_ path: String) -> Bool { (path.hasPrefix("Projects/") && driveParts(path).count <= 2) || driveReadOnly(path) }

/** The folder a path is in. */
func driveParent(_ path: String) -> String {
    let p = driveParts(path)
    return p.count <= 1 ? "" : p.dropLast().joined(separator: "/") + "/"
}

func driveSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

extension UTType {
    /** A drive entry dragged within the app (its path). */
    static let driveItem = UTType(importedAs: "com.syeyoung.assistant.drive-item")
}

