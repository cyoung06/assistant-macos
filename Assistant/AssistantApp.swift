import AppKit
import Carbon.HIToolbox
import SwiftUI
import UserNotifications

@main
struct AssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Assistant", id: "main") {
            ContentView().environmentObject(model)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Capture…") { CapturePanel.shared.show() }.keyboardShortcut(" ", modifiers: .option)
                Button("Quick Note") { QuickNote.make() }.keyboardShortcut("n", modifiers: [.control, .option])
            }
        }

        // A note in a window of its own (Files' "Open in New Window"): to keep beside another note, or a PDF.
        WindowGroup("Note", id: "note", for: String.self) { $path in
            if let path { NoteView(path: path, windowed: true).environmentObject(model).frame(minWidth: 480, minHeight: 400) }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            let due = model.data.tasks.filter { !$0.closed && ($0.overdue || ($0.due?.date ?? "~") <= todayString) }.count
            Label(due > 0 ? "\(due)" : "", systemImage: "checkmark.circle")
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView().environmentObject(model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Reminders.requestPermission()
        HotKey.register()
        MainActor.assumeIsolated {
            NoteEditorCheck.runIfAsked(); NotebookCheck.runIfAsked()
            DriveDomain.start()
            // A permanent redirect the web server once gave for the drive's endpoint (to its own
            // http://…:8080, refused by App Transport Security) is cached: forgotten, so it's asked again.
            URLCache.shared.removeCachedResponse(for: URLRequest(url: AppModel.shared.api.driveURL("")))
        }
    }

    /** Quitting lets the open note go first (a moment, for what was just typed to go out). */
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let editors = NoteEditor.open.allObjects
            guard !editors.isEmpty else { return .terminateNow }
            Task { @MainActor in
                _ = await withTaskGroup(of: Void.self) { group in
                    group.addTask { for e in editors { await e.close() } }
                    group.addTask { try? await Task.sleep(for: .seconds(10)) }
                    await group.next()
                    group.cancelAll()
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /** Mails (from Apple Mail) and images dropped on the Dock icon open in Capture. */
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        if let eml = urls.first(where: { $0.pathExtension.lowercased() == "eml" }), let data = try? Data(contentsOf: eml) {
            Task { @MainActor in
                // Read by the server's MIME parser; if that fails, Capture opens with the error to see.
                do { CapturePanel.shared.show(mail: try await AppModel.shared.api.parseMail(data)) } catch { CapturePanel.shared.show(text: "Couldn't read that mail: \(error.localizedDescription)") }
            }
            return
        }
        let images = urls.compactMap { url -> CapturedImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return CapturedImage(data: data, name: url.lastPathComponent, mimeType: url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg")
        }
        CapturePanel.shared.show(images: images)
    }

    /** Clicking a reminder opens its task. */
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["task"] as? String {
            Task { @MainActor in
                AppModel.shared.openTask = id
                NSApp.activate()
            }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

/**
 * From anywhere: ⌥Space opens Capture, ⌃⌥N a quick note (Carbon hot keys need no accessibility
 * permission).
 */
enum HotKey {
    private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { if id.id == 2 { QuickNote.make() } else { CapturePanel.shared.show() } }
            return noErr
        }, 1, &spec, nil, nil)
        for (n, key, mods) in [(UInt32(1), kVK_Space, optionKey), (2, kVK_ANSI_N, controlKey | optionKey)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x4153_5354), id: n), GetApplicationEventTarget(), 0, &ref) // "ASST"
            refs.append(ref)
        }
    }
}

/** A quick note for the class on now (in its project's Notes), in a window of its own, to write in. */
@MainActor
enum QuickNote {
    private static var windows: [NSWindow] = []

    static func make(in projectId: String? = nil) {
        Task {
            do {
                let path = try await AppModel.shared.api.quickNote(notebook: false, projectId: projectId)
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                w.title = (path as NSString).lastPathComponent
                w.isReleasedWhenClosed = false
                w.contentViewController = NSHostingController(rootView: NoteView(path: path, windowed: true, writing: true).environmentObject(AppModel.shared))
                w.center()
                w.makeKeyAndOrderFront(nil)
                NSApp.activate()
                windows.removeAll { !$0.isVisible }
                windows.append(w)
            } catch {
                AppModel.shared.error = "Couldn't make a quick note: \(error.localizedDescription)"
            }
        }
    }
}

/** A floating window with Capture, in front of whatever app is active. */
@MainActor
final class CapturePanel {
    static let shared = CapturePanel()
    private var panel: NSPanel?

    func show(text: String = "", images: [CapturedImage] = [], mail: MailFile? = nil) {
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = "Capture"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: CaptureView(api: AppModel.shared.api, text: text, images: images, mail: mail, handOff: { text, title, link, images in
            TriageOutbox.shared.send(text: text, title: title, link: link, images: images)
            return true
        }) { [weak self] in
            self?.panel?.close()
            Task { await AppModel.shared.refresh() }
        }.frame(minWidth: 480, minHeight: 200))
        p.center()
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }
}
