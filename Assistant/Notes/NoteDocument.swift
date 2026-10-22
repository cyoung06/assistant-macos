import Foundation

/**
 * A note as every device has it at once: a Yjs document ([SyncDoc], the shared core's) kept in step
 * with the API's (see [LiveConnection]), which writes the file.
 * Edits typed here go out as they're made ([edited]); others' come in through [remote], on the main
 * actor, as the document takes them (so the editor's text and the document's never drift apart).
 * Course files only read. [status] hears "loading", "live", "connecting", "offline", "readonly", or
 * "error" with why.
 */
@MainActor
final class NoteDocument {
    let path: String
    let readOnly: Bool
    private let status: (_ state: String, _ message: String?) -> Void
    private let remote: (_ changes: [TextChange]) -> Void
    private var api: API { AppModel.shared.api }

    /** As this Mac last had it (opened from at once, offline too; see [LiveCache]). */
    private let cache: LiveCache
    private let doc: SyncDoc
    private var opened: CheckedContinuation<String, Error>?
    private var connection: LiveConnection!
    private var saving: Task<Void, Never>?

    /** Keeps the note on this Mac a moment after it changes (here or elsewhere). */
    private func keepSoon() {
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.cache.save(self.doc.state())
        }
    }

    init(path: String, status: @escaping (_ state: String, _ message: String?) -> Void, remote: @escaping (_ changes: [TextChange]) -> Void) {
        self.path = path
        self.readOnly = driveReadOnly(path)
        self.status = status
        self.remote = remote
        cache = LiveCache(path: path)
        doc = cache.load().flatMap { try? SyncDoc.fromState(state: $0) } ?? SyncDoc()
        connection = LiveConnection(path: path, greeting: { [doc] in doc.start() }, receive: { [weak self] in try self?.receive($0) }) { [weak self] state, message in
            guard let self else { return }
            if state == "error" {
                // Moved or deleted: what's kept here is no one's now.
                self.cache.forget()
                if let c = self.opened {
                    self.opened = nil
                    c.resume(throwing: APIError(message: message ?? "This note can't be opened"))
                }
            }
            // Live once the note is here; until then, it's still opening.
            if state != "live" || self.opened == nil { self.status(state, message) }
        }
    }

    private func receive(_ bytes: Data) throws -> Data? {
        let got = try doc.receive(message: bytes)
        if !got.changes.isEmpty, opened == nil { remote(got.changes) }
        if !got.changes.isEmpty { keepSoon() }
        if let c = opened, LiveConnection.isSyncStep2(bytes) {
            opened = nil
            c.resume(returning: doc.text())
            status("live", nil)
        }
        return got.reply
    }

    /** The note's text: once it's come from the server (or, for course files, as the file is). */
    func open() async throws -> String {
        status("loading", nil)
        if readOnly {
            guard let read = try await api.driveRead(path) else { throw APIError(message: "Couldn't read \(path)") }
            status("readonly", nil)
            return String(decoding: read.data, as: UTF8.self)
        }
        // Kept here: shown at once, what's changed since coming in as it does.
        if cache.load() != nil {
            connection.connect()
            return doc.text()
        }
        return try await withCheckedThrowingContinuation { c in
            opened = c
            connection.connect()
        }
    }

    /** Typed here: [to] - [from] UTF-16 units from [from] replaced by [insert]. */
    func edited(from: Int, to: Int, insert: String) {
        guard !readOnly else { return }
        connection.send(doc.edit(from: UInt32(from), to: UInt32(to), insert: insert))
        keepSoon()
    }

    /** Lets the note go (a moment first, for what was just sent to go out). */
    func close() async {
        if !readOnly {
            saving?.cancel()
            cache.save(doc.state())
        }
        await connection.close()
    }
}
