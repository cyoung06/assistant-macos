import CryptoKit
import Foundation

/**
 * A live document as this Mac last had it (its Yjs state): kept so it opens at once, offline too, and
 * what was written while away isn't lost if the app quits before it's sent. On connecting, only what's
 * changed since goes either way (see [LiveConnection]). In Application Support, by a hash of the path.
 */
struct LiveCache {
    private let file: URL

    init(path: String) {
        let dir = LiveCache.folder.appending(path: "live", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        file = dir.appending(path: hash + ".ydoc")
    }

    /** Where the app keeps what it needs offline (live documents, notebooks' base PDFs). */
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Assistant", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /** The kept state; nil if there's none. */
    func load() -> Data? { (try? Data(contentsOf: file)).flatMap { $0.isEmpty ? nil : $0 } }

    /** Keeps [state], whole or not at all. */
    func save(_ state: Data) { try? state.write(to: file, options: .atomic) }

    /** Lets go of it (the file was moved or deleted: what's kept is no one's any more). */
    func forget() { try? FileManager.default.removeItem(at: file) }
}
