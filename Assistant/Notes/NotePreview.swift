import AppKit

extension NSAttributedString.Key {
    /** Markdown syntax hidden while it's not being edited: no glyphs, no room. */
    static let noteHidden = NSAttributedString.Key("com.syeyoung.assistant.noteHidden")
    /** Something drawn in place of the text (a [NoteReplacement]): one glyph its size, the rest hidden. */
    static let noteReplacement = NSAttributedString.Key("com.syeyoung.assistant.noteReplacement")
    /** A code block's lines (their background is drawn). */
    static let noteCodeBlock = NSAttributedString.Key("com.syeyoung.assistant.noteCodeBlock")
    /** A quote's lines (its bar is drawn). */
    static let noteQuote = NSAttributedString.Key("com.syeyoung.assistant.noteQuote")
    /** A link: where it goes. */
    static let noteLink = NSAttributedString.Key("com.syeyoung.assistant.noteLink")
}

/** Something drawn in place of text: its size, where its baseline is (from its top), and how it's drawn. */
class NoteReplacement: NSObject {
    var size: CGSize { .zero }
    var baseline: CGFloat { size.height }
    /** Takes a line of its own (its line is sized to it), rather than sitting in the text. */
    var block: Bool { false }
    func draw(in context: CGContext, topLeft: CGPoint) {}
}

/**
 * The web editor's live preview, with AppKit's text system: a note reads as rendered (headings
 * sized, emphasis and links styled with their marks hidden, tasks as checkboxes, math typeset,
 * diagrams, tables and images drawn) except where the cursor is, which shows the Markdown as
 * written. The structure comes from the core, the same as on Android and the web.
 */
@MainActor
final class NotePreview {
    let style: NoteStyle
    /** The text's width (blocks span it), and the visible height (images take at most 60% of it). */
    var width: CGFloat = 600
    var viewport: CGFloat = 800
    /** An image by its link, if it's loaded (asking starts loading it). */
    var image: (String) -> NSImage? = { _ in nil }

    private var math: [String: Painted?] = [:]
    private var diagrams: [String: Painted?] = [:]
    private var dark: Bool { NSColor(argb: style.background).brightnessComponent < 0.5 }

    init(style: NoteStyle) { self.style = style }

    private var body: CGFloat { CGFloat(style.fontSize) }
    private var lineHeight: CGFloat { body * CGFloat(style.lineHeight) }
    private func color(_ argb: UInt32) -> NSColor { NSColor(argb: argb) }

