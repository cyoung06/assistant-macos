import AppKit
import WebKit

/**
 * Diagnostics (from a terminal only): `Assistant.app/Contents/MacOS/Assistant -checkNoteEditor`
 * writes a throwaway note under "No project", edits and saves it through the editor, exercises
 * every request the page can make (image upload and read, save as a copy, a conflict), prints
 * what passed, deletes what it made, and quits.
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
        func js(_ script: String) async -> Any? { try? await editor.webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page) }
        func wait(_ what: () -> Bool) async { for _ in 0..<100 where !what() { try? await Task.sleep(for: .milliseconds(100)) } }

        // The editor shown off screen, as Files would.
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor.webView

        do {
            try await api.driveWrite(path, Data("# Check\n\nInline $x^2$ math.\n".utf8), type: "text/markdown")
            await editor.open(path)
            await wait { editor.state == "saved" }
            check("opens the note (state \(editor.state))", editor.state == "saved")
            try await Task.sleep(for: .seconds(1))
            let katex = await js("return document.querySelectorAll('.katex').length") as? Int ?? 0
            check("renders TeX (\(katex) formula)", katex > 0)

            // Typing at the end, then saving.
            _ = await js("""
                const c = document.querySelector('.cm-content'); c.focus();
                const r = document.createRange(); r.selectNodeContents(c); r.collapse(false);
                const s = getSelection(); s.removeAllRanges(); s.addRange(r);
                document.execCommand('insertText', false, ' hello-mac');
                """)
            await editor.flush()
            let saved = try await api.driveRead(path).map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            check("saves what's typed", saved.contains("hello-mac"))

            // The page's requests, as it makes them.
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            let up = try await editor.request("uploadImage", ["notePath": path, "name": "pasted image.png", "mimeType": "image/png", "base64": png])
            let rel = up["relativePath"] as? String ?? ""
            check("uploads an image (\(rel))", rel == "attachments/pasted%20image.png")
            let image = try await editor.request("readImage", ["path": folder + "attachments/pasted image.png"])
            check("reads an image back", image["base64"] as? String == png && image["mimeType"] as? String == "image/png")
            let copy = try await editor.request("saveCopy", ["path": path, "text": "mine"])
            check("saves a copy (\(copy["name"] as? String ?? "?"))", copy["name"] as? String == "zz-mac-editor-test (my copy).md")

            let before = try await editor.request("load", ["path": path])
            try await api.driveWrite(path, Data("changed elsewhere\n".utf8), type: "text/markdown")
            let conflict = try await editor.request("save", ["path": path, "text": "stale", "etag": before["etag"] ?? NSNull(), "force": false])
            check("refuses to overwrite a newer version", conflict["conflict"] as? Bool == true)
            let forced = try await editor.request("save", ["path": path, "text": "forced", "etag": NSNull(), "force": true])
            check("overwrites when told to", forced["conflict"] == nil)
        } catch {
            check("no errors (\(error.localizedDescription))", false)
        }

        // Cleaning up.
        for p in [path, folder + "zz-mac-editor-test (my copy).md", folder + "attachments/pasted image.png"] { try? await api.driveDelete(p) }
        if (try? await api.driveFolder(folder + "attachments/"))?.isEmpty == true { try? await api.driveDelete(folder + "attachments/") }
        return ok
    }
}
