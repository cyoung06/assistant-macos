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
            }
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
    }

    /** Mails (from Apple Mail) and images dropped on the Dock icon open in Capture. */
    func application(_ application: NSApplication, open urls: [URL]) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        if let mail = urls.lazy.filter({ $0.pathExtension.lowercased() == "eml" }).compactMap({ (try? Data(contentsOf: $0)).flatMap(MailFile.parse) }).first {
            CapturePanel.shared.show(mail: mail)
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

/** ⌥Space from anywhere opens Capture (Carbon hot keys need no accessibility permission). */
enum HotKey {
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { CapturePanel.shared.show() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4153_5354), id: 1) // "ASST"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
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
