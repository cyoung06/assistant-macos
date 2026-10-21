import AppKit
import SwiftUI

/**
 * Two panes side by side with a divider that's easy to grab: AppKit's split view, whose thin divider
 * takes drags a few points either side of it (as Finder's and Xcode's do). SwiftUI's HSplitView only
 * takes them on its one-point line. [leading] keeps its width as the window resizes.
 */
struct SplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    var leadingWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat)
    var trailingMinWidth: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        let left = NSSplitViewItem(viewController: NSHostingController(rootView: leading))
        left.minimumThickness = leadingWidth.min
        left.maximumThickness = leadingWidth.max
        left.holdingPriority = .defaultLow + 1
        let right = NSSplitViewItem(viewController: NSHostingController(rootView: trailing))
        right.minimumThickness = trailingMinWidth
        controller.addSplitViewItem(left)
        controller.addSplitViewItem(right)
        controller.initialLeading = leadingWidth.ideal
        return controller
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Leading>)?.rootView = leading
        (controller.splitViewItems[1].viewController as? NSHostingController<Trailing>)?.rootView = trailing
    }

    final class Controller: NSSplitViewController {
        var initialLeading: CGFloat = 0
        private var placed = false

        override func viewDidLayout() {
            super.viewDidLayout()
            // The leading pane's starting width, once there's room for it.
            if !placed, view.bounds.width > 0 {
                placed = true
                splitView.setPosition(initialLeading, ofDividerAt: 0)
            }
        }

        // Drags start up to 4 points either side of the divider.
        override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            proposedEffectiveRect.insetBy(dx: -4, dy: 0)
        }
    }
}
