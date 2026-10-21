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

    private let doc = NotebookDoc()
    private var opened: CheckedContinuation<Void, Error>?
    private var isOpened = false
    private var connection: LiveConnection!

    init(path: String) {
        self.path = path
        connection = LiveConnection(path: path, greeting: { [doc] in doc.start() }, receive: { [weak self] in try self?.receive($0) }) { [weak self] state, message in
            guard let self else { return }
            if state == "error", let c = self.opened {
                self.opened = nil
                c.resume(throwing: APIError(message: message ?? "This notebook can't be opened"))
            }
            if state != "live" || self.isOpened { self.status(state, message) }
        }
    }

    private func receive(_ bytes: Data) throws -> Data? {
        let got = try doc.receive(message: bytes)
        if isOpened, !got.changes.isEmpty { changed?(got.changes) }
        if let c = opened, LiveConnection.isSyncStep2(bytes) {
            opened = nil
            isOpened = true
            c.resume()
            status("live", nil)
        }
        return got.reply
    }

    /** Once the notebook is here from the server. */
    func open() async throws {
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
    }

    func close() async {
        await connection.close()
    }

    /** A file the server keeps by its hash (the base PDF, pictures): fetched once, then from the cache. */
    static func blob(_ hash: String) async throws -> Data {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "notebook-blobs")
        let file = dir.appending(path: hash)
        if let data = try? Data(contentsOf: file) { return data }
        let api = AppModel.shared.api
        let (data, response) = try await URLSession.shared.data(from: api.base.appending(path: "api/v1/sync/blobs/\(hash)"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(message: "Couldn't fetch the notebook's file") }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