    /** Styles [storage] by [spans]; nothing is hidden or replaced where [selection] is (or anywhere, with [source]). */
    func apply(_ storage: NSTextStorage, spans: [Span], selection: NSRange?, source: Bool) {
        let text = storage.string as NSString
        let all = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes([.font: NoteCore.text(body), .foregroundColor: color(style.text)], range: all)

        // Each paragraph's style, put together and set at the end.
        var paragraphs: [Int: NSMutableParagraphStyle] = [:]
        func paragraph(at location: Int) -> NSMutableParagraphStyle {
            let start = text.paragraphRange(for: NSRange(location: min(location, max(0, text.length - 1)), length: 0)).location
            if let p = paragraphs[start] { return p }
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = lineHeight
            p.maximumLineHeight = lineHeight
            paragraphs[start] = p
            return p
        }
        func eachParagraph(in range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            var at = range.location
            repeat {
                change(paragraph(at: at))
                let r = text.paragraphRange(for: NSRange(location: min(at, max(0, text.length - 1)), length: 0))
                at = NSMaxRange(r)
            } while at < NSMaxRange(range)
        }

        let touches = { (from: Int, to: Int) -> Bool in
            guard let s = selection else { return false }
            return s.location <= to && NSMaxRange(s) >= from
        }
        let lineRange = { (at: Int) -> NSRange in text.lineRange(for: NSRange(location: min(at, text.length), length: 0)) }
        let lineTouched = { (at: Int) -> Bool in let l = lineRange(at); return touches(l.location, NSMaxRange(l) - 1) }
        func put(_ key: NSAttributedString.Key, _ value: Any, _ from: Int, _ to: Int) {
            let r = NSRange(location: max(0, from), length: max(0, min(to, text.length) - max(0, from)))
            if r.length > 0 { storage.addAttribute(key, value: value, range: r) }
        }
        func hide(_ from: Int, _ to: Int) { put(.noteHidden, true, from, to) }
        func hideMarks(_ s: Span) { if !source { for m in s.marks { hide(Int(m.from), Int(m.to)) } } }
        func font(_ f: NSFont, _ from: Int, _ to: Int) { put(.font, f, from, to) }
        // Something drawn in place of a block of lines: its first line replaced, the rest collapsed.
        var replacedTo = -1
        func block(_ r: NoteReplacement, _ from: Int, _ to: Int) {
            replacedTo = to
            let first = lineRange(from)
            let firstEnd = min(to, NSMaxRange(first) - (text.substring(with: first).hasSuffix("\n") ? 1 : 0))
            put(.noteReplacement, r, from, firstEnd)
            eachParagraph(in: NSRange(location: from, length: 0)) { p in
                let h = r.size.height + (r.block ? 12 : 0)
                p.minimumLineHeight = max(h, lineHeight); p.maximumLineHeight = max(h, lineHeight)
            }
            if firstEnd + 1 < to {
                hide(firstEnd, to)
                eachParagraph(in: NSRange(location: firstEnd + 1, length: to - firstEnd - 1)) { p in p.minimumLineHeight = 0.01; p.maximumLineHeight = 0.01 }
            }
        }

        for s in spans {
            let from = Int(s.range.from), to = min(Int(s.range.to), text.length)
            if to <= from || from < replacedTo { continue }
            let editing = source || touches(from, to)
            switch s.element {
            case let .heading(level):
                let i = min(max(Int(level) - 1, 0), 5)
                let size = body * CGFloat(style.headingSizes[i])
                font(NoteCore.text(size, weight: 700), from, to)
                eachParagraph(in: NSRange(location: from, length: 0)) { p in
                    p.minimumLineHeight = size * 1.3; p.maximumLineHeight = size * 1.3
                    p.paragraphSpacingBefore = size * CGFloat(style.headingSpaceAbove[i])
                }
                if !lineTouched(from) { hideMarks(s) }
            case .emphasis:
                put(.obliqueness, 0.2, from, to)
                if !editing { hideMarks(s) }
            case .strong:
                storage.enumerateAttribute(.font, in: NSRange(location: from, length: to - from)) { value, r, _ in
                    let size = (value as? NSFont)?.pointSize ?? body
                    storage.addAttribute(.font, value: NoteCore.text(size, weight: 700), range: r)
                }
                if !editing { hideMarks(s) }
            case .strikethrough:
                put(.strikethroughStyle, NSUnderlineStyle.single.rawValue, from, to)
                put(.foregroundColor, color(style.textTertiary), from, to)
                if !editing { hideMarks(s) }
            case .inlineCode:
                font(NoteCore.code(body * CGFloat(style.codeSize)), from, to)
                if !editing { hideMarks(s) }
            case let .link(url):
                put(.foregroundColor, color(style.accent), from, to)
                put(.underlineStyle, NSUnderlineStyle.single.rawValue, from, to)
                put(.noteLink, url, from, to)
                if !editing { hideMarks(s) }
            case let .autolink(url):
                put(.foregroundColor, color(style.accent), from, to)
                put(.underlineStyle, NSUnderlineStyle.single.rawValue, from, to)
                put(.noteLink, url, from, to)
            case let .math(tex, display):
                if editing {
                    font(NoteCore.code(body * CGFloat(style.mathSourceSize)), from, to)
                    put(.foregroundColor, color(style.accent), from, to)
                    continue
                }
                guard let drawing = typeset(tex, display) else { continue }
                if display { block(MathReplacement(drawing, display: true, width: width), from, to) }
                else {
                    put(.noteReplacement, MathReplacement(drawing, display: false, width: width), from, to)
                    // A formula taller than the line makes the line taller (as on the web).
                    eachParagraph(in: NSRange(location: from, length: 0)) { p in p.minimumLineHeight = max(p.minimumLineHeight, drawing.height + 4); p.maximumLineHeight = max(p.maximumLineHeight, drawing.height + 4) }
                }
            case .bullet:
                if !lineTouched(from) && !source, let m = s.marks.first { put(.noteReplacement, BulletReplacement(body: body, color: color(style.textSecondary)), Int(m.from), Int(m.to)) }
            case let .task(checked):
                guard let m = s.marks.first, !touches(Int(m.from), Int(m.to)), !source else { continue }
                // "- [x]" and the space after it become the box.
                let end = Int(m.to) + (Int(m.to) < text.length && text.character(at: Int(m.to)) == 32 ? 1 : 0)
                put(.noteReplacement, CheckboxReplacement(checked: checked, body: body, style: style), Int(m.from), end)
                if checked {
                    let lineEnd = NSMaxRange(lineRange(from)) - 1
                    put(.strikethroughStyle, NSUnderlineStyle.single.rawValue, end, lineEnd)
                    put(.foregroundColor, color(style.textTertiary), end, lineEnd)
                }
            case .quote:
                put(.noteQuote, true, from, to)
                put(.noteReplacementStyle, NoteStyleBox(style), from, to)
                put(.foregroundColor, color(style.textSecondary), from, to)
                let indent = CGFloat(style.quoteBarWidth + style.quoteIndent)
                eachParagraph(in: NSRange(location: from, length: to - from)) { p in p.firstLineHeadIndent = indent; p.headIndent = indent }
                if !source { for m in s.marks where !lineTouched(Int(m.from)) { hide(Int(m.from), Int(m.to)) } }
            case .rule:
                if !lineTouched(from) && !source { put(.noteReplacement, RuleReplacement(width: width, color: color(style.rule)), from, to) }
            case let .codeBlock(language, code):
                if language.lowercased() == "mermaid", !editing, let d = diagram(code) {
                    block(PictureReplacement(painted: d, width: width, maxHeight: .greatestFiniteMagnitude), from, to)
                    continue
                }
                put(.noteCodeBlock, true, from, to)
                put(.noteReplacementStyle, NoteStyleBox(style), from, to)
                font(NoteCore.code(body * CGFloat(style.codeBlockSize)), from, to)
                let pad = CGFloat(style.codePadding)
                eachParagraph(in: NSRange(location: from, length: to - from)) { p in p.firstLineHeadIndent = pad; p.headIndent = pad; p.tailIndent = -pad }
                if !editing {
                    for m in s.marks {
                        font(NoteCore.code(body * CGFloat(style.fenceSize)), Int(m.from), Int(m.to))
                        put(.foregroundColor, color(style.textTertiary), Int(m.from), Int(m.to))
                    }
                }
            case let .table(rows, alignments):
                if editing {
                    font(NoteCore.code(body * CGFloat(style.codeBlockSize)), from, to)
                } else {
                    block(TableReplacement(rows: rows, alignments: alignments, preview: self), from, to)
                }
            case let .image(url, alt):
                if !editing {
                    if let img = image(url) { put(.noteReplacement, PictureReplacement(image: img, width: width, maxHeight: viewport * 0.6), from, to) }
                    else { put(.foregroundColor, color(style.textTertiary), from, to); _ = alt }
                }
            }
        }

        // Every paragraph at least the note's line height.
        var at = 0
        while at < text.length {
            _ = paragraph(at: at)
            at = NSMaxRange(text.paragraphRange(for: NSRange(location: at, length: 0)))
        }
        // Each line's room split above and below its text, as CSS does (TextKit puts it all above).
        for (start, p) in paragraphs {
            let r = text.paragraphRange(for: NSRange(location: min(start, max(0, text.length - 1)), length: 0))
            storage.addAttribute(.paragraphStyle, value: p, range: r)
            guard p.maximumLineHeight > 1 else { continue }
            storage.enumerateAttribute(.font, in: r) { value, run, _ in
                guard let f = value as? NSFont else { return }
                // TextKit puts a line's extra room above its text: half of it goes below instead.
                let extra = p.maximumLineHeight - (f.ascender - f.descender)
                if extra > 0 { storage.addAttribute(.baselineOffset, value: extra / 2, range: run) }
            }
        }
    }

