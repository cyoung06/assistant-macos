import Foundation

/**
 * A note as every device has it at once: a Yjs document ([SyncDoc], the shared core's) kept in step
 * with the API's over its y-websocket endpoint (`/api/v1/sync?doc=<path>`), which writes the file.
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
    private var socket: URLSessionWebSocketTask?
    /** Edits made while not connected (the sync on connecting covers them anyway). */
    private var pending: [Data] = []
    private var opened: CheckedContinuation<String, Error>?
    private var isOpen = false
    /** Refused by the server (not a note to edit live, or moved or deleted): no more tries. */
    private var refused = false
    private var closed = false

    init(path: String, status: @escaping (_ state: String, _ message: String?) -> Void, remote: @escaping (_ changes: [TextChange]) -> Void) {
        self.path = path
        self.readOnly = driveReadOnly(path)
        self.status = status
        self.remote = remote
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
            Task { await connect() }
        }
    }

    /** Typed here: [to] - [from] UTF-16 units from [from] replaced by [insert]. */
    func edited(from: Int, to: Int, insert: String) {
        guard !readOnly, !closed else { return }
        send(doc.edit(from: UInt32(from), to: UInt32(to), insert: insert))
    }

    private func send(_ message: Data) {
        guard let socket, isOpen else { pending.append(message); return }
        socket.send(.data(message)) { _ in }
    }

    /** Connected, with tries again (a little later each time, up to half a minute) until let go. */
    private func connect() async {
        var wait: UInt64 = 1
        while !closed && !refused {
            status("connecting", nil)
            var c = URLComponents(url: api.base.appending(path: "api/v1/sync"), resolvingAgainstBaseURL: false)!
            c.scheme = c.scheme == "https" ? "wss" : "ws"
            c.queryItems = [URLQueryItem(name: "doc", value: path)]
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let task = URLSession.shared.webSocketTask(with: c.url!)
            socket = task
            task.resume()
            // Old messages: what they carried is in the sync this connection starts with.
            pending.removeAll()
            task.send(.data(doc.start())) { _ in }
            do {
                while !closed {
                    guard case .data(let bytes) = try await task.receive() else { continue }
                    wait = 1
                    isOpen = true
                    let got = try doc.receive(message: bytes)
                    if !got.changes.isEmpty, opened == nil { remote(got.changes) }
                    // The server's answer to our sync step 1 (y-protocols: sync, step 2): the note is all here.
                    if let c = opened, bytes.count > 1, bytes[0] == 0, bytes[1] == 1 {
                        opened = nil
                        c.resume(returning: doc.text())
                    }
                    if opened == nil { status("live", nil) }
                    if let reply = got.reply { task.send(.data(reply)) { _ in } }
                    for m in pending { task.send(.data(m)) { _ in } }
                    pending.removeAll()
                }
            } catch {
                if task.closeCode == .policyViolation {
                    refused = true
                    let why = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "This note can't be opened"
                    status("error", why)
                    opened?.resume(throwing: APIError(message: why))
                    opened = nil
                }
            }
            isOpen = false
            socket = nil
            if closed || refused { break }
            status("offline", nil)
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 30)
        }
    }

    /** Lets the note go (a moment first, for what was just sent to go out). */
    func close() async {
        closed = true
        if isOpen { try? await Task.sleep(nanoseconds: 300_000_000) }
        socket?.cancel(with: .normalClosure, reason: nil)
    }
}
