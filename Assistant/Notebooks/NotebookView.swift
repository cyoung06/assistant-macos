import PDFKit
import SwiftUI

/**
 * A notebook written on here, live with every device on it (see [NotebookDocument]): pages from the
 * base PDF or blank ones, everyone's ink drawn from its outline, pictures where they were put. Here a
 * simple pen (its width following a tablet's pressure where there is one), a highlighter, and an
 * eraser that takes strokes whole, as the tablet's and the web's do; blank pages added after the page
 * in view, pages deleted (with what's on them), and pages bookmarked.
 */
struct NotebookView: View {
    @StateObject private var model: NotebookModel
    @State private var deleting = false

    init(path: String) {
        _model = StateObject(wrappedValue: NotebookModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The pages': where you are, bookmarks, adding and deleting.
            HStack(spacing: 6) {
                Circle().fill(model.status == "Live" ? Color.green : model.status.hasPrefix("Offline") || model.status.hasPrefix("Connecting") || model.status.hasPrefix("Opening") ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
                    .help(model.status)
                if model.status != "Live" { Text(model.status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !model.pageIds.isEmpty {
                    Text("\(model.current + 1) / \(model.pageIds.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                IconButton(model.bookmarked ? "Remove This Page's Bookmark" : "Bookmark This Page", symbol: model.bookmarked ? "star.fill" : "star") {
                    model.bookmark(!model.bookmarked)
                }
                .foregroundStyle(model.bookmarked ? Color.yellow : Color.primary)
                .disabled(model.pageIds.isEmpty)
                if !model.bookmarks.isEmpty {
                    Menu {
                        ForEach(Array(model.pageIds.enumerated()).filter { model.bookmarks.contains($0.element) }, id: \.element) { i, id in
                            Button("Page \(i + 1)", systemImage: "star") { model.go(to: id) }
                        }
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Go to a bookmarked page")
                }
                Divider().frame(height: 16)
                // A blank page after this one: in the look last picked, or another from the menu.
                Menu {
                    ForEach([("plain", "Plain", "doc"), ("lines", "Lines", "line.3.horizontal"), ("grid", "Grid", "squareshape.split.3x3"), ("dots", "Dots", "circle.grid.3x3")], id: \.0) { style, name, symbol in
                        Button(name, systemImage: model.style == style ? "checkmark" : symbol) { model.style = style; model.addPage() }
                    }
                } label: {
                    Label("Add Page", systemImage: "doc.badge.plus").labelStyle(.iconOnly)
                } primaryAction: {
                    model.addPage()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a blank page after this one (the menu picks its look)")
                .disabled(model.pageIds.isEmpty)
                IconButton("Delete This Page", symbol: "trash") { deleting = true }
                    .disabled(model.pageIds.count <= 1)
                    .confirmationDialog("Delete page \(model.current + 1) and what's on it?", isPresented: $deleting) {
                        Button("Delete Page", role: .destructive) { model.deletePage() }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            NotebookCanvas(model: model)
                .overlay(alignment: .topTrailing) { tools.padding(12) }
        }
        .task { await model.start() }
        .onDisappear { model.close() }
    }
}

extension NotebookView {
    /** The pen, highlighter and eraser, and the colours: a pill over the page's edge, as on the tablet. */
    private var tools: some View {
        VStack(spacing: 10) {
            ForEach([(NotebookModel.Tool.pen, "Pen", "pencil"), (.highlighter, "Highlighter", "highlighter"), (.fading, "Fading Pen (gone 4 s after you stop)", "scribble.variable"), (.eraser, "Eraser", "eraser")], id: \.1) { tool, name, symbol in
                Button { model.tool = tool } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                        .foregroundStyle(model.tool == tool ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
            if model.tool != .eraser && model.tool != .fading {
                Divider().frame(width: 22)
                ForEach(Array(model.palette.enumerated()), id: \.offset) { i, argb in
                    Button { model.color = i } label: {
                        Circle().fill(Color(nsColor: argbColor(argb | 0xff000000)))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1))
                            .overlay(Circle().stroke(Color.primary.opacity(0.85), lineWidth: model.color == i ? 2 : 0).padding(-3))
                            .frame(width: 30, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Colour \(i + 1)")
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/** ARGB as a colour. */
private func argbColor(_ argb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((argb >> 16) & 255) / 255, green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255, alpha: CGFloat(argb >> 24) / 255)
}

/** The tablet's colours (ARGB): pens, then highlighters. */
private let pens: [UInt32] = [0xff1b1b1f, 0xff1e5bd8, 0xffd93025, 0xff188038]
private let highlighters: [UInt32] = [0x66ffd600, 0x6634c759, 0x66ff7eb6, 0x6640a9ff]

@MainActor
final class NotebookModel: NSObject, ObservableObject, PDFPageOverlayViewProvider {
    /** [fading]: a pen whose writing fades 4 s after the last stroke (to point things out); never kept. */
    enum Tool { case pen, highlighter, fading, eraser }

    @Published var status = "Opening…"
    @Published var tool: Tool = .pen {
        // Another tool picked: the fading pen's writing goes now.
        didSet { if oldValue == .fading && tool != .fading && !fading.isEmpty && fadingAlpha == 1 { fadeLater(after: 0) } }
    }
    @Published var color = 0
    @Published var style = "plain"
    /** The pages' ids, in order, and the page in view (its index). */
    @Published private(set) var pageIds: [String] = []
    @Published private(set) var current = 0
    @Published private(set) var bookmarks: Set<String> = []
    var bookmarked: Bool { pageIds.indices.contains(current) && bookmarks.contains(pageIds[current]) }
    /** Where the pages show (set as it's made). */
    private weak var view: PDFView?
    var palette: [UInt32] { tool == .highlighter ? highlighters : pens }

    private let notebook: NotebookDocument
    private var baseHash = ""
    private var base: PDFDocument?
    /** Each shown page's id in the notebook. */
    private var idOf: [ObjectIdentifier: String] = [:]
    /** What's on the pages, by page id: strokes and pictures by their ids. */
    private(set) var strokes: [String: [String: NotebookStroke]] = [:]
    private(set) var pictures: [String: [String: NotebookImage]] = [:]
    /** Pictures' images, by hash, once fetched. */
    private(set) var images: [String: CGImage] = [:]
    /** The pages showing now, by page id (each draws what's on its page). */
    private var overlays: [String: Weak] = [:]
    private var closed = false

    private struct Weak { weak var view: PageInk? }

    init(path: String) {
        notebook = NotebookDocument(path: path)
        super.init()
        notebook.changed = { [weak self] in self?.changed($0) }
        notebook.status = { [weak self] state, message in
            self?.status = switch state {
            case "live": "Live"
            case "connecting": "Connecting…"
            case "offline": "Offline (kept)"
            default: message ?? state
            }
        }
    }

    func start() async {
        do {
            try await notebook.open()
            status = "Live"
            await rebuild()
            await restorePlace()
        } catch {
            status = error.localizedDescription
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        Task { await notebook.close() }
    }

    // ---- shown ----

    /** The pages as the notebook has them now, with everything on them. */
    private func rebuild() async {
        if notebook.base != baseHash {
            baseHash = notebook.base
            base = nil
            if !baseHash.isEmpty {
                do { base = PDFDocument(data: try await NotebookDocument.blob(baseHash)) } catch { status = "Couldn't load the PDF" }
            }
        }
        let shown = PDFDocument()
        idOf = [:]
        for p in notebook.pages {
            let page = (p.base >= 0 ? base?.page(at: Int(p.base))?.copy() as? PDFPage : nil) ?? blank(p)
            shown.insert(page, at: shown.pageCount)
            idOf[ObjectIdentifier(page)] = p.id
        }
        strokes = [:]
        for s in notebook.strokes { strokes[s.page, default: [:]][s.id] = s }
        pictures = [:]
        for i in notebook.images { put(i) }
        pageIds = notebook.pages.map(\.id)
        bookmarks = Set(notebook.bookmarks)
        show(shown)
    }

    /** [document] shown, kept at the page that was showing. */
    private func show(_ document: PDFDocument) {
        self.shown = document
        guard let view else { return }
        let was = current
        view.document = document
        let index = min(was, max(0, document.pageCount - 1))
        if let page = document.page(at: index) { view.go(to: page) }
        current = index
    }

    /** What's shown (until a view shows it). */
    private var shown: PDFDocument?

    func attach(_ view: PDFView) {
        self.view = view
        if let shown { view.document = shown }
    }

    /** The page in view changed (PDFKit says). */
    func scrolled() {
        guard let view, let page = view.currentPage, let i = view.document?.index(for: page) else { return }
        if current != i { current = i }
        if !placing { place.keep(notebook.path, page: i, tool: toolName) }
    }

    // Where it was left (on any device): opened there, with the tool in hand.
    private let place = PlaceKeeper()
    private var placing = true
    private var toolName: String { switch tool { case .pen: "pen"; case .highlighter: "highlighter"; case .fading: "fading"; case .eraser: "eraser" } }

    private func restorePlace() async {
        if let (page, t) = try? await AppModel.shared.api.drivePlace(notebook.path) {
            if let page, page < pageIds.count { go(to: pageIds[page]) }
            switch t { case "pen": tool = .pen; case "highlighter": tool = .highlighter; case "fading": tool = .fading; case "eraser": tool = .eraser; default: break }
        }
        placing = false
    }

    private var blanks: [String: PDFDocument] = [:]

    /** A blank page in its style: the core's drawing of it, as a one-page PDF. */
    private func blank(_ p: NotebookPage) -> PDFPage {
        let key = "\(p.style) \(p.width) \(p.height)"
        let doc = blanks[key] ?? PDFDocument(data: onePagePDF(blankPage(style: p.style, width: p.width, height: p.height), width: p.width, height: p.height)) ?? PDFDocument()
        blanks[key] = doc
        return (doc.page(at: 0)?.copy() as? PDFPage) ?? PDFPage()
    }

    private func put(_ i: NotebookImage) {
        pictures[i.page, default: [:]][i.id] = i
        guard images[i.blob] == nil else { return }
        Task {
            guard let data = try? await NotebookDocument.blob(i.blob), let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            images[i.blob] = image
            redraw(i.page)
        }
    }

    private func redraw(_ page: String) { overlays[page]?.view?.needsDisplay = true }

    private func changed(_ changes: [NotebookChange]) {
        if changes.contains(where: { if case .pages = $0 { true } else if case .base = $0 { true } else { false } }) {
            Task { await rebuild() }
            return
        }
        for c in changes {
            switch c {
            case .stroke(let id, let stroke):
                for (page, on) in strokes where on[id] != nil { strokes[page]?[id] = nil; redraw(page) }
                if let stroke { strokes[stroke.page, default: [:]][id] = stroke; redraw(stroke.page) }
            case .image(let id, let image):
                for (page, on) in pictures where on[id] != nil { pictures[page]?[id] = nil; redraw(page) }
                if let image { put(image); redraw(image.page) }
            case .bookmarks:
                bookmarks = Set(notebook.bookmarks)
            default: break
            }
        }
    }

    // ---- the pages' overlays (PDFKit's, one on each page showing) ----

    nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        MainActor.assumeIsolated {
            guard let id = idOf[ObjectIdentifier(page)] else { return nil }
            let ink = PageInk(model: self, page: page, id: id, in: view)
            overlays[id] = Weak(view: ink)
            return ink
        }
    }

    // ---- written here ----

    /** A blank page in [style] after the page in view, its size; shown once added. */
    func addPage() {
        let pages = notebook.pages
        guard !pages.isEmpty else { return }
        let at = min(current, pages.count - 1)
        let page = NotebookPage(id: UUID().uuidString.lowercased(), base: -1, style: style, width: pages[at].width, height: pages[at].height)
        notebook.edit([.insertPage(index: UInt32(at + 1), page: page)])
        Task {
            await rebuild()
            go(to: page.id)
        }
    }

    /** The page in view gone, with what's on it. */
    func deletePage() {
        guard pageIds.indices.contains(current), pageIds.count > 1 else { return }
        notebook.edit([.removePage(id: pageIds[current])])
        Task { await rebuild() }
    }

    func bookmark(_ on: Bool) {
        guard pageIds.indices.contains(current) else { return }
        let id = pageIds[current]
        notebook.edit([.bookmark(page: id, on: on)])
        if on { bookmarks.insert(id) } else { bookmarks.remove(id) }
    }

    func go(to id: String) {
        guard let i = pageIds.firstIndex(of: id), let page = view?.document?.page(at: i) else { return }
        view?.go(to: page)
        current = i
    }

    /** What a stroke through [points] (x, y, pressure) on [page] will be. */
    func stroke(_ points: [Float], on page: String) -> NotebookStroke {
        // The fading pen: a laser pointer's red line (its white core is drawn over it, see laserCore).
        if tool == .fading {
            return NotebookStroke(id: UUID().uuidString.lowercased(), page: page, tool: "fading", color: 0xffe53935, width: 3.2, points: points, outline: [outlineOf(points, width: 3.2, pen: false)], ink: nil, transform: nil)
        }
        let pen = tool != .highlighter
        let width: Float = pen ? 0.6 : 9
        return NotebookStroke(id: UUID().uuidString.lowercased(), page: page, tool: pen ? "pen" : "highlighter", color: palette[color % palette.count], width: width, points: points, outline: [outlineOf(points, width: width, pen: pen)], ink: nil, transform: nil)
    }

    func put(_ s: NotebookStroke) {
        guard s.points.count >= 3 else { return }
        // The fading pen's: shown until it fades, not the notebook's.
        if tool == .fading {
            fading[s.page, default: []].append(s)
            redraw(s.page)
            fadeLater()
            return
        }
        notebook.edit([.putStroke(stroke: s)])
        strokes[s.page, default: [:]][s.id] = s
        redraw(s.page)
    }

    // ---- the fading pen: writing that goes 4 s after the last stroke, never kept ----

    /** The fading pen's writing, by page, until it fades; how much of it shows (1, down to 0 as it fades). */
    private(set) var fading: [String: [NotebookStroke]] = [:]
    private(set) var fadingAlpha: CGFloat = 1
    private var fadeWait: Task<Void, Never>?

    /** A laser stroke's white core. */
    func laserCore(_ s: NotebookStroke) -> NotebookStroke {
        NotebookStroke(id: s.id + "-core", page: s.page, tool: "fading", color: 0xffffffff, width: 1.1, points: s.points, outline: [outlineOf(s.points, width: 1.1, pen: false)], ink: nil, transform: nil)
    }

    /** Writing with the fading pen again: what's there stays (shown again if fading), the wait starts over. */
    func keepFading() {
        fadeWait?.cancel()
        fadeWait = nil
        if fadingAlpha != 1 { fadingAlpha = 1; fading.keys.forEach(redraw) }
    }

    private func fadeLater(after: Double = 4) {
        keepFading()
        fadeWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(after))
            // Faded over a little over half a second, then gone.
            for step in 1...18 {
                guard !Task.isCancelled, let self else { return }
                self.fadingAlpha = 1 - CGFloat(step) / 18
                self.fading.keys.forEach(self.redraw)
                try? await Task.sleep(for: .milliseconds(33))
            }
            guard !Task.isCancelled, let self else { return }
            let pages = Array(self.fading.keys)
            self.fading = [:]
            self.fadingAlpha = 1
            pages.forEach(self.redraw)
        }
    }

    /** The eraser went over [at] (the notebook's points) on [page]: strokes within [r] of it go. */
    func erase(on page: String, at: [CGPoint], r: Float) {
        let hit = (strokes[page] ?? [:]).filter { _, s in at.contains { p in hits(s, Float(p.x), Float(p.y), r) } }.map(\.key)
        guard !hit.isEmpty else { return }
        notebook.edit(hit.map { NotebookEdit.removeStroke(id: $0) })
        for id in hit { strokes[page]?[id] = nil }
        redraw(page)
    }
}

// ---- drawing and writing on a page ----

/** What's written on one page, over it (PDFKit's page overlay), and where the pen and eraser go on it. */
final class PageInk: NSView {
    private weak var model: NotebookModel?
    private weak var pdfView: PDFView?
    let page: PDFPage
    let id: String
    /** The stroke being written: its points (x, y, pressure). */
    private(set) var drawing: [Float]?
    /** Where the eraser last was: it takes what it passed over since, not just where events land. */
    private var rubbed: CGPoint?

    init(model: NotebookModel, page: PDFPage, id: String, in pdfView: PDFView) {
        self.model = model
        self.page = page
        self.id = id
        self.pdfView = pdfView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    /** From the notebook's terms (from the crop box's top left, y down) to this view's. */
    private var fromNotebook: CGAffineTransform? {
        guard let pdfView else { return nil }
        let crop = page.bounds(for: .cropBox)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { convert(pdfView.convert(CGPoint(x: crop.minX + x, y: crop.maxY - y), from: page), from: pdfView) }
        let o = at(0, 0), x = at(1, 0), y = at(0, 1)
        return CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let t = fromNotebook, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.concatenate(t)
        // In the notebook's terms from here: y down, so pictures are drawn flipped back.
        for i in (model.pictures[id] ?? [:]).values {
            guard let image = model.images[i.blob], i.rect.count == 4 else { continue }
            let r = i.rect, c = i.crop.count == 4 ? i.crop : [0, 0, 1, 1]
            let fw = r[2] / max(c[2] - c[0], 0.0001), fh = r[3] / max(c[3] - c[1], 0.0001)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(r[0]), y: CGFloat(r[1]), width: CGFloat(r[2]), height: CGFloat(r[3])))
            ctx.translateBy(x: CGFloat(r[0] - c[0] * fw), y: CGFloat(r[1] - c[1] * fh + fh))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(fw), height: CGFloat(fh)))
            ctx.restoreGState()
        }
        for s in (model.strokes[id] ?? [:]).values { draw(s, in: ctx) }
        if let fading = model.fading[id], !fading.isEmpty {
            ctx.setAlpha(model.fadingAlpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for s in fading { draw(s, in: ctx); draw(model.laserCore(s), in: ctx) }
            ctx.endTransparencyLayer()
            ctx.setAlpha(1)
        }
        if let drawing {
            let s = model.stroke(drawing, on: id)
            draw(s, in: ctx)
            if model.tool == .fading { draw(model.laserCore(s), in: ctx) }
        }
        ctx.restoreGState()
    }

    private func draw(_ s: NotebookStroke, in ctx: CGContext) {
        ctx.saveGState()
        if let t = s.transform, t.count == 6 {
            ctx.concatenate(CGAffineTransform(a: CGFloat(t[0]), b: CGFloat(t[1]), c: CGFloat(t[2]), d: CGFloat(t[3]), tx: CGFloat(t[4]), ty: CGFloat(t[5])))
        }
        if s.tool == "highlighter" { ctx.setBlendMode(.multiply) }
        let color = argbColor(s.color).cgColor
        let outline = s.outline.filter { $0.count >= 6 }
        if outline.isEmpty {
            // No outline: its centre line, as wide as the stroke.
            ctx.addLines(between: stride(from: 0, to: s.points.count - 2, by: 3).map { CGPoint(x: CGFloat(s.points[$0]), y: CGFloat(s.points[$0 + 1])) })
            ctx.setStrokeColor(color)
            ctx.setLineWidth(CGFloat(s.width))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        } else {
            for poly in outline {
                ctx.addLines(between: stride(from: 0, to: poly.count - 1, by: 2).map { CGPoint(x: CGFloat(poly[$0]), y: CGFloat(poly[$0 + 1])) })
                ctx.closePath()
            }
            ctx.setFillColor(color)
            ctx.fillPath(using: .winding)
        }
        ctx.restoreGState()
    }

    // ---- the pen and the eraser ----

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /** Where [event] is, in the notebook's terms. */
    private func point(_ event: NSEvent) -> CGPoint? {
        fromNotebook.map { convert(event.locationInWindow, from: nil).applying($0.inverted()) }
    }

    private func pressure(_ event: NSEvent) -> Float {
        event.subtype == .tabletPoint && event.pressure > 0 ? event.pressure : 0.5
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let p = point(event) else { return }
        if model.tool == .eraser {
            rubbed = nil
            rub(to: p)
            return
        }
        if model.tool == .fading { model.keepFading() }
        drawing = [Float(p.x), Float(p.y), pressure(event)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let p = point(event) else { return }
        if model.tool == .eraser { return rub(to: p) }
        guard drawing != nil else { return }
        drawing! += [Float(p.x), Float(p.y), pressure(event)]
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let drawing, let model { model.put(model.stroke(drawing, on: id)) }
        drawing = nil
        rubbed = nil
        needsDisplay = true
    }

    private func rub(to p: CGPoint) {
        let from = rubbed ?? p
        let steps = max(1, Int((hypot(p.x - from.x, p.y - from.y) / 3).rounded(.up)))
        let at = (0...steps).map { i in CGPoint(x: from.x + (p.x - from.x) * CGFloat(i) / CGFloat(steps), y: from.y + (p.y - from.y) * CGFloat(i) / CGFloat(steps)) }
        model?.erase(on: id, at: at, r: 6)
        rubbed = p
    }
}

private struct NotebookCanvas: NSViewRepresentable {
    @ObservedObject var model: NotebookModel

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.scrolled() }
        }
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        // The pages' overlays take the pen (rather than the PDF's text selection).
        view.pageOverlayViewProvider = model
        view.isInMarkupMode = true
        model.attach(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { observer.map(NotificationCenter.default.removeObserver) }
    }
}

// ---- shapes ----

/** The filled shape of a stroke through [pts] (x, y, pressure): its sides [width] apart (by pressure for a pen), round at the ends. As the web's. */
func outlineOf(_ pts: [Float], width: Float, pen: Bool) -> [Float] {
    let n = pts.count / 3
    guard n > 0 else { return [] }
    func half(_ i: Int) -> Float { pen ? (width / 2) * (0.4 + 1.2 * pts[i * 3 + 2]) : width / 2 }
    if n == 1 {
        let r = half(0)
        return (0..<12).flatMap { k -> [Float] in
            let a = Float(k) * .pi / 6
            return [pts[0] + r * cos(a), pts[1] + r * sin(a)]
        }
    }
    var left: [Float] = []
    var right: [Float] = []
    for i in 0..<n {
        let a = max(0, i - 1)
        let b = min(n - 1, i + 1)
        var dx = pts[b * 3] - pts[a * 3]
        var dy = pts[b * 3 + 1] - pts[a * 3 + 1]
        let len = max(hypot(dx, dy), 0.000001)
        dx /= len
        dy /= len
        let h = half(i)
        left += [pts[i * 3] - dy * h, pts[i * 3 + 1] + dx * h]
        right += [pts[i * 3] + dy * h, pts[i * 3 + 1] - dx * h]
    }
    // Round ends: half circles around the first and last points.
    func cap(_ i: Int, _ from: Float) -> [Float] {
        let h = half(i)
        return (1..<6).flatMap { k -> [Float] in
            let a = from + Float(k) * .pi / 6
            return [pts[i * 3] + h * cos(a), pts[i * 3 + 1] + h * sin(a)]
        }
    }
    func dir(_ i: Int, _ j: Int) -> Float { atan2(pts[j * 3 + 1] - pts[i * 3 + 1], pts[j * 3] - pts[i * 3]) }
    var reversed: [Float] = []
    for i in stride(from: right.count - 2, through: 0, by: -2) { reversed += [right[i], right[i + 1]] }
    return left + cap(n - 1, dir(n - 2, n - 1) - .pi / 2) + reversed + cap(0, dir(1, 0) - .pi / 2)
}

/** Whether a circle of [r] at ([x], [y]) touches stroke [s] (its centre line, moved as it was). */
func hits(_ s: NotebookStroke, _ x: Float, _ y: Float, _ r: Float) -> Bool {
    let p = s.points
    let t = s.transform.flatMap { $0.count == 6 ? $0 : nil }
    func at(_ i: Int) -> (Float, Float) {
        let px = p[i * 3], py = p[i * 3 + 1]
        guard let t else { return (px, py) }
        return (t[0] * px + t[2] * py + t[4], t[1] * px + t[3] * py + t[5])
    }
    let reach = r + s.width / 2
    for i in 0..<(p.count / 3) {
        let (ax, ay) = at(i)
        if i == 0 && hypot(ax - x, ay - y) <= reach { return true }
        if i > 0 {
            let (bx, by) = at(i - 1)
            let dx = ax - bx, dy = ay - by
            let len = dx * dx + dy * dy
            let u = len == 0 ? 0 : max(0, min(1, ((x - bx) * dx + (y - by) * dy) / len))
            if hypot(bx + u * dx - x, by + u * dy - y) <= reach { return true }
        }
    }
    return false
}

/** A one-page PDF of [content] (a content stream) on a [width] by [height] page. */
func onePagePDF(_ content: String, width: Float, height: Float) -> Data {
    let stream = Data(content.utf8)
    var out = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = []
    func object(_ body: Data) {
        offsets.append(out.count)
        out += Data("\(offsets.count) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
    }
    object(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
    object(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
    object(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Resources << >> /Contents 4 0 R >>".utf8))
    object(Data("<< /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("\nendstream".utf8))
    let xref = out.count
    out += Data("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n".utf8)
    for o in offsets { out += Data(String(format: "%010d 00000 n \n", o).utf8) }
    out += Data("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
    return out
}