    // ---- typesetting (cached: it's the slow part) ----

    func typeset(_ tex: String, _ display: Bool) -> Painted? {
        let key = "\(display)|\(body)|\(style.text)|\(tex)"
        if let cached = math[key] { return cached }
        let painted = (try? renderMath(tex: tex, display: display, fontSize: Float(body), color: style.text)).map(Painted.init)
        math[key] = painted
        return painted
    }

    func diagram(_ source: String) -> Painted? {
        let key = "\(dark)|\(source)"
        if let cached = diagrams[key] { return cached }
        let painted = (try? renderMermaid(source: source, dark: dark)).map(Painted.init)
        diagrams[key] = painted
        return painted
    }
}

// ---- what's drawn in place of text ----

/** Typeset math: inline on the text's baseline, or a display formula centred on its line. */
final class MathReplacement: NoteReplacement {
    let painted: Painted
    let display: Bool
    let width: CGFloat
    init(_ painted: Painted, display: Bool, width: CGFloat) { self.painted = painted; self.display = display; self.width = width }
    override var size: CGSize { CGSize(width: display ? width : painted.width, height: painted.height) }
    override var baseline: CGFloat { painted.baseline }
    override var block: Bool { display }
    override func draw(in context: CGContext, topLeft: CGPoint) {
        let x = display ? topLeft.x + max(0, (width - painted.width) / 2) : topLeft.x
        painted.paint(in: context, at: CGPoint(x: x, y: topLeft.y))
    }
}

