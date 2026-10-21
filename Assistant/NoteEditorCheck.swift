import AppKit

/**
 * Diagnostics (from a terminal only): `Assistant.app/Contents/MacOS/Assistant -checkNoteEditor
 * [-noteSnapshot <file.png> -noteSource <note.md>]` writes a throwaway note under "No project",
 * opens it in the editor off screen (as a preview), edits it (the server writes the file), writes
 * it elsewhere (the editor shows that as it comes), prints what passed, deletes what it made, and quits. With -noteSnapshot, the note
 * (from -noteSource, or the check's own) is also drawn to a PNG, as it shows.
 */
@MainActor
enum NoteEditorCheck {
    static func runIfAsked() {
        guard CommandLine.arguments.contains("-checkNoteEditor") else { return }
        Task {
            let ok = await run()
            print(ok ? "NOTE EDITOR CHECK: PASS" : "NOTE EDITOR CHECK: FAIL")
            exit(ok ? 0 : 1)
        }
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        return args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    private static func run() async -> Bool {
        let api = AppModel.shared.api
        let editor = NoteEditor()
        let folder = "Projects/No project/"
        let path = folder + "zz-mac-editor-test.md"
        var ok = true
        func check(_ what: String, _ passed: Bool) {
            print("\(passed ? "✓" : "✗") \(what)")
            ok = ok && passed
        }
        func wait(_ what: () -> Bool) async { for _ in 0..<100 where !what() { try? await Task.sleep(for: .milliseconds(100)) } }

        // The editor shown off screen, as Files would (dark, as the app usually is).
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = editor.scrollView
        editor.appearanceChanged()

        let note = argument("-noteSource").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "# Check\n\nInline $x^2$ math, **bold**.\n"
        do {
            try await api.driveWrite(path, Data(note.utf8), type: "text/markdown")
            await editor.open(path)
            await wait { editor.state == "live" }
            check("opens the note live, as a preview (state \(editor.state), editing \(editor.editing))", editor.state == "live" && !editor.editing)
            editor.fit()
            check("shows it rendered (math drawn, marks hidden)", hasReplacement(editor) && editor.text == note)

            if let snapshot = argument("-noteSnapshot") {
                try? await Task.sleep(for: .seconds(1))
                let view = editor.scrollView
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
                    check("drew it to \(snapshot)", true)
                }
            }

            // Editing: what's typed goes to the server, which writes the file a second later.
            editor.setEditing(true)
            check("edits when asked", editor.editing && editor.textView.isEditable)
            editor.textView.setSelectedRange(NSRange(location: (editor.text as NSString).length, length: 0))
            editor.textView.insertText(" hello-mac", replacementRange: editor.textView.selectedRange())
            var written = ""
            for _ in 0..<50 where !written.contains("hello-mac") {
                try? await Task.sleep(for: .milliseconds(200))
                written = try await api.driveRead(path).map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            }
            check("what's typed reaches the file", written.contains("hello-mac"))

            // Written elsewhere (an app without live editing): shown here as it comes, the cursor staying put.
            let cursor = (editor.text as NSString).length
            editor.textView.setSelectedRange(NSRange(location: cursor, length: 0))
            try await api.driveWrite(path, Data(("elsewhere\n" + written).utf8), type: "text/markdown")
            await wait { editor.text.hasPrefix("elsewhere\n") }
            check("shows a write from elsewhere", editor.text == "elsewhere\n" + written)
            check("keeps the cursor where it was in the text", editor.textView.selectedRange().location == cursor + ("elsewhere\n" as NSString).length)
        } catch {
            check("no errors (\(error.localizedDescription))", false)
        }

        try? await api.driveDelete(path)
        return ok
    }

    private static func hasReplacement(_ editor: NoteEditor) -> Bool {
        let storage = editor.textView.textStorage!
        var found = false
        storage.enumerateAttribute(.noteReplacement, in: NSRange(location: 0, length: storage.length)) { v, _, _ in if v != nil { found = true } }
        return found
    }
}
