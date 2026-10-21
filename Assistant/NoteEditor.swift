import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /** Show a drive path in Files (a link followed from a note): its path is the object. */
    static let driveReveal = Notification.Name("com.syeyoung.assistant.drive-reveal")
}

/**
 * A Markdown note, natively: the text in an NSTextView styled as the web editor's live preview (see
 * [NotePreview], with the core's structure, math and diagrams, so it looks as on Android and the
 * web), saved by [NoteDocument]. A note opens as a preview; editing is asked for (Edit). One editor
 * serves every note, so the note open before is saved when another one opens.
 */
@MainActor
final class NoteEditor: NSObject, ObservableObject, NSTextViewDelegate, NSTextStorageDelegate {
    static let shared = NoteEditor()

    /** How the note is: loading, live, connecting, offline, error, readonly. */
    @Published private(set) var state = "loading"
    @Published private(set) var message: String?
    /** The Markdown as written everywhere, instead of rendered. */
    @Published var source = false { didSet { restyle(structure: false) } }
    /** Being edited (asked for: a note opens as a preview). */
    @Published private(set) var editing = false

    /** Whether a note has been shown (so there may be something to save before quitting). */
    static private(set) var isOpen = false

    private(set) var path: String?
    private var document: NoteDocument?
    private var spans: [Span] = []
    private var loading = false
    private var preview = NotePreview(style: noteStyle(dark: false))

    private var api: API { AppModel.shared.api }

    // ---- the view ----