/** A diagram (from the core) or an image, as wide as the column at most, centred (diagrams) or at the start (images). */
final class PictureReplacement: NoteReplacement {
    let painted: Painted?
    let picture: NSImage?
    let fitted: CGSize
    let width: CGFloat
    init(painted: Painted, width: CGFloat, maxHeight: CGFloat) {
        self.painted = painted; picture = nil; self.width = width
        let scale = min(1, width / max(painted.width, 1), maxHeight / max(painted.height, 1))
        fitted = CGSize(width: painted.width * scale, height: painted.height * scale)
    }
    init(image: NSImage, width: CGFloat, maxHeight: CGFloat) {
        painted = nil; picture = image; self.width = width
        // An image a pixel to each point, as browsers show them.
        let px = image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        let scale = min(1, width / max(px.width, 1), maxHeight / max(px.height, 1))
        fitted = CGSize(width: px.width * scale, height: px.height * scale)
    }
    override var size: CGSize { CGSize(width: painted != nil ? width : fitted.width, height: fitted.height) }
    override var block: Bool { true }
    override func draw(in context: CGContext, topLeft: CGPoint) {
        if let painted {
            painted.paint(in: context, at: CGPoint(x: topLeft.x + (width - fitted.width) / 2, y: topLeft.y), scale: fitted.width / painted.width)
        } else if let picture {
            let rect = CGRect(origin: topLeft, size: fitted)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/** A list item's marker as a bullet, centred in 0.9em. */
final class BulletReplacement: NoteReplacement {
    let body: CGFloat
    let color: NSColor
    init(body: CGFloat, color: NSColor) { self.body = body; self.color = color }
    override var size: CGSize { CGSize(width: body * 0.9, height: body) }
    override var baseline: CGFloat { NoteCore.text(body).ascender }
    override func draw(in context: CGContext, topLeft: CGPoint) {
        let s = NSAttributedString(string: "•", attributes: [.font: NoteCore.text(body, weight: 700), .foregroundColor: color])
        let w = s.size().width
        s.draw(at: CGPoint(x: topLeft.x + (body * 0.9 - w) / 2, y: topLeft.y))
    }
}

/** A task's checkbox (1.05em, as on the web), checked or not. */
final class CheckboxReplacement: NoteReplacement {
    let checked: Bool
    let body: CGFloat
    let style: NoteStyle
    init(checked: Bool, body: CGFloat, style: NoteStyle) { self.checked = checked; self.body = body; self.style = style }
    override var size: CGSize { CGSize(width: body * 1.5, height: body * 1.05) }
    override var baseline: CGFloat { body * 1.05 * 0.85 }
    override func draw(in context: CGContext, topLeft: CGPoint) {
        let s = body * 1.05
        let box = CGRect(x: topLeft.x, y: topLeft.y, width: s, height: s)
        let path = NSBezierPath(roundedRect: box, xRadius: s * 0.2, yRadius: s * 0.2)
        if checked {
            NSColor(argb: style.accent).setFill(); path.fill()
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + s * 0.25, y: box.minY + s * 0.52))
            tick.line(to: CGPoint(x: box.minX + s * 0.43, y: box.minY + s * 0.7))
            tick.line(to: CGPoint(x: box.minX + s * 0.76, y: box.minY + s * 0.32))
            tick.lineWidth = s * 0.12; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            NSColor(argb: style.background).setStroke(); tick.stroke()
        } else {
            path.lineWidth = s * 0.08
            NSColor(argb: style.textTertiary).setStroke(); path.stroke()
        }
    }
}

/** A thematic break as a line across. */
final class RuleReplacement: NoteReplacement {
    let width: CGFloat
    let color: NSColor
    init(width: CGFloat, color: NSColor) { self.width = width; self.color = color }
    override var size: CGSize { CGSize(width: width, height: 1) }
    override var baseline: CGFloat { 0 }
    override func draw(in context: CGContext, topLeft: CGPoint) {
        color.setFill()
        CGRect(x: topLeft.x, y: topLeft.y, width: width, height: 1).fill()
    }
}

/**
 * A GFM table drawn as one (as the web does): each cell's Markdown styled by the same preview, in
 * 0.95em text, padded 5 by 12, the header row in 600 on the code background, rules between.
 */
final class TableReplacement: NoteReplacement {
    private let cells: [[NSTextStorage]]
    private let alignments: [Alignment]
    private let columns: [CGFloat]
    private let heights: [CGFloat]
    private let style: NoteStyle

