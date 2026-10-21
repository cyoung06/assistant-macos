import FileProvider
import UniformTypeIdentifiers

/**
 * The drive in Finder ("Assistant", like iCloud Drive): folders listed as they're opened, files
 * downloaded when opened and uploaded when saved, through the API (as the app's Files view does).
 * Course files only read; a save that meets a newer version on the drive doesn't overwrite it: it's
 * kept beside it as "name (conflict).ext".
 */
final class Provider: NSObject, NSFileProviderReplicatedExtension {
    let store: Store
    let api = API(base: URL(string: Defaults.server)!)

    required init(domain: NSFileProviderDomain) {
        store = Store(domain: domain)
        super.init()
    }

    func invalidate() {}

    /** [entry] as Finder sees it. */
    func item(_ entry: Store.DriveEntryRecord) -> Item {
        Item(entry, id: store.id(for: entry.path), parent: store.id(for: driveParent(entry.path)))
    }

    /** [path]'s entry: as last listed, or listed now. */
    private func entry(_ path: String) async throws -> Store.DriveEntryRecord {
        if let e = store.entry(path) { return e }
        return try await relisted(path)
    }

    /** [path]'s entry, its folder listed again (after a change made from here). */
    private func relisted(_ path: String) async throws -> Store.DriveEntryRecord {
        let folder = driveParent(path)
        let entries = try await api.driveFolder(folder)
        store.listed(folder, entries)
        guard let e = entries.first(where: { $0.path == path }) else { throw NSFileProviderError(.noSuchItem) }
        return Store.DriveEntryRecord(e)
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run(completionHandler) {
            if identifier == .rootContainer { return Item.root() }
            guard let path = self.store.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
            return self.item(try await self.entry(path))
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard let path = store.path(for: itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                let etag = try await api.driveDownload(path, to: dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                let had = try await entry(path)
                let now = Store.DriveEntryRecord(DriveEntry(path: path, name: had.name, folder: false, size: size, modified: had.modified, contentType: had.contentType, etag: etag ?? had.etag))
                store.update(now)
                progress.completedUnitCount = 1
                completionHandler(dest, item(now), nil)
            } catch {
                completionHandler(nil, nil, Self.fileProviderError(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard let parent = store.path(for: itemTemplate.parentItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                if driveReadOnly(parent) { throw NSFileProviderError(.cannotSynchronize) }
                let folder = itemTemplate.contentType?.conforms(to: .folder) == true
                let name = itemTemplate.filename.replacingOccurrences(of: "/", with: " ")
                var path = parent + name + (folder ? "/" : "")
                // Finder re-importing what's already there: the same item, not a second one.
                if options.contains(.mayAlreadyExist), let there = try? await relisted(path) {
                    completionHandler(item(there), [], false, nil)
                    return
                }
                if folder {
                    try await api.driveMakeFolder(path)
                } else if let url {
                    path = try await api.driveCreate(path) { at in try await self.api.driveUpload(at, from: url) }
                } else {
                    path = try await api.driveCreate(path) { at in try await self.api.driveWriteNew(at, Data(), type: "application/octet-stream") }
                }
                progress.completedUnitCount = 1
                completionHandler(item(try await relisted(path)), [], false, nil)
            } catch {
                completionHandler(nil, [], false, Self.fileProviderError(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard var path = store.path(for: item.itemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                let folder = path.hasSuffix("/")
                // Renamed or moved.
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    guard let parent = store.path(for: item.parentItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
                    let to = parent + item.filename.replacingOccurrences(of: "/", with: " ") + (folder ? "/" : "")
                    if to != path {
                        try await api.driveMove(path, to)
                        store.moved(path, to: to)
                        path = to
                    }
                }
                // Saved: only over the version it was opened as; otherwise kept beside the newer one.
                var refetch = false
                if changedFields.contains(.contents), let newContents, !folder {
                    let base = String(decoding: version.contentVersion, as: UTF8.self)
                    let etag = store.entry(path)?.etag ?? (base.contains("@") ? nil : base)
                    if try await api.driveUpload(path, from: newContents, ifMatch: etag) == nil {
                        let name = (path as NSString).lastPathComponent
                        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                        let conflict = driveParent(path) + stem + " (conflict)" + (ext.isEmpty ? "" : ".\(ext)")
                        _ = try await api.driveCreate(conflict) { at in try await self.api.driveUpload(at, from: newContents) }
                        refetch = true
                    }
                }
                progress.completedUnitCount = 1
                completionHandler(self.item(try await relisted(path)), [], refetch, nil)
            } catch {
                completionHandler(nil, [], false, Self.fileProviderError(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard let path = store.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
                if driveFixed(path) { throw NSFileProviderError(.deletionRejected) }
                try await api.driveDelete(path)
                store.gone(path)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(Self.fileProviderError(error))
            }
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        if containerItemIdentifier != .workingSet && store.path(for: containerItemIdentifier) == nil { throw NSFileProviderError(.noSuchItem) }
        return Enumerator(containerItemIdentifier, provider: self)
    }

    // ---- errors ----

    /** [work]'s item to [done], or its error as File Provider's. */
    private func run(_ done: @escaping (NSFileProviderItem?, Error?) -> Void, _ work: @escaping () async throws -> NSFileProviderItem) -> Progress {
        Task {
            do { done(try await work(), nil) } catch { done(nil, Self.fileProviderError(error)) }
        }
        return Progress()
    }

    /** As File Provider understands it: gone, unreachable, or what it was. */
    static func fileProviderError(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if let e = error as? APIError, e.status == 404 { return NSFileProviderError(.noSuchItem) }
        if error is URLError { return NSFileProviderError(.serverUnreachable) }
        return error
    }
}
