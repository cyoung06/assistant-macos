import AppKit

/**
 * The math being written, typeset (or its TeX error while it doesn't parse), shown just below it
 * while the cursor is in it (see [NoteEditor]). A view inside the text view, not a popover: it never
 * takes the keyboard from the text.
 */
final class MathTip: NSView {
    private var painted: Painted?
    /** What it shows: the math typeset (nil), or a message ([failed]: a TeX error). */
    private(set) var message: String?
    private(set) var failed = false
    private let label = NSTextField(labelWithString: "")
    private let pad: CGFloat = 8

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    /** Shows [painted] (the math typeset). */
    func show(_ painted: Painted) {
        self.painted = painted
        message = nil
        failed = false
        label.isHidden = true
        setFrameSize(NSSize(width: painted.width + pad * 2, height: painted.height + pad * 2))
        needsDisplay = true
    }

    /** Shows [message]: why it doesn't parse ([error]), or a hint. */
    func show(message: String, error: Bool) {
        painted = nil
        self.message = message
        failed = error
        label.isHidden = false
        label.stringValue = message
        label.textColor = error ? .systemRed : .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        let size = label.fittingSize
        label.frame = NSRect(x: pad, y: pad, width: min(size.width, 460), height: size.height)
        setFrameSize(NSSize(width: label.frame.width + pad * 2, height: label.frame.height + pad * 2))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.borderColor = NSColor.separatorColor.cgColor
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let painted, let context = NSGraphicsContext.current?.cgContext else { return }
        painted.paint(in: context, at: CGPoint(x: pad, y: pad))
    }

    // It shows; clicks go to the text.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