    @MainActor
    init(rows: [[String]], alignments: [Alignment], preview: NotePreview) {
        self.alignments = alignments
        style = preview.style
        let size = CGFloat(preview.style.fontSize) * 0.95
        let count = rows.map(\.count).max() ?? 0
        let cellPreview = NotePreview(style: preview.style)
        let cells: [[NSTextStorage]] = rows.enumerated().map { r, row in
            (0..<count).map { c in
                let storage = NSTextStorage(string: c < row.count ? row[c] : "")
                cellPreview.apply(storage, spans: markdownSpans(text: storage.string), selection: nil, source: false)
                storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { v, range, _ in
                    let f = v as? NSFont
                    let scaled = (f?.pointSize ?? size) * 0.95
                    let isCode = f?.fontName.hasPrefix("JetBrains") ?? false
                    storage.addAttribute(.font, value: isCode ? NoteCore.code(scaled) : NoteCore.text(scaled, weight: r == 0 ? 600 : ((f?.fontName.contains("Bold") ?? false) ? 700 : 400)), range: range)
                }
                storage.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: storage.length))
                return storage
            }
        }
        let natural = (0..<count).map { c in (cells.map { ceil($0[c].size().width) }.max() ?? 0) + 24 }
        let scale = min(1, preview.width / max(natural.reduce(0, +), 1))
        let columns = natural.map { $0 * scale }
        self.cells = cells
        self.columns = columns
        heights = cells.map { row in (row.enumerated().map { c, s in ceil(s.boundingRect(with: CGSize(width: (columns[c] - 24), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height) }.max() ?? 0) + 10 }
    }

    override var size: CGSize { CGSize(width: columns.reduce(0, +), height: heights.reduce(0, +)) }
    override var block: Bool { true }

    override func draw(in context: CGContext, topLeft: CGPoint) {
        let total = size
        NSColor(argb: style.codeBackground).setFill()
        CGRect(x: topLeft.x, y: topLeft.y, width: total.width, height: heights.first ?? 0).fill()
        var y = topLeft.y
        for (r, row) in cells.enumerated() {
            var x = topLeft.x
            for (c, cell) in row.enumerated() {
                let rect = CGRect(x: x + 12, y: y + 5, width: columns[c] - 24, height: heights[r] - 10)
                let p = NSMutableParagraphStyle()
                p.alignment = c < alignments.count ? (alignments[c] == .center ? .center : alignments[c] == .right ? .right : .left) : .left
                let aligned = NSMutableAttributedString(attributedString: cell)
                aligned.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: aligned.length))
                aligned.draw(with: rect, options: [.usesLineFragmentOrigin])
                x += columns[c]
            }
            y += heights[r]
        }
        // Borders around every cell.
        NSColor(argb: style.rule).setFill()
        var at = topLeft.y
        CGRect(x: topLeft.x, y: at, width: total.width, height: 1).fill()
        for h in heights { at += h; CGRect(x: topLeft.x, y: at - 1, width: total.width, height: 1).fill() }
        var cx = topLeft.x
        CGRect(x: cx, y: topLeft.y, width: 1, height: total.height).fill()
        for w in columns { cx += w; CGRect(x: cx - 1, y: topLeft.y, width: 1, height: total.height).fill() }
    }
}

