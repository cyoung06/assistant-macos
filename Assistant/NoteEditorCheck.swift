import AppKit

/**
 * Diagnostics (from a terminal only): `Assistant.app/Contents/MacOS/Assistant -checkNoteEditor
 * [-noteSnapshot <file.png> -noteSource <note.md>]` writes a throwaway note under "No project",
 * opens it in the editor off screen (as a preview), edits and saves it, makes a conflict and
 * settles it, prints what passed, deletes what it made, and quits. With -noteSnapshot, the note
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
        let editor = NoteEditor.shared
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
            await wait { editor.state == "saved" }
            check("opens the note as a preview (state \(editor.state), editing \(editor.editing))", editor.state == "saved" && !editor.editing)
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

            // Editing: typing at the end, then leaving editing saves it.
            editor.setEditing(true)
            check("edits when asked", editor.editing && editor.textView.isEditable)
            editor.textView.setSelectedRange(NSRange(location: (editor.text as NSString).length, length: 0))
            editor.textView.insertText(" hello-mac", replacementRange: editor.textView.selectedRange())
            editor.setEditing(false)
            await wait { editor.state == "saved" }
            await editor.flush()
            let saved = try await api.driveRead(path).map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            check("saves what's typed", saved.contains("hello-mac"))

            // A conflict: written elsewhere, then typed here.
            try await api.driveWrite(path, Data("changed elsewhere\n".utf8), type: "text/markdown")
            editor.setEditing(true)
            editor.textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
            await editor.flush()
            check("refuses to overwrite a newer version (state \(editor.state))", editor.state == "conflict")
            editor.loadTheirs()
            await wait { editor.state == "saved" }
            check("loads theirs", editor.text == "changed elsewhere\n")
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
