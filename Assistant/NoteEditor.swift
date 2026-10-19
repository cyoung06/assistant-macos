import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    /** Show a drive path in Files (a link followed from a note): its path is the object. */
    static let driveReveal = Notification.Name("com.syeyoung.assistant.drive-reveal")
}

/**
 * The web app's note editor (Markdown with TeX, written as it renders), bundled in the app
 * (Assistant/Editor, from ./sync-editor.sh) and shown in a web view. The page reaches nothing
 * itself: it asks here to read and write notes and their images (see web/src/embed/README.md).
 * One editor serves every note, so the note open before is saved when another one opens.
 */
@MainActor
final class NoteEditor: NSObject, ObservableObject, WKScriptMessageHandlerWithReply {
    static let shared = NoteEditor()

    /** What the page says about the note: loading, saved, unsaved, saving, error, conflict, readonly. */
    @Published private(set) var state = "loading"
    @Published private(set) var message: String?
    /** The Markdown as written, instead of rendered as you write. */
    @Published var source = false { didSet { run("assistantEditor.setSource(\(source))") } }

    /** The note shown (or to be shown once the page is up), and its version as last read or written. */
    private(set) var path: String?
    private var etag: String?
    private var ready = false
    private var pending: [String: Any]?

    private var api: API { AppModel.shared.api }

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "assistant")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        if let page = Bundle.main.url(forResource: "embed", withExtension: "html", subdirectory: "Editor") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return view
    }()

    private override init() {
        super.init()
        // Saved before the app quits (a moment's wait at most).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NoteEditor.shared.flushBeforeQuitting() }
        }
    }

    // ---- showing a note ----

    /** Shows the note at [path], read from the drive (saving the one shown before). */
    func open(_ path: String) async {
        guard path != self.path else { return }
        _ = webView
        state = "loading"
        message = nil
        do {
            guard let read = try await api.driveRead(path) else { return }
            self.path = path
            etag = read.etag
            let note: [String: Any] = [
                "path": path, "text": String(decoding: read.data, as: UTF8.self), "etag": read.etag ?? NSNull(),
                "readOnly": driveReadOnly(path), "theme": "system",
            ]
            if ready { _ = try await webView.callAsyncJavaScript("assistantEditor.open(note)", arguments: ["note": note], contentWorld: .page) }
            else { pending = note }
        } catch {
            state = "error"
            message = error.localizedDescription
        }
    }

    /** Saves what's unsaved now. */
    func flush() async {
        guard ready, path != nil else { return }
        _ = try? await webView.callAsyncJavaScript("await assistantEditor.flush()", arguments: [:], contentWorld: .page)
    }

    /** A newer version written elsewhere (another device, Finder): shown if nothing's being edited here. */
    func checkForChanges() async {
        guard ready, let path, let etag else { return }
        guard let read = try? await api.driveRead(path, ifNoneMatch: etag), let newer = read.etag, newer != etag else { return }
        let note: [String: Any] = ["text": String(decoding: read.data, as: UTF8.self), "etag": newer]
        _ = try? await webView.callAsyncJavaScript("assistantEditor.reloadIfUnchanged(note)", arguments: ["note": note], contentWorld: .page)
    }

    private func flushBeforeQuitting() {
        var done = false
        Task { await flush(); done = true }
        let until = Date().addingTimeInterval(2)
        while !done && Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    private func run(_ script: String) {
        guard ready else { return }
        webView.evaluateJavaScript(script)
    }

    // ---- what the page asks ----

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return replyHandler(nil, "Not understood") }
        let payload = body["payload"] as? [String: Any] ?? [:]
        guard body["id"] != nil else {
            notice(type, payload)
            return replyHandler(nil, nil)
        }
        Task {
            do { replyHandler(try await request(type, payload), nil) } catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    /** A request's answer (see the README's table). */
    func request(_ type: String, _ p: [String: Any]) async throws -> [String: Any] {
        let path = p["path"] as? String ?? ""
        switch type {
        case "save":
            let force = p["force"] as? Bool ?? false
            let text = p["text"] as? String ?? ""
            // An empty note is a newline (older servers refuse empty bodies).
            guard let written = try await api.driveWrite(path, Data((text.isEmpty ? "\n" : text).utf8), type: "text/markdown; charset=utf-8", ifMatch: force ? nil : p["etag"] as? String) else {
                return ["conflict": true]
            }
            if path == self.path { etag = written.etag }
            return ["etag": written.etag ?? NSNull()]
        case "load":
            guard let read = try await api.driveRead(path) else { throw APIError(message: "Couldn't read \(path)") }
            if path == self.path { etag = read.etag }
            return ["text": String(decoding: read.data, as: UTF8.self), "etag": read.etag ?? NSNull()]
        case "saveCopy":
            let name = (path as NSString).lastPathComponent
            let copy = ((name as NSString).deletingPathExtension) + " (my copy)" + ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension)
            let folder = driveParent(path)
            let free = await api.driveFreeName(copy, in: folder)
            let text = p["text"] as? String ?? ""
            try await api.driveWrite(folder + free, Data((text.isEmpty ? "\n" : text).utf8), type: "text/markdown; charset=utf-8")
            Task { await DriveStore.shared.load(folder) }
            return ["name": free]
        case "uploadImage":
            guard let notePath = p["notePath"] as? String, let data = Data(base64Encoded: p["base64"] as? String ?? "") else { throw APIError(message: "No image") }
            let folder = driveParent(notePath) + "attachments/"
            let name = await api.driveFreeName((p["name"] as? String ?? "image.png").replacingOccurrences(of: "/", with: " "), in: folder)
            try await api.driveWrite(folder + name, data, type: p["mimeType"] as? String ?? "application/octet-stream")
            Task { await DriveStore.shared.load(folder) }
            return ["relativePath": "attachments/" + uriComponent(name)]
        case "readImage":
            guard let read = try await api.driveRead(path) else { throw APIError(message: "Couldn't read \(path)") }
            let type = read.type ?? UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return ["mimeType": type, "base64": read.data.base64EncodedString()]
        default:
            throw APIError(message: "Unknown request \(type)")
        }
    }

    private func notice(_ type: String, _ p: [String: Any]) {
        switch type {
        case "ready":
            ready = true
            run("assistantEditor.setSource(\(source))")
            if let note = pending {
                pending = nil
                Task { _ = try? await webView.callAsyncJavaScript("assistantEditor.open(note)", arguments: ["note": note], contentWorld: .page) }
            }
        case "status":
            state = p["state"] as? String ?? state
            message = p["message"] as? String
        case "openLink":
            if let path = p["resolvedPath"] as? String {
                NotificationCenter.default.post(name: .driveReveal, object: path)
            } else if let href = p["href"] as? String, let url = URL(string: href) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

/** A path part as JavaScript's encodeURIComponent writes it (as the web app links attachments). */
func uriComponent(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

/** The editor's web view, wherever a note is shown. */
private struct NoteWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let view = NoteEditor.shared.webView
        view.removeFromSuperview()
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: ()) {
        // Leaving the note (another file selected, Files closed): what's unsaved is saved.
        Task { @MainActor in await NoteEditor.shared.flush() }
    }
}

/** A Markdown note in Files: the editor, with its save state, a Markdown-as-written switch, and ⌘S. */
struct NoteView: View {
    let entry: DriveEntry
    @ObservedObject private var editor = NoteEditor.shared
    @ObservedObject private var store = DriveStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: driveIcon(.markdown)).foregroundStyle(.secondary)
                Text(entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(statusText).font(.caption).foregroundStyle(editor.state == "error" || editor.state == "conflict" ? .red : .secondary)
                Spacer()
                Toggle("Source", isOn: $editor.source).toggleStyle(.button).help("Show the Markdown as written")
                Button("Save") { Task { await editor.flush() } }.keyboardShortcut("s", modifiers: .command).disabled(driveReadOnly(entry.path))
                Button("Open") { Task { await store.openExternally(entry) } }
            }
            .padding(10)
            Divider()
            NoteWebView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: entry.path) { await editor.open(entry.path) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await editor.checkForChanges() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            Task { await editor.flush() }
        }
    }

    private var statusText: String {
        switch editor.state {
        case "saved": "Saved"
        case "unsaved": "Edited"
        case "saving": "Saving…"
        case "error": "Couldn't save" + (editor.message.map { ": \($0)" } ?? "")
        case "conflict": "Changed elsewhere"
        case "readonly": "From PLMS · read-only"
        default: ""
        }
    }
}
