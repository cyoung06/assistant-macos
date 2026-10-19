import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CapturedImage: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
    let mimeType: String
    var image: NSImage? { NSImage(data: data) }
}

/**
 * Capture: a quick task from text, a link or screenshots, or "Analyze", where the model proposes
 * tasks and events to review before anything is created. Used by the ⌥Space panel and the Share
 * extension.
 */
struct CaptureView: View {
    let api: API
    @State var text: String
    @State var images: [CapturedImage]
    /** A mail dropped from Apple Mail: its subject becomes the title, with a link back to it. */
    @State var mail: MailFile? = nil
    /** Takes it to send in the background, so the panel closes at once; false sends it here instead (the app couldn't be reached). */
    var handOff: ((_ text: String, _ title: String, _ link: String?, _ images: [CapturedImage]) -> Bool)? = nil
    var onDone: () -> Void

    @State private var mode = 0
    @State private var title = ""
    @State private var due: Due?
    @State private var projectId: String?
    @State private var projects: [Project] = []
    @State private var busy = false
    @State private var error: String?
    @State private var uploaded: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) {
                Text("To Triage").tag(0)
                Text("Quick task").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images) { img in
                            if let i = img.image {
                                Image(nsImage: i).resizable().scaledToFill().frame(width: 90, height: 64).clipped().cornerRadius(6)
                                    .overlay(alignment: .topTrailing) {
                                        Button { images.removeAll { $0.id == img.id } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).padding(2)
                                    }
                            }
                        }
                    }
                }
            }

            if mode == 0 { triage } else { quickTask }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(16)
        .onDrop(of: [.emailMessage, .image, .fileURL, .text, .url], isTargeted: nil) { providers in
            Task { await take(providers) }
            return true
        }
        .onPasteCommand(of: [.image, .png, .tiff, .text, .url]) { providers in Task { await take(providers) } }
        .task {
            projects = (try? await api.projects()) ?? []
            if let mail { useMail(mail) } else if title.isEmpty { await prefill() }
            if !images.isEmpty { mode = 1 }
        }
    }

    // ---- quick task ----------------------------------------------------------------

    private var quickTask: some View {
        VStack(alignment: .leading, spacing: 8) {
            MentionField(api: api, text: $title, prompt: "Task title (@ to reference)", axis: .vertical)
            HStack(spacing: 6) {
                ForEach(dueChoices(today: todayString).prefix(3), id: \.1) { label, day in
                    Button(label) { due = Due(date: day, time: due?.time) }.buttonStyle(.bordered).controlSize(.small)
                        .tint(due?.date == day ? .accentColor : nil)
                }
                if due != nil { Button("No date") { due = nil }.controlSize(.small) }
                Spacer()
                Picker("", selection: $projectId) {
                    Text("No project").tag(String?.none)
                    ForEach(projects, id: \.id) { p in Text(p.name).tag(Optional(p.id)) }
                }
                .labelsHidden().frame(maxWidth: 180)
            }
            if !text.isEmpty { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(busy ? "Saving…" : "Create task") { Task { await createQuick() } }
                    .keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
    }

    private func prefill() async {
        let link = text.firstMatch(of: /https?:\/\/\S+/).map { String($0.output) }
        let rest = text.replacing(/https?:\/\/\S+/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = String(rest.split(separator: "\n").first ?? "").prefix(120).description
        if let link, let ref = try? await api.resolve(link) {
            let md = refMarkdown(ref.title, ref.url)
            title = title.isEmpty ? md : "\(title) \(md)"
        }
    }

    /** Subject as the title; sender and a link that reopens the mail in Mail go in the description; Analyze reads the body. */
    private func useMail(_ m: MailFile) {
        mail = m
        title = m.subject.isEmpty ? "(no subject)" : m.subject
        if text.isEmpty { text = m.text }
    }

    private var mailDescription: String? {
        guard let m = mail else { return nil }
        let subject = m.subject.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return ((m.link.map { ["Mail: [\(subject)](\($0))"] } ?? []) + ["From: \(m.from)"]).joined(separator: "\n")
    }

    private func uploadImages() async throws -> [String] {
        if uploaded.isEmpty && !images.isEmpty {
            var ids: [String] = []
            for img in images { ids.append(try await api.upload(img.data, filename: img.name, mimeType: img.mimeType)) }
            uploaded = ids
        }
        return uploaded
    }

    private func createQuick() async {
        busy = true
        defer { busy = false }
        do {
            let ids = try await uploadImages()
            let description = mailDescription ?? (text.count > 120 || text.contains("\n") ? text : nil)
            _ = try await api.create(.init(attachmentIds: ids, description: description, due: due, projectId: projectId, title: title.trimmingCharacters(in: .whitespaces)))
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    // ---- triage ---------------------------------------------------------------------

    /** Sends it to Triage and closes: the model reads it in the background, and its suggestions wait there. */
    private var triage: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text to read, or a note for the model (optional)", text: $text, axis: .vertical).lineLimit(2...6)
            HStack {
                Text(images.isEmpty ? "Paste or drop screenshots here." : "\(images.count) image(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(busy ? "Sending…" : "Send to Triage") { Task { await sendToTriage() } }
                    .keyboardShortcut(.defaultAction).disabled(busy || (images.isEmpty && text.isEmpty))
            }
        }
    }

    private func sendToTriage() async {
        let source = mail.map { "Mail from \($0.from), subject \($0.subject):\n\n" } ?? ""
        if let handOff, handOff(source + text, mail?.subject ?? "", mail?.link, images) {
            onDone()
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let ids = try await uploadImages()
            try await api.submitTriage(text: source + text, attachmentIds: ids, title: mail?.subject ?? "", link: mail?.link)
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    // ---- paste and drop ---------------------------------------------------------------

    private func take(_ providers: [NSItemProvider]) async {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.emailMessage.identifier), let data = try? await p.loadFile(.emailMessage), let m = MailFile.parse(data) {
                useMail(m)
                mode = 0
                return
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), let data = await p.imageData() {
                images.append(CapturedImage(data: data, name: "screenshot.png", mimeType: "image/png"))
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = try? await p.loadURL(), let data = try? Data(contentsOf: url),
                      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                images.append(CapturedImage(data: data, name: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "image/png"))
            } else if let s = try? await p.loadString() {
                text = text.isEmpty ? s : text + "\n" + s
            }
        }
    }
}

extension NSItemProvider {
    /** The image as PNG (or as shared, when it can't be converted). */
    func imageData() async -> Data? {
        if let png = try? await loadData(.png) { return png }
        return try? await loadData(.image)
    }

    func loadData(_ type: UTType) async throws -> Data? {
        guard hasItemConformingToTypeIdentifier(type.identifier) else { return nil }
        return try await withCheckedThrowingContinuation { c in
            _ = loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let error { c.resume(throwing: error) } else {
                    // TIFF from the pasteboard becomes PNG, which every model accepts.
                    if type != .png, let data, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { c.resume(returning: png) }
                    else { c.resume(returning: data) }
                }
            }
        }
    }

    /** A file the drag provides (including a promised one, like a mail dragged out of Mail). */
    func loadFile(_ type: UTType) async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: url.flatMap { try? Data(contentsOf: $0) }) }
            }
        }
    }

    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { c in
            _ = loadObject(ofClass: URL.self) { url, error in if let error { c.resume(throwing: error) } else { c.resume(returning: url) } }
        }
    }

    func loadString() async throws -> String? {
        if canLoadObject(ofClass: String.self) {
            return try await withCheckedThrowingContinuation { c in
                _ = loadObject(ofClass: String.self) { s, error in if let error { c.resume(throwing: error) } else { c.resume(returning: s) } }
            }
        }
        if let url = try? await loadURL() { return url.absoluteString }
        return nil
    }
}

/**
 * A text field where typing `@` at the end searches everything that can be referenced and
 * inserts it as a Markdown link.
 */
struct MentionField: View {
    let api: API
    @Binding var text: String
    var prompt: String
    var axis: Axis = .horizontal
    @State private var results: [RefItem] = []

    private var query: String? {
        guard let m = text.firstMatch(of: /(?:^|\s)@([^\s@\[\]()]*(?: [^\s@\[\]()]+){0,2})$/) else { return nil }
        return String(m.output.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(prompt, text: $text, axis: axis).textFieldStyle(.roundedBorder).lineLimit(axis == .vertical ? 1...4 : 1...1)
            if query != nil, !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results, id: \.url) { r in
                        Button {
                            if let q = query {
                                text = String(text.dropLast(q.count + 1)) + refMarkdown(r.title, r.url) + " "
                                results = []
                            }
                        } label: {
                            HStack {
                                Image(systemName: refSymbol(r.url)).frame(width: 16)
                                Text(r.title).lineLimit(1)
                                Spacer()
                                Text([r.kind.rawValue.replacingOccurrences(of: "_", with: " "), r.context].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4).padding(.horizontal, 6)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: query) {
            guard let q = query else { results = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            results = (try? await api.search(q)) ?? []
        }
    }
}