/**
 * The text system's part of the preview: hidden syntax gets no glyphs; a replacement's first
 * character becomes one glyph its size (the rest none), and it's drawn there. Code blocks'
 * backgrounds and quotes' bars are drawn under the text.
 */
final class NoteLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func replacement(at index: Int) -> (NoteReplacement, NSRange)? {
        guard let storage = textStorage, index < storage.length else { return nil }
        var range = NSRange()
        guard let r = storage.attribute(.noteReplacement, at: index, effectiveRange: &range) as? NoteReplacement else { return nil }
        return (r, range)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            if let (_, range) = replacement(at: index) {
                properties[i] = index == range.location ? .controlCharacter : .null
            } else if storage.attribute(.noteHidden, at: index, effectiveRange: nil) != nil {
                properties[i] = .null
            }
        }
        properties.withUnsafeBufferPointer { setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange) }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        replacement(at: charIndex) != nil ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let (r, _) = replacement(at: charIndex) else { return .zero }
        return NSRect(x: glyphPosition.x, y: glyphPosition.y - r.baseline, width: r.size.width, height: r.size.height)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, let context = NSGraphicsContext.current?.cgContext else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.noteCodeBlock, in: chars) { value, range, _ in
            guard value != nil, let style = (storage.attribute(.noteReplacementStyle, at: range.location, effectiveRange: nil) as? NoteStyleBox)?.style else { return }
            let rect = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let pad = container.lineFragmentPadding
            let full = CGRect(x: origin.x + pad, y: origin.y + rect.minY, width: container.size.width - 2 * pad, height: rect.height)
            context.setFillColor(NSColor(argb: style.codeBackground).cgColor)
            context.addPath(CGPath(roundedRect: full, cornerWidth: CGFloat(style.codeRadius), cornerHeight: CGFloat(style.codeRadius), transform: nil))
            context.fillPath()
        }
        storage.enumerateAttribute(.noteQuote, in: chars) { value, range, _ in
            guard value != nil, let style = (storage.attribute(.noteReplacementStyle, at: range.location, effectiveRange: nil) as? NoteStyleBox)?.style else { return }
            // The quote's lines as laid out. Its hidden "> " end up on the line before, so a line counts
            // only when it shows some of the quote.
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { line, _, _, glyphs, _ in
                let shown = NSIntersectionRange(self.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), range)
                var visible = false
                storage.enumerateAttribute(.noteHidden, in: shown) { hidden, _, stop in if hidden == nil { visible = true; stop.pointee = true } }
                if visible { rect = rect.union(line) }
            }
            guard !rect.isNull else { return }
            context.setFillColor(NSColor(argb: style.rule).cgColor)
            context.fill(CGRect(x: origin.x + container.lineFragmentPadding, y: origin.y + rect.minY, width: CGFloat(style.quoteBarWidth), height: rect.height))
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let context = NSGraphicsContext.current?.cgContext else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.noteReplacement, in: chars) { value, range, _ in
            guard let r = value as? NoteReplacement, range.location >= chars.location else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let at = location(forGlyphAt: glyph)
            // A block at the top of its own line (padded as the line's room allows); inline, its baseline on the line's.
            let y = r.block ? line.minY + max(0, (line.height - r.size.height) / 2) : line.minY + at.y - r.baseline
            r.draw(in: context, topLeft: CGPoint(x: origin.x + line.minX + at.x, y: origin.y + y))
        }
    }
}

extension NSAttributedString.Key {
    /** The note's style, for what the layout manager draws (code backgrounds, quote bars). */
    static let noteReplacementStyle = NSAttributedString.Key("com.syeyoung.assistant.noteStyle")
}

/** The style as an attribute value. */
final class NoteStyleBox: NSObject {
    let style: NoteStyle
    init(_ style: NoteStyle) { self.style = style }
}
