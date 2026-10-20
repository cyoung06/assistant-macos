import Foundation

/** A mail dragged out of a mail app (an .eml file), as Capture needs it; read by the server ([API.parseMail]). */
struct MailFile {
    let subject: String
    let from: String
    let messageId: String?
    let text: String

    /** The mail as a reference: mid:<Message-ID> (RFC 2392); the app opens it in Apple Mail. */
    var link: String? {
        messageId.map { "mid:" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? $0) }
    }
}
