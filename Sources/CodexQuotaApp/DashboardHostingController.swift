import AppKit
import SwiftUI

@MainActor
final class DashboardHostingController: NSHostingController<DashboardView> {
    init(model: DashboardViewModel) {
        super.init(rootView: DashboardView(model: model))
        // The popover owns its frame. Old hosting min/max constraints must not
        // keep the overview's height after switching to a shorter ranking page.
        sizingOptions = []
        if #available(macOS 13.3, *) { safeAreaRegions = [] }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func fittedContentSize() -> NSSize {
        let size = sizeThatFits(in: NSSize(width: 344, height: 10_000))
        return NSSize(width: 344, height: ceil(size.height))
    }

    func applyContentSize(_ size: NSSize) {
        preferredContentSize = size
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
    }
}
