import Foundation

/** A mail dragged out of Apple Mail (an .eml file): what Capture needs from it. */
struct MailFile {
    let subject: String
    let from: String
    let messageId: String?
    let text: String

    /** Reopens this mail in Apple Mail. */
    var link: String? {
        messageId.map { "message:%3C" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? $0) + "%3E" }
    }

    /** Parses headers (unfolded, encoded words decoded) and the first plain-text part. */
    static func parse(_ data: Data) -> MailFile? {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let (headers, body) = split(raw)
        guard !headers.isEmpty else { return nil }
        let subject = decodeWords(headers["subject"] ?? "")
        let from = decodeWords(headers["from"] ?? "")
        let id = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        let text = plainText(headers: headers, body: body)
        return MailFile(subject: subject, from: from, messageId: id, text: text)
    }

    private static func split(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = normalized.range(of: "\n\n") else { return ([:], "") }
        var headers: [String: String] = [:]
        var last: String?
        for line in normalized[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t", let key = last {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                if headers[key] == nil { headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                last = key
            }
        }
        return (headers, String(normalized[end.upperBound...]))
    }

    /** The first text/plain part, decoded; the whole body for a single-part plain mail. */
    private static func plainText(headers: [String: String], body: String) -> String {
        let type = (headers["content-type"] ?? "text/plain").lowercased()
        if type.hasPrefix("multipart/"), let boundary = param("boundary", in: headers["content-type"] ?? "") {
            for part in body.components(separatedBy: "--" + boundary).dropFirst() {
                let (h, b) = split(part.trimmingCharacters(in: .newlines) + "\n")
                let ptype = (h["content-type"] ?? "text/plain").lowercased()
                if ptype.hasPrefix("multipart/") || ptype.hasPrefix("text/plain") {
                    let t = plainText(headers: h, body: b)
                    if !t.isEmpty { return t }
                }
            }
            return ""
        }
        guard type.hasPrefix("text/plain") else { return "" }
        let charset = param("charset", in: headers["content-type"] ?? "") ?? "utf-8"
        let bytes: Data
        switch (headers["content-transfer-encoding"] ?? "").lowercased() {
        case "base64": bytes = Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined()) ?? Data()
        case "quoted-printable": bytes = quotedPrintable(body, underscoreIsSpace: false)
        default: bytes = Data(body.utf8)
        }
        return decode(bytes, charset).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func param(_ name: String, in header: String) -> String? {
        guard let r = header.range(of: name + "=", options: .caseInsensitive) else { return nil }
        let rest = header[r.upperBound...]
        if rest.first == "\"" { return rest.dropFirst().split(separator: "\"").first.map(String.init) }
        return rest.split(whereSeparator: { $0 == ";" || $0 == " " }).first.map(String.init)
    }

    /** RFC 2047 encoded words, e.g. "=?UTF-8?B?7KSR6rCE6rOg7IKs?=". */
    static func decodeWords(_ s: String) -> String {
        let pattern = #/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/#
        var out = ""
        var rest = Substring(s)
        while let m = rest.firstMatch(of: pattern) {
            let between = rest[rest.startIndex..<m.range.lowerBound]
            // Whitespace between two encoded words is not part of the text.
            if !(out.hasSuffix("\u{0}") && between.allSatisfy(\.isWhitespace)) { out += between }
            out = out.replacingOccurrences(of: "\u{0}", with: "")
            let charset = String(m.output.1), text = String(m.output.3)
            let bytes = m.output.2.lowercased() == "b" ? (Data(base64Encoded: padded(text)) ?? Data()) : quotedPrintable(text, underscoreIsSpace: true)
            out += decode(bytes, charset) + "\u{0}"
            rest = rest[m.range.upperBound...]
        }
        return (out + rest).replacingOccurrences(of: "\u{0}", with: "")
    }

    private static func padded(_ b64: String) -> String { b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4) }

    private static func quotedPrintable(_ s: String, underscoreIsSpace: Bool) -> Data {
        var out = Data()
        let chars = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "="), i + 2 < chars.count, let v = UInt8(String(bytes: chars[i + 1...i + 2], encoding: .ascii)!, radix: 16) {
                out.append(v); i += 3
            } else {
                out.append(underscoreIsSpace && c == UInt8(ascii: "_") ? UInt8(ascii: " ") : c); i += 1
            }
        }
        return out
    }

    private static func decode(_ bytes: Data, _ charset: String) -> String {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) as CFString)
        let encoding = cf == kCFStringEncodingInvalidId ? String.Encoding.utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
    }
}
