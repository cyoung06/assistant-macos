import AppKit
import SwiftUI
import UniformTypeIdentifiers

/** "Share → Assistant": opens Capture with what was shared (text, links, images). */
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        Task { @MainActor in
            let (text, images) = await collect()
            let server = UserDefaults(suiteName: "com.syeyoung.assistant")?.string(forKey: "server") ?? Defaults.server
            let root = CaptureView(api: API(base: URL(string: server)!), text: text, images: images) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
            let host = NSHostingView(rootView: root.frame(width: 520))
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            view.addSubview(host)
            preferredContentSize = NSSize(width: 520, height: 320)
        }
    }

    private func collect() async -> (String, [CapturedImage]) {
        var texts: [String] = []
        var images: [CapturedImage] = []
        for case let item as NSExtensionItem in extensionContext?.inputItems ?? [] {
            if let t = item.attributedContentText?.string, !t.isEmpty { texts.append(t) }
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.image.identifier), let data = await p.imageData() {
                    images.append(CapturedImage(data: data, name: "shared.png", mimeType: "image/png"))
                } else if let s = try? await p.loadString() {
                    texts.append(s)
                }
            }
        }
        return (texts.joined(separator: "\n"), images)
    }
}
