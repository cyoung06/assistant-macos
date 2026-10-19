import AppKit
import Foundation

/**
 * How the Share extension hands something to the app to send to Triage in the background: the
 * extension (sandboxed, and without an App Group, as the app isn't signed by a team) puts it on a
 * private named pasteboard and opens `assistant-handoff:<id>`; the app takes it off and queues it.
 */
enum Handoff {
    static let scheme = "assistant-handoff"
    private static let board = NSPasteboard(name: NSPasteboard.Name("com.syeyoung.assistant.handoff"))
    private static let type = NSPasteboard.PasteboardType("com.syeyoung.assistant.triage")

    struct Payload: Codable {
        var id: String
        var text: String
        var title: String
        var link: String?
        var images: [Data]
        var mimeTypes: [String]
    }

    /** From the extension: true when the app took it (it opens, if it wasn't running). */
    static func give(text: String, title: String, link: String?, images: [CapturedImage]) -> Bool {
        let p = Payload(id: UUID().uuidString, text: text, title: title, link: link, images: images.map(\.data), mimeTypes: images.map(\.mimeType))
        guard let data = try? PropertyListEncoder().encode(p), let url = URL(string: "\(scheme):\(p.id)") else { return false }
        board.clearContents()
        guard board.setData(data, forType: type) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /** In the app, for an `assistant-handoff:<id>` link: the payload, if it's the one on the pasteboard. */
    static func take(_ url: URL) -> Payload? {
        let id = url.absoluteString.dropFirst(scheme.count + 1)
        guard let data = board.data(forType: type), let p = try? PropertyListDecoder().decode(Payload.self, from: data), p.id == id else { return nil }
        board.clearContents()
        return p
    }
}