    private let layout = NoteLayoutManager()
    private let storage = NSTextStorage()
    private let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))

    lazy var textView: NoteTextView = {
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true
        let view = NoteTextView(frame: .zero, textContainer: container)
        view.editor = self
        view.delegate = self
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.isEditable = false
        return view
    }()

    lazy var scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { _ in
            MainActor.assumeIsolated { NoteEditor.shared.fit() }
        }
        scroll.postsFrameChangedNotifications = true
        return scroll
    }()

    private override init() {
        super.init()
        NoteCore.registerFonts()
    }

    /** The text column: at most as wide as the web's, centred, with room below the last line. */
    func fit() {
        let width = scrollView.contentSize.width
        let column = min(CGFloat(preview.style.maxWidth), width - 2 * CGFloat(preview.style.paddingHorizontal))
        let side = max(CGFloat(preview.style.paddingHorizontal), (width - column) / 2)
        textView.textContainerInset = NSSize(width: side, height: CGFloat(preview.style.paddingTop))
        preview.width = column - 2 * container.lineFragmentPadding
        preview.viewport = scrollView.contentSize.height
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        restyle(structure: false)
    }

    // ---- showing a note ----

    /** Shows the note at [path] (letting go of the one shown before), as a preview. */
    func open(_ path: String) async {
        guard path != self.path else { return }
        await document?.close()
        self.path = path
        Self.isOpen = true
        _ = textView
        storage.delegate = self
        setEditing(false)
        let document = NoteDocument(path: path, status: { [weak self] s, m in self?.state = s; self?.message = m }, remote: { [weak self] in self?.remote($0) })
        self.document = document
        do {
            show(try await document.open())
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        } catch {
            state = "error"
            message = error.localizedDescription
        }
    }

    /** Another device's edits being applied (not typed here: not sent back). */
    private var applying = false

    /** Another device's edits, as the document took them: made to the text in order, the selection moving with the text around it. */
    private func remote(_ changes: [TextChange]) {
        var selected = textView.selectedRange()
        applying = true
        storage.beginEditing()
        for c in changes {
            let from = Int(c.from), to = Int(c.to), inserted = (c.insert as NSString).length
            storage.replaceCharacters(in: NSRange(location: from, length: to - from), with: c.insert)
            let shift = { (at: Int) -> Int in at >= to ? at + inserted - (to - from) : (at > from ? from + inserted : at) }
            let start = shift(selected.location), end = shift(NSMaxRange(selected))
            selected = NSRange(location: start, length: max(0, end - start))
        }
        storage.endEditing()
        applying = false
        textView.setSelectedRange(selected)
        restyle(structure: true)
    }

    /** Characters changed (typed, pasted, or put in by the "/" list): to the other devices, as it happens. */
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let insert = (textStorage.string as NSString).substring(with: editedRange)
        MainActor.assumeIsolated {
            guard !loading, !applying else { return }
            document?.edited(from: editedRange.location, to: NSMaxRange(editedRange) - delta, insert: insert)
        }
    }

    /** Shows [text] as the note (opened, or another version): not an edit. */
    private func show(_ text: String) {
        loading = true
        let at = min(textView.selectedRange().location, (text as NSString).length)
        storage.setAttributedString(NSAttributedString(string: text))
        textView.setSelectedRange(NSRange(location: at, length: 0))
        loading = false
        restyle(structure: true)
    }

    /** The note's look in this appearance (light or dark). */
    func appearanceChanged() {
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let style = noteStyle(dark: dark)
        let images = preview.image
        preview = NotePreview(style: style)
        preview.image = images
        textView.backgroundColor = NSColor(argb: style.background)
        textView.insertionPointColor = NSColor(argb: style.text)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(argb: style.accentSoft)]
        preview.image = { [weak self] url in self?.image(url) }
        fit()
    }

    /** Restyling (which sets the selection back): its own selection changes aren't the user's. */
    private var restyling = false

    /** Styles the text again: [structure] when it changed (its spans are worked out again). */
    func restyle(structure: Bool) {
        guard path != nil, !restyling else { return }
        restyling = true
        defer { restyling = false }
        if structure { spans = markdownSpans(text: storage.string) }
        let selection = editing && textView.window?.firstResponder === textView ? textView.selectedRange() : nil
        // Typing attributes and the selection survive restyling.
        let selected = textView.selectedRange()
        preview.apply(storage, spans: spans, selection: selection, source: source)
        if textView.selectedRange() != selected { textView.setSelectedRange(selected) }
        textView.typingAttributes = [.font: NoteCore.text(CGFloat(preview.style.fontSize)), .foregroundColor: NSColor(argb: preview.style.text)]
    }

    /** Editing (cursor, Markdown where the cursor is) or a preview (all rendered, links open). Leaving editing saves. */
    func setEditing(_ on: Bool) {
        let on = on && !(document?.readOnly ?? true)
        editing = on
        textView.isEditable = on
        if on { textView.window?.makeFirstResponder(textView) }
        restyle(structure: false)
    }

    // ---- what the text view tells ----

    func textDidChange(_ notification: Notification) {
        restyle(structure: true)
        if !applying { offerBlocks() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        restyle(structure: false)
    }

    /** "/" at a line's start or after a space: the blocks it can insert (AppKit's completion list). */
    private func offerBlocks() {
        guard editing, let range = slashRange() else { return }
        _ = range
        textView.complete(nil)
    }

    /** "/" and what's typed after it, if the cursor's right after them. */
    func slashRange() -> NSRange? {
        let text = storage.string as NSString
        let cursor = textView.selectedRange().location
        guard textView.selectedRange().length == 0, cursor > 0 else { return nil }
        let line = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: cursor - line.location))
        guard let m = before.firstMatch(of: /(?:^|\s)\/([\w ]*)$/) else { return nil }
        let typed = m.output.1.utf16.count
        return NSRange(location: cursor - typed - 1, length: typed + 1)
    }

    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        guard let range = slashRange() else { return [] }
        let query = (storage.string as NSString).substring(with: range).dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
        return slashItems().filter { item in query.isEmpty || "\(item.label) \(item.keywords)".lowercased().split(separator: " ").contains { $0.hasPrefix(query) } }.map(\.label)
    }

    /** A "/" item chosen: its text in place of what was typed, the cursor where it says. */
    func insertBlock(_ label: String) {
        guard let item = slashItems().first(where: { $0.label == label }), let range = slashRange() else { return }
        textView.insertText(item.text, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + Int(item.cursor), length: 0))
    }

    // ---- clicks, keys, images ----

    /** A click on [index] in the text: a checkbox toggles (editing); a link opens (in the preview, or with ⌘). True if it was handled. */
    func clicked(at index: Int, command: Bool) -> Bool {
        guard index < storage.length else { return false }
        var range = NSRange()
        if let box = storage.attribute(.noteReplacement, at: index, effectiveRange: &range) as? CheckboxReplacement {
            guard editing else { return true }
            let text = storage.string as NSString
            let bracket = text.range(of: "[", options: [], range: range)
            if bracket.location != NSNotFound {
                textView.insertText(box.checked ? " " : "x", replacementRange: NSRange(location: bracket.location + 1, length: 1))
            }
            return true
        }
        if let url = storage.attribute(.noteLink, at: index, effectiveRange: nil) as? String, !editing || command {
            follow(url)
            return true
        }
        return false
    }

    private func follow(_ href: String) {
        if let path, let drivePath = linkPath(folder: driveParent(path), href: href) {
            NotificationCenter.default.post(name: .driveReveal, object: drivePath)
        } else if let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            // The web and mail only: no file:// or app schemes from a note.
            NSWorkspace.shared.open(url)
        }
    }

    /** ⌘B, ⌘I, ⌘K (as on the web). */
    func shortcut(_ key: String) -> Bool {
        guard editing else { return false }
        let r = textView.selectedRange()
        switch key {
        case "b", "i":
            apply(toggleWrap(text: storage.string, from: UInt32(r.location), to: UInt32(NSMaxRange(r)), mark: key == "b" ? "**" : "*"))
        case "k":
            let label = r.length > 0 ? (storage.string as NSString).substring(with: r) : "link"
            textView.insertText("[\(label)](https://)", replacementRange: r)
            textView.setSelectedRange(NSRange(location: r.location + label.utf16.count + 3, length: 8))
        default:
            return false
        }
        return true
    }

    private func apply(_ edit: Edit) {
        for c in edit.changes.sorted(by: { $0.from > $1.from }) {
            textView.insertText(c.insert, replacementRange: NSRange(location: Int(c.from), length: Int(c.to - c.from)))
        }
        textView.setSelectedRange(NSRange(location: Int(edit.anchor), length: Int(edit.head) - Int(edit.anchor)))
    }

    /** An image (pasted or dropped) uploaded into the note's attachments/ (a free name) and linked at the cursor. */
    func insertImage(_ data: Data, name: String, mime: String) {
        guard editing, let path else { return }
        let at = textView.selectedRange().location
        Task {
            do {
                let now = { let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; return f.string(from: Date()) }()
                let file = pastedName(name: name, mime: mime, now: now)
                let made = try await api.driveCreate(driveParent(path) + "attachments/" + file) { try await self.api.driveWriteNew($0, data, type: mime) }
                let link = relativeLink(folder: driveParent(path), path: made)
                let text = storage.string as NSString
                let lineStart = at == 0 || text.character(at: at - 1) == 10
                textView.insertText((lineStart ? "" : "\n") + "![](\(link))\n", replacementRange: NSRange(location: at, length: 0))
                Task { await DriveStore.shared.load(driveParent(path) + "attachments/") }
            } catch {
                message = "Couldn't add the image: \(error.localizedDescription)"
            }
        }
    }

    // ---- images in the note ----

    private var images: [String: NSImage?] = [:]

    /** The image a link in the note shows, if it's loaded; asking starts loading it (styled again when it's in). */
    func image(_ url: String) -> NSImage? {
        if let known = images[url] { return known }
        images[url] = .some(nil)
        let path = self.path
        Task {
            var data: Data?
            if let path, let drivePath = linkPath(folder: driveParent(path), href: url) {
                data = try? await api.driveRead(drivePath)?.data
            } else if let web = URL(string: url), ["http", "https"].contains(web.scheme?.lowercased() ?? "") {
                data = try? await URLSession.shared.data(from: web).0
            }
            if let data, let img = NSImage(data: data) {
                images[url] = img
                restyle(structure: false)
            }
        }
        return nil
    }

    // ---- what the screen asks ----

    /** Lets the note go (quitting, or the window closing). */
    func close() async {
        await document?.close()
    }

    /** The text as it is (for checks). */
    var text: String { storage.string }
}

