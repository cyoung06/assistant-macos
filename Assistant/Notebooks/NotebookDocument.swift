import Foundation

/**
 * A notebook (a PDF written on with a pen) as every device has it at once: the shared core's
 * [NotebookDoc] kept in step with the API's (see [LiveConnection]), which writes the PDF. Edits made
 * here go out as they're made ([edit]); others' come in through [changed], on the main actor, as the
 * document takes them. [status] hears "connecting", "live", "offline", or "error" with why.
 */
@MainActor
final class NotebookDocument {
    let path: String
    /** Others' changes, once the notebook is open. */
    var changed: ((_ changes: [NotebookChange]) -> Void)?
    var status: (_ state: String, _ message: String?) -> Void = { _, _ in }

    /** As this Mac last had it (opened from at once, offline too; see [LiveCache]). */
    private let cache: LiveCache
    /** Replaced (before connecting) if what's kept turns out to be another document's. */
    private var doc: NotebookDoc
    private var saving: Task<Void, Never>?

    /** Which document what's kept is: noted once the server's is here. */
    private func keepEpoch() {
        Task { [path, cache] in
            if let now = try? await AppModel.shared.api.syncEpoch(path), let now { cache.epoch = now }
        }
    }

    /** Keeps the notebook on this Mac a moment after it changes (here or elsewhere). */
    private func keepSoon() {
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cache.save(self.doc.state())
        }
    }
    private var opened: CheckedContinuation<Void, Error>?
    private var isOpened = false
    private var connection: LiveConnection!

    init(path: String) {
        self.path = path
        cache = LiveCache(path: path)
        doc = cache.load().flatMap { try? NotebookDoc.fromState(state: $0) } ?? NotebookDoc()
        connection = LiveConnection(path: path, greeting: { [weak self] in self?.doc.start() ?? Data() }, receive: { [weak self] in try self?.receive($0) }) { [weak self] state, message in
            guard let self else { return }
            if state == "error" {
                // Moved or deleted: what's kept here is no one's now.
                self.cache.forget()
                if let c = self.opened {
                    self.opened = nil
                    c.resume(throwing: APIError(message: message ?? "This notebook can't be opened"))
                }
            }
            if state != "live" || self.isOpened { self.status(state, message) }
        }
    }

    private func receive(_ bytes: Data) throws -> Data? {
        let got = try doc.receive(message: bytes)
        if isOpened, !got.changes.isEmpty { changed?(got.changes) }
        if !got.changes.isEmpty { keepSoon() }
        if LiveConnection.isSyncStep2(bytes) { keepEpoch() }
        if let c = opened, LiveConnection.isSyncStep2(bytes) {
            opened = nil
            isOpened = true
            c.resume()
            status("live", nil)
        }
        return got.reply
    }

    /** Once the notebook is here from the server. */
    /**
     * Once the notebook is here: at once if it's kept on this Mac (connecting meanwhile, what's changed
     * since coming in as it does), else when the server has sent it.
     */
    func open() async throws {
        // What's kept is used only while it's still this path's document (not one deleted since and made again).
        if !(await cache.stillCurrent(path)) {
            cache.forget()
            doc = NotebookDoc()
        }
        let base = doc.base()
        if !doc.pages().isEmpty, base.isEmpty || FileManager.default.fileExists(atPath: Self.blobFile(base).path) {
            isOpened = true
            connection.connect()
            return
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            opened = c
            connection.connect()
        }
    }

    var pages: [NotebookPage] { doc.pages() }
    var strokes: [NotebookStroke] { doc.strokes() }
    var images: [NotebookImage] { doc.images() }
    /** The bookmarked pages' ids. */
    var bookmarks: [String] { doc.bookmarks() }
    /** The base PDF's hash (see [blob]). */
    var base: String { doc.base() }

    func edit(_ edits: [NotebookEdit]) {
        guard !edits.isEmpty else { return }
        connection.send(doc.edit(edits: edits))
        keepSoon()
    }

    func close() async {
        saving?.cancel()
        cache.save(doc.state())
        await connection.close()
    }

    /** Where a blob is kept: with the live documents (not in Caches, which macOS may clear), for opening offline. */
    static func blobFile(_ hash: String) -> URL { LiveCache.folder.appending(path: "notebook-blobs/\(hash)") }

    /** A file the server keeps by its hash (the base PDF, pictures): fetched once, then kept. */
    static func blob(_ hash: String) async throws -> Data {
        let file = blobFile(hash)
        let dir = file.deletingLastPathComponent()
        if let data = try? Data(contentsOf: file) { return data }
        let api = AppModel.shared.api
        let (data, response) = try await URLSession.shared.data(from: api.base.appending(path: "api/v1/sync/blobs/\(hash)"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "Couldn't fetch the notebook's file") }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
