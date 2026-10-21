import FileProvider

/**
 * A folder's contents for Finder, or (the working set) every folder Finder has listed. Changes are
 * what a listing now shows against the one before: the drive keeps no history to ask.
 */
final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let provider: Provider

    init(_ container: NSFileProviderItemIdentifier, provider: Provider) {
        self.container = container
        self.provider = provider
    }

    func invalidate() {}

    /** The folders this enumerator covers. */
    private func folders() throws -> [String] {
        if container == .workingSet { return provider.store.folders }
        guard let path = provider.store.path(for: container) else { throw NSFileProviderError(.noSuchItem) }
        return [path]
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                var items: [NSFileProviderItem] = []
                for folder in try folders() {
                    let entries = try await provider.api.driveFolder(folder)
                    provider.store.listed(folder, entries)
                    items += entries.map { provider.item(Store.DriveEntryRecord($0)) }
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(Provider.fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                var updated: [NSFileProviderItem] = []
                var deleted: [NSFileProviderItemIdentifier] = []
                for folder in try folders() {
                    let entries: [DriveEntry]
                    do {
                        entries = try await provider.api.driveFolder(folder)
                    } catch let e as APIError where e.status == 404 {
                        // The folder itself went (it's told as gone where it was listed).
                        continue
                    }
                    let before = provider.store.listed(folder, entries)
                    let now = Dictionary(entries.map { ($0.path, Store.DriveEntryRecord($0)) }, uniquingKeysWith: { a, _ in a })
                    for (path, entry) in now where before[path] != entry { updated.append(provider.item(entry)) }
                    for path in before.keys where now[path] == nil {
                        deleted.append(provider.store.id(for: path))
                        provider.store.gone(path)
                    }
                }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                if !updated.isEmpty { observer.didUpdate(updated) }
                observer.finishEnumeratingChanges(upTo: Self.anchor(), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(Provider.fileProviderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.anchor())
    }

    /** Now: changes are always worked out afresh, so the anchor only has to move on. */
    private static func anchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
    }
}
