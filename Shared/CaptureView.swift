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
    var onDone: () -> Void

    @State private var mode = 0
    @State private var title = ""
    @State private var due: Due?
    @State private var projectId: String?
    @State private var projects: [Project] = []
    @State private var busy = false
    @State private var error: String?
    @State private var proposals: [Pick] = []
    @State private var analyzed = false
    @State private var uploaded: [String] = []

    struct Pick: Identifiable {
        let id = UUID()
        let proposal: Proposal
        var keep = true
        var title: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) {
                Text("Quick task").tag(0)
                Text("Analyze").tag(1)
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

            if mode == 0 { quickTask } else { analyze }

            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding(16)
        .onDrop(of: [.image, .fileURL, .text, .url], isTargeted: nil) { providers in
            Task { await take(providers) }
            return true
        }
        .onPasteCommand(of: [.image, .png, .tiff, .text, .url]) { providers in Task { await take(providers) } }
        .task {
            projects = (try? await api.projects()) ?? []
            if title.isEmpty { await prefill() }
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
            _ = try await api.create(.init(attachmentIds: ids, description: text.count > 120 || text.contains("\n") ? text : nil, due: due, projectId: projectId, title: title.trimmingCharacters(in: .whitespaces)))
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    // ---- analyze --------------------------------------------------------------------

    private var analyze: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text to read, or a note for the model (optional)", text: $text, axis: .vertical).lineLimit(2...6)
            if !analyzed {
                HStack {
                    Text(images.isEmpty ? "Paste or drop screenshots here." : "\(images.count) image(s)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Button(busy ? "Reading…" : "Analyze") { Task { await runAnalyze() } }
                        .keyboardShortcut(.defaultAction).disabled(busy || (images.isEmpty && text.isEmpty))
                }
            } else {
                if proposals.isEmpty { Text("Nothing to track found.").foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($proposals) { $p in
                            HStack(alignment: .top) {
                                Toggle("", isOn: $p.keep).labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    TextField("Title", text: $p.title).textFieldStyle(.roundedBorder)
                                    Text(describe(p.proposal)).font(.caption).foregroundStyle(.secondary)
                                    if !p.proposal.description.isEmpty { Text(p.proposal.description).font(.caption) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                HStack {
                    Button("Again") { analyzed = false; proposals = [] }
                    Spacer()
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Button("Create \(proposals.filter(\.keep).count)") { Task { await createPicked() } }
                        .keyboardShortcut(.defaultAction).disabled(busy || !proposals.contains(where: \.keep))
                }
            }
        }
    }

    private func runAnalyze() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let ids = try await uploadImages()
            proposals = try await api.analyze(text: text, attachmentIds: ids).map { Pick(proposal: $0, title: $0.title) }
            analyzed = true
        } catch { self.error = error.localizedDescription }
    }

    private func createPicked() async {
        busy = true
        defer { busy = false }
        do {
            let firstTask = proposals.firstIndex { $0.keep && $0.proposal.kind != "event" }
            for (i, p) in proposals.enumerated() where p.keep {
                let x = p.proposal
                if x.kind == "event" {
                    try await api.createEvent(.init(end: x.end, endDate: x.endDate, notes: x.description, start: x.start, startDate: x.startDate, title: p.title))
                } else {
                    // The screenshots go with the first task made from them.
                    _ = try await api.create(.init(
                        attachmentIds: i == firstTask ? uploaded : nil, description: x.description, due: x.due, labelIds: x.labelIds,
                        priority: x.priority.flatMap { .init(rawValue: $0.rawValue) }, projectId: x.projectId, title: p.title
                    ))
                }
            }
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    private func describe(_ p: Proposal) -> String {
        let project = projects.first { $0.id == p.projectId }?.name
        let f = DateFormatter()
        f.timeZone = seoul
        f.dateFormat = "MMM d HH:mm"
        var when: String
        if p.kind == "event", let s = p.start, let e = p.end {
            when = "Event · \(f.string(from: s))–" + { f.dateFormat = "HH:mm"; return f.string(from: e) }()
        } else if p.kind == "event", let d = p.startDate {
            when = "Event · \(d) (all day)"
        } else if let due = p.due {
            when = "Task · due \(dueText(due, today: todayString))"
        } else {
            when = "Task · no due date"
        }
        return [when, project].compactMap { $0 }.joined(separator: " · ")
    }

    // ---- paste and drop ---------------------------------------------------------------

    private func take(_ providers: [NSItemProvider]) async {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), let data = await p.imageData() {
                images.append(CapturedImage(data: data, name: "screenshot.png", mimeType: "image/png"))
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = try? await p.loadURL(), let data = try? Data(contentsOf: url),
                      let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                images.append(CapturedImage(data: data, name: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "image/png"))
            } else if let s = try? await p.loadString() {
                text = text.isEmpty ? s : text + "\n" + s
            }
        }
        if !images.isEmpty { mode = 1 }
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