/** The text view: clicks on checkboxes and links, ⌘B/I/K, the "/" list, pasted and dropped images. */
final class NoteTextView: NSTextView {
    weak var editor: NoteEditor?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        if let layout = layoutManager, let container = textContainer {
            var fraction: CGFloat = 0
            let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            if rect.contains(inContainer), let editor = MainActor.assumeIsolated({ editor }) {
                let index = layout.characterIndexForGlyph(at: glyph)
                if MainActor.assumeIsolated({ editor.clicked(at: index, command: event.modifierFlags.contains(.command)) }) { return }
            }
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers,
           MainActor.assumeIsolated({ editor?.shortcut(key) ?? false }) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /** The "/" list replaces what's typed after "/" (not a word) with the chosen block. */
    override var rangeForUserCompletion: NSRange {
        MainActor.assumeIsolated { editor?.slashRange() } ?? super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        // Only the final choice goes in (not each one passed over).
        guard flag, movement != NSCancelTextMovement else { return }
        MainActor.assumeIsolated { editor?.insertBlock(word) }
    }

    override func paste(_ sender: Any?) {
        if insertImages(from: .general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        insertImages(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /** Images on [board] (files, or image data), each uploaded and linked; false if there are none. */
    private func insertImages(from board: NSPasteboard) -> Bool {
        guard MainActor.assumeIsolated({ editor?.editing ?? false }) else { return false }
        var found = false
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL] {
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
                MainActor.assumeIsolated { editor?.insertImage(data, name: url.lastPathComponent, mime: mime) }
                found = true
            }
        }
        if !found, let png = board.data(forType: .png) {
            MainActor.assumeIsolated { editor?.insertImage(png, name: "", mime: "image/png") }
            found = true
        } else if !found, let tiff = board.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            MainActor.assumeIsolated { editor?.insertImage(png, name: "", mime: "image/png") }
            found = true
        }
        return found
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        MainActor.assumeIsolated { editor?.appearanceChanged() }
    }
}

/** The editor's scroll view, wherever a note is shown. */
private struct NoteTextHost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let view = NoteEditor.shared.scrollView
        view.removeFromSuperview()
        DispatchQueue.main.async { NoteEditor.shared.appearanceChanged() }
        return view
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    static func dismantleNSView(_ view: NSScrollView, coordinator: ()) {
        // Leaving the note (Files closed): let go of it (another note opening does that itself).
        Task { @MainActor in await NoteEditor.shared.close() }
    }
}

