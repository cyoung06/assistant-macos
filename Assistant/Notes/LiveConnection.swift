import Foundation

/**
 * A live document's line to the API (y-websocket, `/api/v1/sync?doc=<path>`): for a note
 * ([NoteDocument]) or a notebook ([NotebookDocument]). Connected, and again after it drops (a little
 * later each time, up to half a minute), until let go or refused.
 *
 * What comes in is handed to [receive] on the main actor, as the document takes it (so a view showing
 * the document changes with it); its reply goes back. [greeting] is the document's sync step 1, sent on
 * connecting. Pinged every 20 seconds: a line that died quietly (as one does while the Mac sleeps) is
 * noticed by its missing pong and made again. [status] hears "connecting", "live", "offline", or
 * "error" with why.
 */
@MainActor
final class LiveConnection {
    private let path: String
    private let greeting: () -> Data
    private let receive: (Data) throws -> Data?
    private let status: (_ state: String, _ message: String?) -> Void
    private var api: API { AppModel.shared.api }

    private var socket: URLSessionWebSocketTask?
    /** What's to be sent while not connected (the sync on connecting covers it anyway). */
    private var pending: [Data] = []
    private var isOpen = false
    /** Refused by the server (not a file to edit live, or moved or deleted): no more tries. */
    private var refused = false
    private var closed = false
    /** Whether the last ping was answered. */
    private var ponged = true

    init(path: String, greeting: @escaping () -> Data, receive: @escaping (Data) throws -> Data?, status: @escaping (_ state: String, _ message: String?) -> Void) {
        self.path = path
        self.greeting = greeting
        self.receive = receive
        self.status = status
    }

    func connect() {
        Task { await run() }
    }

    func send(_ message: Data) {
        guard !closed else { return }
        guard let socket, isOpen else { pending.append(message); return }
        socket.send(.data(message)) { _ in }
    }

    private func run() async {
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
            task.send(.data(greeting())) { _ in }
            ponged = true
            let pinger = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    // Unanswered since last time: the line is dead (a dead one may never say so).
                    guard self.ponged else { task.cancel(with: .goingAway, reason: nil); return }
                    self.ponged = false
                    task.sendPing { error in
                        Task { @MainActor [weak self] in
                            if error == nil { self?.ponged = true } else { task.cancel(with: .goingAway, reason: nil) }
                        }
                    }
                }
            }
            do {
                while !closed {
                    guard case .data(let bytes) = try await task.receive() else { continue }
                    wait = 1
                    if !isOpen {
                        isOpen = true
                        status("live", nil)
                    }
                    if let reply = try receive(bytes) { task.send(.data(reply)) { _ in } }
                    for m in pending { task.send(.data(m)) { _ in } }
                    pending.removeAll()
                }
            } catch {
                if task.closeCode == .policyViolation {
                    refused = true
                    status("error", task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "This can't be opened")
                }
            }
            pinger.cancel()
            isOpen = false
            socket = nil
            if closed || refused { break }
            status("offline", nil)
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 30)
        }
    }

    /** Lets go (a moment first, for what was just sent to go out). */
    func close() async {
        closed = true
        if isOpen { try? await Task.sleep(nanoseconds: 300_000_000) }
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    /** Whether [message] is the server's sync step 2 (y-protocols: sync, step 2): the document is all here. */
    nonisolated static func isSyncStep2(_ message: Data) -> Bool {
        message.count > 1 && message[message.startIndex] == 0 && message[message.startIndex + 1] == 1
    }
}
