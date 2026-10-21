import PDFKit
import SwiftUI

/**
 * Diagnostics (from a terminal only): `Assistant.app/Contents/MacOS/Assistant -checkNotebook <path>
 * [-notebookSnapshot <file.png>]` opens the notebook at <path> (a PDF in the drive) off screen as Files
 * would, writes a stroke on its first page with the mouse (the server writes the PDF), erases it again,
 * adds a grid page after it, bookmarks that and deletes it again (each seen by a second connection, as
 * another device would), prints what passed, and quits. With -notebookSnapshot, the first page with that stroke on it is drawn
 * to a PNG, as it shows.
 */
@MainActor
enum NotebookCheck {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-checkNotebook"), i + 1 < args.count else { return }
        Task {
            let ok = await run(path: args[i + 1], snapshot: args.firstIndex(of: "-notebookSnapshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
            print(ok ? "NOTEBOOK CHECK: PASS" : "NOTEBOOK CHECK: FAIL")
            exit(ok ? 0 : 1)
        }
    }

    private static func run(path: String, snapshot: String?) async -> Bool {
        var ok = true
        func check(_ what: String, _ passed: Bool) {
            print("\(passed ? "✓" : "✗") \(what)")
            ok = ok && passed
        }
        func wait(_ what: () -> Bool) async { for _ in 0..<100 where !what() { try? await Task.sleep(for: .milliseconds(100)) } }

        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: NotebookView(path: path))
        window.orderFront(nil)
        var view: PDFView?
        await wait { view = find(PDFView.self, in: window.contentView); return view?.document != nil }
        guard let view, let model = view.pageOverlayViewProvider as? NotebookModel, let doc = view.document, let page = doc.page(at: 0) else {
            check("opens the notebook live", false)
            return false
        }
        view.layoutDocumentView()
        view.go(to: page)
        var ink: PageInk?
        await wait { ink = find(PageInk.self, in: view); return ink?.page === page }
        guard let ink else { check("puts its ink over the first page", false); return false }
        check("opens the notebook live (\(model.status)): \(doc.pageCount) pages, \(model.strokes[ink.id]?.count ?? 0) strokes on the first", model.status == "Live")

        // A stroke across the top of the first page, with the mouse.
        let crop = page.bounds(for: .cropBox)
        let points = (0...10).map { k in CGPoint(x: crop.minX + crop.width * (0.2 + 0.05 * CGFloat(k)), y: crop.maxY - 40 - CGFloat(k)) }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            let inWindow = view.convert(view.convert(p, from: page), to: nil)
            return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = Set((model.strokes[ink.id] ?? [:]).keys)
        model.tool = .pen
        model.color = 2
        // Where the mouse lands: the page's overlay, as PDFKit hit-tests it in markup mode.
        check("the pen goes to the page's overlay", view.window?.contentView?.hitTest(view.window!.contentView!.convert(event(.leftMouseDown, points[0]).locationInWindow, from: nil)) === ink)
        ink.mouseDown(with: event(.leftMouseDown, points[0]))
        for p in points.dropFirst() { ink.mouseDragged(with: event(.leftMouseDragged, p)) }
        ink.mouseUp(with: event(.leftMouseUp, points.last!))
        let added = (model.strokes[ink.id] ?? [:]).values.filter { !before.contains($0.id) }
        check("writes a stroke where the mouse went (\(added.count) new)", added.count == 1 && abs(CGFloat(added.first?.points.first ?? 0) - (points[0].x - crop.minX)) < 1)
        guard let stroke = added.first else { return false }

        if let snapshot {
            try? await Task.sleep(for: .seconds(1))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
            }
            check("drew it to \(snapshot)", FileManager.default.fileExists(atPath: snapshot))
        }

        check("the server writes it into the PDF", await written(path) { $0.contains(stroke.id) })

        // Erased with the eraser, swept across it.
        model.tool = .eraser
        let mid = points[5]
        ink.mouseDown(with: event(.leftMouseDown, CGPoint(x: mid.x, y: mid.y + 20)))
        ink.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: mid.x, y: mid.y - 20)))
        ink.mouseUp(with: event(.leftMouseUp, CGPoint(x: mid.x, y: mid.y - 20)))
        check("erases it", model.strokes[ink.id]?[stroke.id] == nil)
        check("the server takes it out of the PDF", await written(path) { !$0.contains(stroke.id) })

        // Pages and bookmarks, as another device sees them.
        let other = NotebookDocument(path: path)
        do { try await other.open() } catch { check("opens it a second time", false); return false }
        let count = model.pageIds.count
        model.style = "grid"
        model.addPage()
        await wait { model.pageIds.count == count + 1 && model.current == 1 }
        let newPage = model.pageIds.count > 1 ? model.pageIds[1] : ""
        check("adds a grid page after the one in view, and shows it (page \(model.current + 1) of \(model.pageIds.count))", model.pageIds.count == count + 1 && model.current == 1)
        if let snapshot {
            try? await Task.sleep(for: .seconds(1))
            let second = snapshot.replacingOccurrences(of: ".png", with: "-added.png")
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: second))
            }
            check("drew the new page to \(second)", FileManager.default.fileExists(atPath: second))
        }
        await wait { other.pages.contains { $0.id == newPage } }
        check("another device gets it, a grid page", other.pages.first { $0.id == newPage }?.style == "grid")
        model.bookmark(true)
        await wait { other.bookmarks.contains(newPage) }
        check("another device gets its bookmark", other.bookmarks.contains(newPage))
        model.deletePage()
        await wait { !other.pages.contains { $0.id == newPage } }
        check("deletes it, its bookmark with it", model.pageIds.count == count && !other.pages.contains { $0.id == newPage } && !other.bookmarks.contains(newPage))
        await other.close()
        model.close()
        try? await Task.sleep(for: .milliseconds(500))
        return ok
    }

    private static func find<V: NSView>(_ type: V.Type, in view: NSView?) -> V? {
        guard let view else { return nil }
        if let v = view as? V { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    /** Whether the drive's PDF comes to have stroke ids (its ink annotations' AssistantId) that pass [test], within ten seconds. */
    private static func written(_ path: String, _ test: (Set<String>) -> Bool) async -> Bool {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let read = try? await AppModel.shared.api.driveRead(path), let pdf = PDFDocument(data: read.data) else { continue }
            var ids = Set<String>()
            for i in 0..<pdf.pageCount {
                for a in pdf.page(at: i)?.annotations ?? [] {
                    if let id = a.annotationKeyValues[PDFAnnotationKey(rawValue: "/AssistantId")] as? String { ids.insert(id) }
                }
            }
            if test(ids) { return true }
        }
        return false
    }
}
