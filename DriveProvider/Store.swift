import FileProvider
import Foundation

/**
 * What Finder's copy of the drive is kept against. The drive (WebDAV) has no ids of its own, only
 * paths, and File Provider needs an item to keep its identifier when renamed or moved: each path is
 * given one here, which follows it when it's renamed or moved from Finder. (Moved elsewhere, it's a
 * new item to Finder: the old one goes, the new one comes.) And each folder Finder has listed, as it
 * was then, to tell what's changed since.
 */
final class Store: @unchecked Sendable {
    private struct Saved: Codable {
        var ids: [String: String] = [:]
        var folders: [String: [String: DriveEntryRecord]] = [:]
    }

    /** A listed entry as kept (DriveEntry isn't Codable for writing). */
    struct DriveEntryRecord: Codable, Equatable {
        let path: String, name: String, folder: Bool, size: Int64, modified: String?, contentType: String?, etag: String?

        init(_ e: DriveEntry) {
            path = e.path; name = e.name; folder = e.folder; size = e.size; modified = e.modified; contentType = e.contentType; etag = e.etag
        }
    }

    private let file: URL
    private let lock = NSLock()
    private var saved: Saved
    /** Path by id, the other way round. */
    private var paths: [String: String] = [:]

    init(domain: NSFileProviderDomain) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "DriveProvider", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "\(domain.identifier.rawValue).json")
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))) ?? Saved()
        for (path, id) in saved.ids { paths[id] = path }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }

    /** The id for [path] (made if new); the root is the root container. */
    func id(for path: String) -> NSFileProviderItemIdentifier {
        if path.isEmpty { return .rootContainer }
        lock.lock(); defer { lock.unlock() }
        if let id = saved.ids[path] { return NSFileProviderItemIdentifier(id) }
        let id = UUID().uuidString
        saved.ids[path] = id
        paths[id] = path
        save()
        return NSFileProviderItemIdentifier(id)
    }

    /** The path for [id]; nil if it isn't known (anymore). */
    func path(for id: NSFileProviderItemIdentifier) -> String? {
        if id == .rootContainer { return "" }
        lock.lock(); defer { lock.unlock() }
        return paths[id.rawValue]
    }

    /** [from] moved to [to] (from Finder): it, and what's in it, keep their ids. */
    func moved(_ from: String, to: String) {
        lock.lock(); defer { lock.unlock() }
        for (path, id) in saved.ids where path == from || (from.hasSuffix("/") && path.hasPrefix(from)) {
            let now = to + path.dropFirst(from.count)
            saved.ids[path] = nil
            saved.ids[now] = id
            paths[id] = now
        }
        for (folder, entries) in saved.folders where folder == from || (from.hasSuffix("/") && folder.hasPrefix(from)) {
            saved.folders[folder] = nil
            saved.folders[to + folder.dropFirst(from.count)] = entries
        }
        save()
    }

    /** [path] is gone: it (and what's in it) forgotten. */
    func gone(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        for (p, id) in saved.ids where p == path || (path.hasSuffix("/") && p.hasPrefix(path)) {
            saved.ids[p] = nil
            paths[id] = nil
        }
        for folder in saved.folders.keys where folder == path || (path.hasSuffix("/") && folder.hasPrefix(path)) { saved.folders[folder] = nil }
        save()
    }

    // ---- folders as last listed ----

    /** [folder] as just listed; what was there before. */
    @discardableResult
    func listed(_ folder: String, _ entries: [DriveEntry]) -> [String: DriveEntryRecord] {
        lock.lock(); defer { lock.unlock() }
        let before = saved.folders[folder] ?? [:]
        saved.folders[folder] = Dictionary(entries.map { ($0.path, DriveEntryRecord($0)) }, uniquingKeysWith: { a, _ in a })
        save()
        return before
    }

    /** The folders Finder has listed. */
    var folders: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(saved.folders.keys)
    }

    /** [path]'s entry as last listed. */
    func entry(_ path: String) -> DriveEntryRecord? {
        lock.lock(); defer { lock.unlock() }
        return saved.folders[driveParent(path)]?[path]
    }

    /** [entry] as it is now (after a change made from here). */
    func update(_ entry: DriveEntryRecord) {
        lock.lock(); defer { lock.unlock() }
        saved.folders[driveParent(entry.path)]?[entry.path] = entry
        save()
    }
}