/** A Markdown note in Files: a preview, Edit to write in it, its save state, a source switch. */
struct NoteView: View {
    let entry: DriveEntry
    @ObservedObject private var editor = NoteEditor.shared
    @ObservedObject private var store = DriveStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: driveIcon(.markdown)).foregroundStyle(.secondary)
                Text(entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(statusText).font(.caption).foregroundStyle(editor.state == "error" || editor.state == "offline" ? .red : .secondary)
                Spacer()
                Toggle("Source", isOn: $editor.source).toggleStyle(.button).help("Show the Markdown as written")
                if !driveReadOnly(entry.path) && editor.state != "loading" {
                    if editor.editing {
                        Button("Done") { editor.setEditing(false) }.keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button { editor.setEditing(true) } label: { Label("Edit", systemImage: "pencil") }.keyboardShortcut("e", modifiers: .command)
                    }
                }
                Button("Open") { Task { await store.openExternally(entry) } }
            }
            .padding(10)
            Divider()
            NoteTextHost().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: entry.path) { await editor.open(entry.path) }
    }

    private var statusText: String {
        switch editor.state {
        case "live": "Live"
        case "connecting": "Connecting…"
        case "offline": "Offline (edits kept)"
        case "error": "Couldn't open it" + (editor.message.map { ": \($0)" } ?? "")
        case "readonly": "From PLMS · read-only"
        default: ""
        }
    }
}
