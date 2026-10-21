import PDFKit
import SwiftUI

/**
 * A notebook written on here, live with every device on it (see [NotebookDocument]): pages from the
 * base PDF or blank ones, everyone's ink drawn from its outline, pictures where they were put. Here a
 * simple pen (its width following a tablet's pressure where there is one), a highlighter, and an
 * eraser that takes strokes whole, as the tablet's and the web's do.
 */
struct NotebookView: View {
    @StateObject private var model: NotebookModel

    init(path: String) {
        _model = StateObject(wrappedValue: NotebookModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Tool", selection: $model.tool) {
                    Text("Pen").tag(NotebookModel.Tool.pen)
                    Text("Highlighter").tag(NotebookModel.Tool.highlighter)
                    Text("Eraser").tag(NotebookModel.Tool.eraser)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if model.tool != .eraser {
                    ForEach(Array(model.palette.enumerated()), id: \.offset) { i, argb in
                        Button { model.color = i } label: {
                            Circle().fill(Color(nsColor: argbColor(argb | 0xff000000)))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(Color.primary, lineWidth: model.color == i ? 2 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help("Colour \(i + 1)")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            NotebookCanvas(model: model)
        }
        .task { await model.start() }
        .onDisappear { model.close() }
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
    enum Tool { case pen, highlighter, eraser }

    @Published var status = "Opening…"
    @Published var tool: Tool = .pen
    @Published var color = 0
    @Published private(set) var pdf: PDFDocument?
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
        pdf = shown
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

    /** What a stroke through [points] (x, y, pressure) on [page] will be. */
    func stroke(_ points: [Float], on page: String) -> NotebookStroke {
        let pen = tool == .pen
        let width: Float = pen ? 0.6 : 9
        return NotebookStroke(id: UUID().uuidString.lowercased(), page: page, tool: pen ? "pen" : "highlighter", color: palette[color % palette.count], width: width, points: points, outline: [outlineOf(points, width: width, pen: pen)], ink: nil, transform: nil)
    }

    func put(_ s: NotebookStroke) {
        guard s.points.count >= 3 else { return }
        notebook.edit([.putStroke(stroke: s)])
        strokes[s.page, default: [:]][s.id] = s
        redraw(s.page)
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
        if let drawing { draw(model.stroke(drawing, on: id), in: ctx) }
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
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        // The pages' overlays take the pen (rather than the PDF's text selection).
        view.pageOverlayViewProvider = model
        view.isInMarkupMode = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== model.pdf else { return }
        // Pages changed: kept at the page that was showing.
        let at = view.currentPage.flatMap { view.document?.index(for: $0) }
        view.document = model.pdf
        if let at, let page = model.pdf?.page(at: min(at, max(0, (model.pdf?.pageCount ?? 1) - 1))) { view.go(to: page) }
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
