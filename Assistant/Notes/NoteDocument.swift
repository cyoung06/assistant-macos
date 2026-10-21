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

    private let doc = SyncDoc()
    private var opened: CheckedContinuation<String, Error>?
    private var connection: LiveConnection!

    init(path: String, status: @escaping (_ state: String, _ message: String?) -> Void, remote: @escaping (_ changes: [TextChange]) -> Void) {
        self.path = path
        self.readOnly = driveReadOnly(path)
        self.status = status
        self.remote = remote
        connection = LiveConnection(path: path, greeting: { [doc] in doc.start() }, receive: { [weak self] in try self?.receive($0) }) { [weak self] state, message in
            guard let self else { return }
            if state == "error", let c = self.opened {
                self.opened = nil
                c.resume(throwing: APIError(message: message ?? "This note can't be opened"))
            }
            // Live once the note is here; until then, it's still opening.
            if state != "live" || self.opened == nil { self.status(state, message) }
        }
    }

    private func receive(_ bytes: Data) throws -> Data? {
        let got = try doc.receive(message: bytes)
        if !got.changes.isEmpty, opened == nil { remote(got.changes) }
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
        return try await withCheckedThrowingContinuation { c in
            opened = c
            connection.connect()
        }
    }

    /** Typed here: [to] - [from] UTF-16 units from [from] replaced by [insert]. */
    func edited(from: Int, to: Int, insert: String) {
        guard !readOnly else { return }
        connection.send(doc.edit(from: UInt32(from), to: UInt32(to), insert: insert))
    }

    /** Lets the note go (a moment first, for what was just sent to go out). */
    func close() async {
        await connection.close()
    }
}
