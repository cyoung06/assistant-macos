import AppKit
import CoreText

/**
 * What notes are drawn with, shared with Android and the web through the core: its fonts (text in
 * Pretendard, code in JetBrains Mono, the core's fonts/ copied into the app), registered for this
 * app and with the core once, so math and diagrams are set in them too.
 */
enum NoteCore {
    private static let once = NSLock()
    nonisolated(unsafe) private static var registered = false

    /** Registers the fonts (once): with the system for this app, and with the core. */
    static func registerFonts() {
        once.lock()
        defer { once.unlock() }
        guard !registered else { return }
        registered = true
        // The core sets text in the first font registered: Pretendard's regular.
        let files = ["Pretendard-Regular.otf", "Pretendard-SemiBold.otf", "Pretendard-Bold.otf", "JetBrainsMono-Regular.ttf"]
        let urls = files.compactMap { Bundle.main.url(forResource: $0, withExtension: nil, subdirectory: "Fonts") }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        for url in urls { if let data = try? Data(contentsOf: url) { registerFont(data: data) } }
    }

    /** The text font at [size] and [weight] (Pretendard has 400, 600 and 700). */
    static func text(_ size: CGFloat, weight: Int = 400) -> NSFont {
        registerFonts()
        let name = weight >= 700 ? "Pretendard-Bold" : weight >= 600 ? "Pretendard-SemiBold" : "Pretendard-Regular"
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
    }

    /** The code font at [size]; Hangul in code falls back to Pretendard, as on the web. */
    static func code(_ size: CGFloat) -> NSFont {
        registerFonts()
        let fallback = NSFontDescriptor(name: "Pretendard-Regular", size: size)
        let descriptor = NSFontDescriptor(fontAttributes: [.name: "JetBrainsMono-Regular", .cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension NSColor {
    /** An ARGB colour from the core. */
    convenience init(argb: UInt32) {
        self.init(srgbRed: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255, blue: CGFloat(argb & 0xff) / 255, alpha: CGFloat(argb >> 24) / 255)
    }
}

/** A drawing from the core, ready to paint: its shapes as paths (y down, as the drawing has them). */
final class Painted {
    let drawing: Drawing
    private let shapes: [(CGPath, CGColor, CGFloat)]

    init(_ drawing: Drawing) {
        self.drawing = drawing
        shapes = drawing.shapes.map { s in
            let path = CGMutablePath()
            var i = 0
            let p = s.points.map { CGFloat($0) }
            for verb in s.verbs {
                switch verb {
                case 0: path.move(to: CGPoint(x: p[i], y: p[i + 1])); i += 2
                case 1: path.addLine(to: CGPoint(x: p[i], y: p[i + 1])); i += 2
                case 2: path.addQuadCurve(to: CGPoint(x: p[i + 2], y: p[i + 3]), control: CGPoint(x: p[i], y: p[i + 1])); i += 4
                case 3: path.addCurve(to: CGPoint(x: p[i + 4], y: p[i + 5]), control1: CGPoint(x: p[i], y: p[i + 1]), control2: CGPoint(x: p[i + 2], y: p[i + 3])); i += 6
                default: path.closeSubpath()
                }
            }
            return (path, NSColor(argb: s.color).cgColor, CGFloat(s.strokeWidth))
        }
    }

    var width: CGFloat { CGFloat(drawing.width) }
    var height: CGFloat { CGFloat(drawing.height) }
    var baseline: CGFloat { CGFloat(drawing.baseline) }

    /** Paints it with its top-left at [origin] (in a flipped view), [scale] times its size. */
    func paint(in context: CGContext, at origin: CGPoint, scale: CGFloat = 1) {
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        for (path, color, stroke) in shapes {
            context.addPath(path)
            if stroke > 0 {
                context.setStrokeColor(color); context.setLineWidth(stroke); context.strokePath()
            } else {
                context.setFillColor(color); context.fillPath(using: .winding)
            }
        }
        context.restoreGState()
    }
}
