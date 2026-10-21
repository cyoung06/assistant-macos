import CryptoKit
import Foundation

/**
 * A note's file and what's typed into it, as the web editor keeps them: saved a second after typing
 * stops, only over the version it's based on (If-Match); what isn't written yet is kept as a draft
 * on this Mac until it is, and offered when the note opens again (as a conflict if the note changed
 * meanwhile). [text] is what the editor has now; [status] hears how saving is going.
 */
@MainActor
final class NoteDocument {
    let path: String
    let readOnly: Bool
    private let text: () -> String
    private let status: (_ state: String, _ message: String?) -> Void
    private var api: API { AppModel.shared.api }

    /** The version the text is based on (an ETag). */
    private(set) var version: String?
    private var dirty = false
    private var conflicted = false
    private var saving: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var keepTimer: Task<Void, Never>?

    private let draftURL: URL

    init(path: String, text: @escaping () -> String, status: @escaping (String, String?) -> Void) {
        self.path = path
        self.readOnly = driveReadOnly(path)
        self.text = text
        self.status = status
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Assistant/note-drafts")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        draftURL = dir.appending(path: "\(name).json")
    }

    /** The note to show, and how it opens ("saved", or "unsaved"/"conflict" with a draft from before). */
    func open() async throws -> (text: String, state: String) {
        status("loading", nil)
        guard let read = try await api.driveRead(path) else { throw APIError(message: "Couldn't read \(path)") }
        version = read.etag
        let written = String(decoding: read.data, as: UTF8.self)
        let draft = readOnly ? nil : readDraft()
        let state: String
        var shown = written
        if let draft {
            if draft.text == written { clearDraft(); state = "saved" }
            else if draft.base == version { dirty = true; schedule(); state = "unsaved"; shown = draft.text }
            else { version = draft.base; dirty = true; conflicted = true; state = "conflict"; shown = draft.text }
        } else {
            state = readOnly ? "readonly" : "saved"
        }
        status(state, nil)
        return (shown, state)
    }

    /** The text was typed into: kept as a draft at once, saved a second after typing stops. */
    func edited() {
        guard !readOnly else { return }
        dirty = true
        keepTimer?.cancel()
        keepTimer = Task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { keep() } }
        if !conflicted { status("unsaved", nil); schedule() }
    }

    private func schedule() {
        timer?.cancel()
        timer = Task { try? await Task.sleep(for: .seconds(1)); if !Task.isCancelled { await save() } }
    }

    /** Writes the note; with [force], even over a version written elsewhere. */
    func save(force: Bool = false) async {
        guard !readOnly, dirty || force, !conflicted || force else { return }
        if let saving { await saving.value; return await save(force: force) }
        let writing = text()
        dirty = false
        status("saving", nil)
        let task = Task {
            do {
                // An empty note is a newline (older servers refuse empty bodies).
                let body = Data((writing.isEmpty ? "\n" : writing).utf8)
                if let written = try await api.driveWrite(path, body, type: "text/markdown; charset=utf-8", ifMatch: force ? nil : version) {
                    version = written.etag
                    conflicted = false
                    status(dirty ? "unsaved" : "saved", nil)
                } else {
                    dirty = true; conflicted = true
                    status("conflict", nil)
                }
            } catch {
                dirty = true
                status("error", error.localizedDescription)
            }
            keep()
        }
        saving = task
        await task.value
        saving = nil
    }

    /** Writes what's unsaved now; true once everything typed is written (false: it's kept as a draft). */
    func flush() async -> Bool {
        timer?.cancel()
        keep()
        await save()
        return readOnly || (!dirty && !conflicted)
    }

    /** A newer version written elsewhere (asked only if it changed), unless this one's being edited. */
    func newer() async -> String? {
        guard !dirty, saving == nil, !conflicted, let version else { return nil }
        guard let read = try? await api.driveRead(path, ifNoneMatch: version), let etag = read.etag, etag != version else { return nil }
        self.version = etag
        return String(decoding: read.data, as: UTF8.self)
    }

    // ---- a conflict: what to keep ----

    func keepMine() async { await save(force: true) }

    /** The other version, instead of what's here (which is dropped). */
    func loadTheirs() async throws -> String {
        guard let read = try await api.driveRead(path) else { throw APIError(message: "Couldn't read \(path)") }
        version = read.etag
        dirty = false; conflicted = false
        clearDraft()
        status("saved", nil)
        return String(decoding: read.data, as: UTF8.self)
    }

    /** What's here, written beside the note as "name (my copy).md"; its name, and the note's own version. */
    func saveCopy() async throws -> (name: String, theirs: String) {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let copy = stem + " (my copy)" + (ext.isEmpty ? "" : "." + ext)
        let mine = Data(text().utf8)
        let made = try await api.driveCreate(driveParent(path) + copy) { try await self.api.driveWriteNew($0, mine, type: "text/markdown; charset=utf-8") }
        return ((made as NSString).lastPathComponent, try await loadTheirs())
    }

    // ---- the draft ----

    private struct Draft: Codable { let text: String; let base: String?; let at: Date }

    /** Keeps what's unsaved as a draft (none once it's all written), written whole (a crash keeps the last). */
    private func keep() {
        keepTimer?.cancel()
        guard !readOnly else { return }
        guard dirty || conflicted else { return clearDraft() }
        if let data = try? JSONEncoder().encode(Draft(text: text(), base: version, at: Date())) {
            try? data.write(to: draftURL, options: .atomic)
        }
    }

    private func readDraft() -> Draft? { (try? Data(contentsOf: draftURL)).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) } }

    private func clearDraft() { try? FileManager.default.removeItem(at: draftURL) }
}
