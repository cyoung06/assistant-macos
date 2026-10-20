import AppKit
import SwiftUI

/** "Share → Assistant": opens Capture with what was shared (text, links, images, a mail), which sends it from here. */
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        let text = items.compactMap { $0.attributedContentText?.string }.filter { !$0.isEmpty }.joined(separator: "\n")
        // The app's own setting can't be read from here (that takes an App Group, which needs a team-signed app): the default server.
        let root = CaptureView(api: API(base: URL(string: Defaults.server)!), text: text, images: [], shared: items.flatMap { $0.attachments ?? [] }) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = NSHostingView(rootView: root.frame(width: 520))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        preferredContentSize = NSSize(width: 520, height: 320)
    }
}
